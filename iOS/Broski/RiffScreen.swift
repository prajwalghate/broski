import AVFoundation
import BroskiCore
import SwiftUI

/// Riff mode on the iPhone: think out loud about a project with Claude, by voice or typing. Claude knows the
/// project's living page, pushes back and asks the next good question; Wrap up turns the riff into a note.
/// The riff is kept across launches until you start a new one, so a walk-and-talk isn't lost if iOS closes the app.
@MainActor
final class PhoneRiff: ObservableObject {
    @Published private(set) var riff = Riff(project: nil)
    @Published var draft = "" { didSet { keep() } }
    @Published private(set) var thinking = false
    @Published var problem: String?
    @Published var wrap: Riff.WrapUp?
    @Published private(set) var wrapping = false
    @Published var addTodos = true
    @Published private(set) var saved: String? { didSet { keep() } }
    /// Read Broski's replies aloud (remembered; off until you turn it on).
    @Published var speak: Bool {
        didSet {
            UserDefaults.standard.set(speak, forKey: Self.speakKey)
            if !speak { voice.stop() }
        }
    }

    private let store: PhoneStore
    /// False for the self-test, which mustn't touch the riff you have going.
    private let keeps: Bool
    private let voice = RiffVoice()
    private var task: Task<Void, Never>?
    private var wrapTask: Task<Void, Never>?
    /// Bumped by each new riff, so a reply or wrap-up still coming for the last one can't land on this one.
    private var generation = 0

    private static let speakKey = "BroskiRiffSpeak"
    private static let keptKey = "BroskiRiff"

    init(store: PhoneStore, keeps: Bool = true) {
        self.store = store
        self.keeps = keeps
        speak = UserDefaults.standard.bool(forKey: Self.speakKey)
        if keeps { restore() }
    }

    var hasKey: Bool { Keychain.claudeKey != nil }
    /// You've said something; the project is fixed from here on.
    var started: Bool { riff.turns.contains { $0.role == .you } }
    /// Your last words got no reply (an error, or the app closed while Claude was thinking).
    var unanswered: Bool { riff.turns.last?.role == .you && !thinking }
    /// Projects a riff can be about: local-only ones never go to Claude, so they aren't offered.
    var projects: [String] { store.projects.filter { !store.localOnly.contains($0) } }

    func newRiff(project: String?) {
        task?.cancel()
        wrapTask?.cancel()
        generation += 1
        thinking = false
        wrapping = false
        voice.stop()
        riff = Riff(project: project)
        draft = ""
        wrap = nil
        saved = nil
        problem = nil
        keep()
    }

    /// A fresh riff starts on the project you noted in most recently.
    func newRiffGuessingProject() {
        let allowed = Set(projects)
        newRiff(project: store.items.first { $0.project.map(allowed.contains) == true }?.project)
    }

    func setProject(_ project: String?) {
        guard !started else { return }
        riff.project = project
        keep()
    }

    /// Words from the mic, kept in the box (the mic taken away, the app going to the background, the riff closed).
    func addHeard(_ text: String) {
        draft = TextTools.joinPhrase(draft, text)
    }

    /// You tapped stop: what you said goes straight to Broski.
    func voiceDone(_ text: String) {
        guard !text.isEmpty else { return }
        addHeard(text)
        send()
    }

    func stopSpeaking() { voice.stop() }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking, !wrapping else { return }
        guard hasKey else { return problem = "Riff needs your Claude key: add it in Settings › Claude." }
        guard allowed(text) else { return }
        voice.stop()
        riff.turns.append(.init(role: .you, text: text))
        draft = ""
        // What you say after saving isn't in the saved note.
        saved = nil
        requestReply()
    }

    /// Asks again after a failed reply, without repeating what you said.
    func retry() {
        guard unanswered, let last = riff.turns.last?.text, allowed(last) else { return }
        requestReply()
    }

    private func requestReply() {
        guard let key = Keychain.claudeKey else { return }
        thinking = true
        problem = nil
        let page = riff.project.flatMap { store.pages[$0] }
        let snapshot = riff
        let run = generation
        keep()
        task = Task {
            defer { if run == generation { thinking = false } }
            do {
                let reply = try await snapshot.reply(page: page, client: ClaudeClient(apiKey: key))
                guard !Task.isCancelled, run == generation else { return }
                riff.turns.append(.init(role: .broski, text: reply))
                keep()
                if speak { voice.say(reply) }
            } catch {
                guard run == generation, !Self.isCancellation(error) else { return }
                problem = "Broski couldn't answer: \(error.localizedDescription)"
            }
        }
    }

    /// Nothing about a local-only project goes to Claude: not the riff's project, nor one it names.
    private func allowed(_ text: String) -> Bool {
        // Without the shared folder there's no config.json to say which projects are local only.
        guard !store.sharedUnavailable else {
            problem = "Can't reach the shared folder to check which projects are local only, so nothing goes to Claude right now."
            return false
        }
        store.refreshLocalOnly()
        guard !LocalOnly.touches(text, projects: [riff.project], localOnly: store.localOnly, catalog: store.catalog) else {
            problem = "This touches a project that's set to local only, so it can't go to Claude."
            return false
        }
        return true
    }

    func wrapUp() {
        guard started, !wrapping, !thinking else { return }
        voice.stop()
        saved = nil
        problem = nil
        let transcript = riff.plainNote.body
        // Without Claude (no key, or the riff now touches a local-only project): the conversation itself is the note.
        guard let key = Keychain.claudeKey, !store.sharedUnavailable,
              !LocalOnly.touches(transcript, projects: [riff.project], localOnly: store.localOnly, catalog: store.catalog) else {
            let plain = riff.plainNote
            wrap = Riff.WrapUp(title: plain.title, summary_markdown: plain.body, ideas: [], decisions: [], todos: [])
            return
        }
        wrapping = true
        let snapshot = riff
        let run = generation
        wrapTask = Task {
            defer { if run == generation { wrapping = false } }
            do {
                let result = try await snapshot.wrapUp(client: ClaudeClient(apiKey: key))
                guard !Task.isCancelled, run == generation else { return }
                wrap = result
            } catch {
                guard run == generation, !Self.isCancellation(error) else { return }
                problem = "Couldn't wrap up: \(error.localizedDescription)"
            }
        }
    }

    /// Saves the riff as an idea note (with the whole conversation), plus each todo as its own note, like the Mac.
    func save() {
        guard let wrap, saved == nil else { return }
        // A note saved while the shared folder is out of reach would be stranded on this iPhone.
        if store.sharedUnavailable { store.reload() }
        guard !store.sharedUnavailable else {
            problem = "Couldn't reach the shared folder. The riff is kept here; try again in a moment."
            return
        }
        var body = wrap.summary_markdown
        if !wrap.ideas.isEmpty { body += "\n\n**Ideas**\n" + wrap.ideas.map { "- \($0)" }.joined(separator: "\n") }
        if !wrap.decisions.isEmpty { body += "\n\n**Decisions**\n" + wrap.decisions.map { "- \($0)" }.joined(separator: "\n") }
        if !wrap.todos.isEmpty { body += "\n\n**Todos**\n" + wrap.todos.map { "- [ ] \($0)" }.joined(separator: "\n") }
        body += "\n\n<details><summary>The riff</summary>\n\n" + riff.plainNote.body + "\n\n</details>"
        let context = ItemContext(app: "Riff with Broski")
        do {
            let notes = store.store
            let item = try notes.create(ItemDraft(project: riff.project, kind: .idea, tags: ["riff"],
                                                  title: wrap.title, body: body, context: context))
            let todos = addTodos ? wrap.todos : []
            for todo in todos {
                _ = try notes.create(ItemDraft(project: riff.project, kind: .todo, tags: ["riff"], title: todo,
                                               body: "From the riff “\(wrap.title)”.", context: context))
            }
            store.reload()
            saved = "Saved to \(item.project ?? "Inbox")" + (todos.isEmpty ? "" : " with \(todos.count) todo\(todos.count == 1 ? "" : "s")")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: Kept across launches

    private func keep() {
        guard keeps else { return }
        UserDefaults.standard.set([
            "project": riff.project ?? "",
            "turns": riff.turns.map { ["role": $0.role.rawValue, "text": $0.text] },
            "draft": draft,
            "saved": saved ?? "",
        ] as [String: Any], forKey: Self.keptKey)
    }

    private func restore() {
        guard let kept = UserDefaults.standard.dictionary(forKey: Self.keptKey) else { return }
        let project = kept["project"] as? String ?? ""
        var restored = Riff(project: project.isEmpty ? nil : project)
        for turn in kept["turns"] as? [[String: String]] ?? [] {
            guard let role = turn["role"].flatMap(Riff.Turn.Role.init(rawValue:)), let text = turn["text"] else { continue }
            restored.turns.append(.init(role: role, text: text))
        }
        riff = restored
        draft = kept["draft"] as? String ?? ""
        let label = kept["saved"] as? String ?? ""
        saved = label.isEmpty ? nil : label
    }

    // MARK: Checking it on a real iPhone

    /// `--riff-selftest`: one riff turn and a wrap-up with this iPhone's Claude key, about the first project with a
    /// living page that isn't local only. Writes the replies and timings to tmp/riff-selftest.txt; saves nothing and
    /// leaves the riff you have going alone.
    static func selfTest(store: PhoneStore) async {
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("riff-selftest.txt")
        var lines: [String] = []
        func note(_ line: String) {
            lines.append(line)
            try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        store.refreshLocalOnly()
        let model = PhoneRiff(store: store, keeps: false)
        note("Riff self-test \(Date()) · key \(model.hasKey ? "saved" : "missing") · shared folder \(store.sharedFolderName ?? "none") · \(store.projects.count) projects, \(store.pages.count) pages, local only \(store.localOnly.sorted())")
        guard model.hasKey else { return note("done (no Claude key on this iPhone)") }
        let project = model.projects.first { store.pages[$0] != nil }
        model.newRiff(project: project)
        note("project: \(project ?? "none")")
        model.draft = "I'm thinking about what to do next on \(project ?? "my side project"). Push back on me: what am I missing?"
        var started = Date()
        model.send()
        while model.thinking { try? await Task.sleep(nanoseconds: 250_000_000) }
        note(String(format: "reply in %.1fs: %@", Date().timeIntervalSince(started), model.riff.turns.last { $0.role == .broski }?.text ?? "(none) \(model.problem ?? "")"))
        started = Date()
        model.wrapUp()
        while model.wrapping { try? await Task.sleep(nanoseconds: 250_000_000) }
        if let wrap = model.wrap {
            note(String(format: "wrap-up in %.1fs: %@ · %d ideas, %d decisions, %d todos", Date().timeIntervalSince(started), wrap.title, wrap.ideas.count, wrap.decisions.count, wrap.todos.count))
        } else {
            note("wrap-up failed: \(model.problem ?? "unknown")")
        }
        // A local-only project is refused before anything is sent.
        if let secret = store.localOnly.sorted().first {
            model.newRiff(project: nil)
            model.draft = "What should I do about \(secret)?"
            model.send()
            note("local-only \(secret): \(model.riff.turns.isEmpty ? "refused" : "SENT") · \(model.problem ?? "")")
        }
        note("done")
    }
}

/// Reads Broski's replies aloud. Takes the audio session only while speaking, so the mic and other apps get it back.
final class RiffVoice: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let spoken = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = 0.52
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { release() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { release() }

    /// Gives the audio back, unless the mic has taken the session meanwhile (stopping speech to talk).
    private func release() {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct RiffScreen: View {
    @ObservedObject var model: PhoneRiff
    @ObservedObject var store: PhoneStore
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let wrap = model.wrap { wrapView(wrap) } else { conversation }
            }
            .navigationTitle("Riff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if model.wrap == nil {
                        if model.wrapping {
                            ProgressView()
                        } else {
                            Button("Wrap up") { stopMic(); model.wrapUp() }
                                .disabled(!model.started || model.thinking)
                        }
                    }
                    Menu {
                        Toggle(isOn: $model.speak) { Label("Read replies aloud", systemImage: "speaker.wave.2") }
                        Button { stopMic(); model.newRiffGuessingProject() } label: { Label("New riff", systemImage: "plus.bubble") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        // Closing keeps what was said in the box, and the riff itself, for next time.
        .onDisappear {
            model.stopSpeaking()
            stopMic()
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        projectLine
                        if !model.hasKey {
                            Label("Riff needs your Claude key. Add it in Settings › Claude.", systemImage: "key")
                                .font(.callout).foregroundStyle(.orange)
                        } else if !model.started {
                            Text("Say what's on your mind. Broski builds on it, pushes back, and asks the next good question. Tap the mic and talk, or type. Wrap up turns it into a note.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.riff.turns) { bubble($0) }
                        if model.thinking {
                            HStack(spacing: 8) { ProgressView(); Text("Thinking…").foregroundStyle(.secondary) }.font(.callout)
                        }
                        if model.wrapping {
                            HStack(spacing: 8) { ProgressView(); Text("Wrapping up…").foregroundStyle(.secondary) }.font(.callout)
                        }
                        if model.unanswered, model.problem != nil {
                            Button { model.retry() } label: { Label("Try again", systemImage: "arrow.clockwise") }.font(.callout)
                        }
                        if let problem = model.problem ?? recorder.problem {
                            Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: model.riff.turns.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.thinking) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            }
            Divider()
            composer
        }
    }

    @ViewBuilder private var projectLine: some View {
        if model.started {
            Text(model.riff.project.map { "About \($0), with its living page" } ?? "Thinking out loud")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        } else {
            Menu {
                Picker("Project", selection: Binding(get: { model.riff.project ?? "" }, set: { model.setProject($0.isEmpty ? nil : $0) })) {
                    Text("No project").tag("")
                    ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.riff.project.map { "About \($0)" } ?? "No project")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.purple)
            }
        }
    }

    private func bubble(_ turn: Riff.Turn) -> some View {
        HStack {
            if turn.role == .you { Spacer(minLength: 48) }
            Text((try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(turn.text))
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 16).fill(turn.role == .you ? Brand.purple.opacity(0.15) : Color(.secondarySystemBackground)))
                .fixedSize(horizontal: false, vertical: true)
            if turn.role == .broski { Spacer(minLength: 48) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.isRecording {
                HStack(alignment: .top, spacing: 8) {
                    LevelDot(level: recorder.level)
                    Text(recorder.transcript.isEmpty ? "Listening · tap stop when you're done" : recorder.transcript)
                        .font(.callout)
                        .foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(4)
                }
            } else if recorder.finishing {
                Label("Writing it out…", systemImage: "waveform").font(.callout).foregroundStyle(Brand.purple)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Type, or tap the mic and talk…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.vertical, 8)
                if !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !recorder.isRecording {
                    Button { model.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(Brand.purple)
                    }
                    .disabled(model.thinking || model.wrapping)
                    .accessibilityLabel("Send")
                }
                Button { toggleMic() } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(recorder.isRecording ? Color.red : Brand.purple))
                }
                .disabled(recorder.finishing || (!recorder.isRecording && (model.thinking || model.wrapping)))
                .accessibilityLabel(recorder.isRecording ? "Done talking" : "Talk")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemBackground)))
        }
        .padding(12)
        .disabled(!model.hasKey)
    }

    private func toggleMic() {
        if recorder.isRecording {
            guard !recorder.isStopping else { return }
            Task { model.voiceDone(await recorder.stop()) }
        } else {
            focused = false
            model.stopSpeaking()
            Task { await recorder.start() }
        }
    }

    /// Ends a recording without sending it: the words wait in the box.
    private func stopMic() {
        guard recorder.isRecording, !recorder.isStopping else { return }
        Task { model.addHeard(await recorder.stop()) }
    }

    // MARK: Wrap-up

    private func wrapView(_ wrap: Riff.WrapUp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(wrap.title).font(.title3.weight(.semibold))
                Text((try? AttributedString(markdown: wrap.summary_markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(wrap.summary_markdown))
                    .textSelection(.enabled)
                list("Ideas", wrap.ideas)
                list("Decisions", wrap.decisions)
                list("Todos", wrap.todos)
                if !wrap.todos.isEmpty, model.saved == nil {
                    Toggle("Also add the \(wrap.todos.count) todo\(wrap.todos.count == 1 ? "" : "s") to \(model.riff.project ?? "the Inbox")", isOn: $model.addTodos)
                        .tint(Brand.purple)
                }
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if let saved = model.saved {
                    Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button { model.newRiffGuessingProject() } label: { Text("New riff").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Brand.purple).controlSize(.large)
                } else {
                    Button { model.save() } label: { Text("Save note").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Brand.purple).controlSize(.large)
                }
                Button { model.wrap = nil } label: { Text("Back to the riff").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(18)
        }
    }

    @ViewBuilder private func list(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(lines, id: \.self) { Text("• " + $0) }
            }
        }
    }
}
