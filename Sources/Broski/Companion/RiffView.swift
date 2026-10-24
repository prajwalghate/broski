import AVFoundation
import AppKit
import BroskiCore
import SwiftUI

/// Riff mode: think out loud about a project with Claude, by voice or typing. Claude knows the project's
/// living page. "Wrap up" turns the riff into a note (and todos, if you want them).
@MainActor
final class RiffModel: ObservableObject {
    @Published var riff: Riff
    @Published var draft = ""
    @Published private(set) var thinking = false
    @Published var problem: String?
    @Published var wrap: Riff.WrapUp?
    @Published private(set) var wrapping = false
    @Published var addTodos = true
    @Published var saved: String?
    @Published var speak: Bool
    let library: Library
    let brain: Brain
    let voice: VoiceInput
    var onSpeakChange: (Bool) -> Void = { _ in }
    private let synthesizer = AVSpeechSynthesizer()
    private var task: Task<Void, Never>?
    private var wrapTask: Task<Void, Never>?
    /// Bumped by each new riff, so a cancelled reply or wrap-up from the last one can't land on this one
    /// or leave it stuck thinking.
    private var generation = 0

    init(project: String?, library: Library, brain: Brain, voice: VoiceInput, speak: Bool) {
        riff = Riff(project: project)
        self.library = library
        self.brain = brain
        self.voice = voice
        self.speak = speak
    }

    func start(project: String?, opening: String?) {
        task?.cancel()
        wrapTask?.cancel()
        generation += 1
        thinking = false
        wrapping = false
        synthesizer.stopSpeaking(at: .immediate)
        riff = Riff(project: project)
        draft = ""
        wrap = nil
        saved = nil
        problem = nil
        if let opening, !opening.isEmpty {
            draft = opening
            send()
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        guard let client = brain.client else { return problem = "Riff mode needs a Claude key (Settings › AI)." }
        // The text too: it can name a local-only project the riff isn't about ("Keep thinking" brings a whole answer).
        guard !LocalOnly.touches(text, projects: [riff.project], localOnly: Set(BroskiUI.app?.config.localOnlyProjects ?? []), catalog: library.catalog) else {
            return problem = "This touches a project that's set to local only, so it can't go to Claude."
        }
        riff.turns.append(.init(role: .you, text: text))
        draft = ""
        thinking = true
        problem = nil
        let page = riff.project.flatMap { library.pages[$0] }
        let snapshot = riff
        let run = generation
        task = Task {
            defer { if run == generation { thinking = false } }
            do {
                let reply = try await snapshot.reply(page: page, client: client)
                guard !Task.isCancelled, run == generation else { return }
                riff.turns.append(.init(role: .broski, text: reply))
                if speak { say(reply) }
            } catch where Brain.isCancellation(error) {
            } catch {
                if run == generation { problem = error.localizedDescription }
            }
        }
    }

    func toggleVoice() {
        if voice.listening {
            Task {
                let text = await voice.stop(vocabulary: library.projectNames)
                guard !text.isEmpty else { return }
                draft = TextTools.joinPhrase(draft, text)
                send()
            }
        } else {
            synthesizer.stopSpeaking(at: .immediate)
            voice.start()
        }
    }

    func setProject(_ project: String?) {
        riff.project = project
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text.replacingOccurrences(of: "*", with: ""))
        utterance.rate = 0.52
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func wrapUp() {
        guard riff.turns.contains(where: { $0.role == .you }), !wrapping else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // A new wrap-up covers what was said since the last save, so it can be saved too.
        saved = nil
        guard let client = brain.client else {
            let plain = riff.plainNote
            wrap = Riff.WrapUp(title: plain.title, summary_markdown: plain.body, ideas: [], decisions: [], todos: [])
            return
        }
        wrapping = true
        let run = generation
        wrapTask = Task {
            defer { if run == generation { wrapping = false } }
            do {
                let result = try await riff.wrapUp(client: client)
                // A new riff started meanwhile: this wrap-up isn't its, so it's neither shown nor saved under it.
                guard !Task.isCancelled, run == generation else { return }
                wrap = result
            } catch where Brain.isCancellation(error) {
            } catch {
                if run == generation { problem = error.localizedDescription }
            }
        }
    }

    /// Saves the riff as an idea note (with the full conversation), plus each todo as its own note.
    func save() {
        guard let wrap else { return }
        var body = wrap.summary_markdown
        if !wrap.ideas.isEmpty { body += "\n\n**Ideas**\n" + wrap.ideas.map { "- \($0)" }.joined(separator: "\n") }
        if !wrap.decisions.isEmpty { body += "\n\n**Decisions**\n" + wrap.decisions.map { "- \($0)" }.joined(separator: "\n") }
        if !wrap.todos.isEmpty { body += "\n\n**Todos**\n" + wrap.todos.map { "- [ ] \($0)" }.joined(separator: "\n") }
        body += "\n\n<details><summary>The riff</summary>\n\n" + riff.plainNote.body + "\n\n</details>"
        do {
            let store = library.store
            let item = try store.create(ItemDraft(project: riff.project, kind: .idea, tags: ["riff"],
                                                  title: wrap.title, body: body, context: ItemContext(app: "Riff with Broski")))
            if addTodos {
                for todo in wrap.todos {
                    _ = try store.create(ItemDraft(project: riff.project, kind: .todo, tags: ["riff"], title: todo,
                                                   body: "From the riff “\(wrap.title)”.", context: ItemContext(app: "Riff with Broski")))
                }
            }
            library.reload()
            saved = "Saved to \(item.project ?? "Inbox")" + (addTodos && !wrap.todos.isEmpty ? " with \(wrap.todos.count) todo\(wrap.todos.count == 1 ? "" : "s")" : "")
            Log.info("Riff saved (\(riff.turns.count) turns)")
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

struct RiffView: View {
    @ObservedObject var model: RiffModel
    @ObservedObject var voice: VoiceInput
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let wrap = model.wrap {
                wrapView(wrap)
            } else {
                conversation
                Divider()
                composer
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: BroskiArt.avatar(diameter: 26, crowned: false)).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Riff").font(.system(size: 14, weight: .semibold))
                Text(model.riff.project.map { "Thinking about \($0), with its living page" } ?? "Thinking out loud")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(get: { model.riff.project ?? "" }, set: { model.setProject($0.isEmpty ? nil : $0) })) {
                Text("No project").tag("")
                ForEach(model.library.projectNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)
            .disabled(!model.riff.turns.isEmpty)
            Toggle("Speak", isOn: Binding(get: { model.speak }, set: { model.speak = $0; model.onSpeakChange($0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Read Broski's replies aloud")
            Button("Wrap up") { model.wrapUp() }
                .disabled(!model.riff.turns.contains { $0.role == .you } || model.wrapping)
                .help("Turn this riff into a note")
        }
        .padding(12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.riff.turns.isEmpty {
                        Text("Say what's on your mind. Broski builds on it, pushes back, and asks the next good question. Type, or click the mic and talk. Wrap up turns it into a note.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                    ForEach(model.riff.turns) { turn in
                        bubble(turn).id(turn.id)
                    }
                    if model.thinking {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                            .font(.system(size: 12)).id("thinking")
                    }
                    if let problem = model.problem ?? voice.problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.riff.turns.count) { _ in
                withAnimation { proxy.scrollTo(model.riff.turns.last?.id, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ turn: Riff.Turn) -> some View {
        HStack {
            if turn.role == .you { Spacer(minLength: 60) }
            Text((try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(turn.text))
                .font(.system(size: 13.5))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(turn.role == .you ? Brand.purple.opacity(0.15) : Color.primary.opacity(0.06)))
                .fixedSize(horizontal: false, vertical: true)
            if turn.role == .broski { Spacer(minLength: 60) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Type, or click the mic and talk…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { model.send() }
            if voice.transcribing { ProgressView().controlSize(.small) }
            Button { model.toggleVoice() } label: {
                Image(systemName: voice.listening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(voice.listening ? Color.red : Brand.purple))
            }
            .buttonStyle(.plain)
            .help(voice.listening ? "Done talking" : "Talk")
        }
        .padding(12)
    }

    private func wrapView(_ wrap: Riff.WrapUp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(wrap.title).font(.system(size: 18, weight: .semibold))
                Text((try? AttributedString(markdown: wrap.summary_markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(wrap.summary_markdown))
                    .font(.system(size: 13.5)).textSelection(.enabled)
                list("Ideas", wrap.ideas)
                list("Decisions", wrap.decisions)
                list("Todos", wrap.todos)
                if !wrap.todos.isEmpty {
                    Toggle("Also add the \(wrap.todos.count) todo\(wrap.todos.count == 1 ? "" : "s") to \(model.riff.project ?? "the Inbox")", isOn: $model.addTodos)
                }
                HStack {
                    if let saved = model.saved { Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Spacer()
                    Button("Back to the riff") { model.wrap = nil }
                    Button("Save note") { model.save() }
                        .buttonStyle(.borderedProminent).tint(Brand.purple)
                        .disabled(model.saved != nil)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder private func list(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(lines, id: \.self) { Text("• " + $0).font(.system(size: 13)) }
            }
        }
    }
}
