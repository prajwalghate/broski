import AVFoundation
import AppKit
import BroskiCore
import SwiftUI

/// The home conversation: one ongoing conversation with Broski, kept as files in the Broski folder. Replies come
/// through the model gateway; notes, todos and decisions are saved only from a card you tap, or a "note: …".
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var turns: [Turn] = []
    @Published var draft = ""
    @Published private(set) var thinking = false
    @Published private(set) var isPrivate = false
    /// Leaving private mode after saying something: keep it, or let it go.
    @Published var askKeep = false
    /// Replies come from the deep model.
    @Published var deep = false
    @Published var project: String?
    @Published var card: SaveCard?
    @Published var problem: String?
    @Published var speak: Bool

    let library: Library
    let voice: VoiceInput
    var onSpeakChange: (Bool) -> Void = { _ in }
    private let root: URL
    private let config: () -> BroskiConfig
    private let synthesizer = AVSpeechSynthesizer()
    /// A private conversation lives only here, never on disk.
    private var privateTurns: [Turn] = []
    private var task: Task<Void, Never>?
    private var store: ConversationStore { ConversationStore(root: root, device: "mac") }

    init(root: URL, library: Library, voice: VoiceInput, config: @escaping () -> BroskiConfig) {
        self.root = root
        self.library = library
        self.voice = voice
        self.config = config
        speak = config().speakReplies
        reload()
    }

    /// The recent conversation from every device, and the project it was last about.
    func reload() {
        guard !thinking else { return }
        turns = store.recent(80)
        if project == nil { project = turns.last(where: { $0.project != nil })?.project }
    }

    var visibleTurns: [Turn] { isPrivate ? privateTurns : turns }

    var modelLabel: String { deep ? "Deep" : "Everyday" }

    var gateway: ModelGateway {
        ModelGateway(settings: config().models ?? .defaults, root: root, device: "mac") { id in
            id == "claude" ? Secrets.get(Secrets.claudeKey) : Secrets.get("model.\(id)")
        }
    }

    private var localOnlyProjects: Set<String> { Set(config().localOnlyProjects) }

    /// Any of this text, or the project, belongs to a local-only project: only on-device models may see it.
    private func touchesLocalOnly(_ text: String) -> Bool {
        LocalOnly.touches(text, projects: [project], localOnly: localOnlyProjects, catalog: library.catalog)
    }

    // MARK: Talking

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !thinking else { return }
        draft = ""
        if let command = ConversationCommand.parse(text, catalog: library.catalog) { return run(command) }
        add(Turn(device: "mac", speaker: .you, text: text, project: project))
        reply()
    }

    private func add(_ turn: Turn) {
        if isPrivate {
            privateTurns.append(turn)
            return
        }
        turns.append(turn)
        do {
            try store.append(turn)
        } catch {
            problem = "Couldn't keep that in your Broski folder: \(error.localizedDescription)"
        }
    }

    private func reply() {
        let history = visibleTurns
        let request = ConversationContext.build(aboutYou: isPrivate ? nil : Memory.aboutYou(root: root),
                                                page: isPrivate ? nil : project.flatMap { library.pages[$0] },
                                                project: isPrivate ? nil : project, turns: history, isPrivate: isPrivate)
        let localOnly = touchesLocalOnly(request.messages.map(\.text).joined(separator: "\n"))
        let role: ModelRole = deep ? .deep : .everyday
        let gateway = gateway
        let project = project
        let wasPrivate = isPrivate
        thinking = true
        problem = nil
        task = Task {
            defer { thinking = false }
            do {
                let (reply, route) = try await gateway.send(request, role: role, project: project, localOnly: localOnly)
                guard wasPrivate == isPrivate else { return }
                var sources: [String] = []
                if route.overBudget { sources.append("Past today's limit: \(route.model)") }
                if route.substituted { sources.append("On this Mac: \(route.model)") }
                add(Turn(device: "mac", speaker: .broski, text: reply.text, project: project, model: route.model,
                         sources: sources.isEmpty ? nil : sources))
                if speak { say(reply.text) }
                if !wasPrivate { suggestSave(force: false) }
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func run(_ command: ConversationCommand) {
        switch command {
        case .note(let text):
            quickNote(text)
        case .goPrivate:
            goPrivate()
        case .leavePrivate:
            leavePrivate()
        case .thinkHarder:
            deep = true
        case .saveThat:
            suggestSave(force: true)
        case .remember(let fact):
            guard !isPrivate else { return problem = "Private conversations keep nothing, so that isn't remembered." }
            do {
                try Memory.remember(fact, root: root, device: "mac")
                add(Turn(device: "mac", speaker: .note, text: "Remembered: \(fact)", project: project))
            } catch {
                problem = "Couldn't remember that: \(error.localizedDescription)"
            }
        case .forget(let phrase):
            let forgot = (try? Memory.forget(phrase, root: root, device: "mac")) ?? false
            if forgot {
                add(Turn(device: "mac", speaker: .note, text: "Forgotten.", project: project))
            } else {
                problem = "Nothing Broski remembers matches that. See what it knows in the dashboard."
            }
        case .switchProject(let name):
            project = name
            add(Turn(device: "mac", speaker: .topic, text: name, project: name))
        }
    }

    // MARK: Saving

    /// "note: …" or the Note button: saved at once, filed by the rules, no reply.
    func quickNote(_ given: String? = nil) {
        let text = (given ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return problem = "Type or say something first." }
        if given == nil { draft = "" }
        let decision = Rules.interpret(text, catalog: library.catalog, activeSession: nil)
        let target = project ?? (decision.project.isEmpty ? nil : decision.project)
        do {
            let item = try library.store.create(ItemDraft(
                project: target, kind: NoteKind(rawValue: decision.kind) ?? .note,
                priority: Priority(rawValue: decision.priority) ?? .normal, tags: decision.tags,
                title: decision.title.isEmpty ? String(text.prefix(90)) : decision.title, body: decision.body,
                context: ItemContext(app: "Broski conversation")))
            library.reload()
            add(Turn(device: "mac", speaker: .note, text: "Noted in \(item.project ?? "the inbox"): \(item.title)", project: item.project))
        } catch {
            problem = "Couldn't save the note: \(error.localizedDescription)"
        }
    }

    /// Asks the fast model what in the last few turns is worth saving; shows a card when there's something.
    func suggestSave(force: Bool) {
        let recent = turns.suffix(6).filter { $0.speaker == .you || $0.speaker == .broski }
        guard recent.contains(where: { $0.speaker == .you }) else {
            if force { problem = "Nothing to save yet." }
            return
        }
        let transcript = recent.map { "\($0.speaker == .you ? "User" : "Broski"): \($0.text)" }.joined(separator: "\n\n")
        let localOnly = touchesLocalOnly(transcript)
        // The model isn't told local-only projects exist, so it can't file anything into them.
        let known = library.projectNames.filter { !localOnlyProjects.contains($0) }
        let request = ModelRequest(system: SaveCard.instructions + "\n\nThe user's projects: " + known.joined(separator: ", "),
                                   messages: [ModelMessage(role: .user, text: transcript)], maxTokens: 1500,
                                   schemaJSON: SaveCard.schemaJSON)
        let gateway = gateway
        let project = project
        Task {
            do {
                let (reply, _) = try await gateway.send(request, role: .fast, project: project, localOnly: localOnly)
                if var found = SaveCard.parse(reply.text, catalog: library.catalog) {
                    if found.project == nil { found.project = project }
                    card = found
                } else if force {
                    problem = "Nothing in the last few turns to save."
                }
            } catch {
                if force { problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
            }
        }
    }

    func saveCard() {
        guard let card else { return }
        var counts: [SaveCard.Entry.Kind: Int] = [:]
        do {
            for entry in card.items {
                var tags = ["conversation"]
                let kind: NoteKind
                switch entry.kind {
                case .note: kind = .note
                case .idea: kind = .idea
                case .todo: kind = .todo
                case .bug: kind = .bug
                case .decision:
                    kind = .note
                    tags.append("decision")
                }
                _ = try library.store.create(ItemDraft(project: card.project, kind: kind, tags: tags, title: entry.title,
                                                       body: entry.body, context: ItemContext(app: "Broski conversation")))
                counts[entry.kind, default: 0] += 1
            }
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
            return
        }
        library.reload()
        let summary = counts.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) \($0.key.rawValue)\($0.value == 1 ? "" : "s")" }.joined(separator: ", ")
        add(Turn(device: "mac", speaker: .note, text: "Saved to \(card.project ?? "the inbox"): \(summary)", project: card.project))
        self.card = nil
    }

    func removeFromCard(_ index: Int) {
        guard var card, card.items.indices.contains(index) else { return }
        card.items.remove(at: index)
        self.card = card.items.isEmpty ? nil : card
    }

    // MARK: Private mode

    func togglePrivate() { isPrivate ? leavePrivate() : goPrivate() }

    func goPrivate() {
        guard !isPrivate else { return }
        task?.cancel()
        isPrivate = true
        privateTurns = []
        deep = false
        card = nil
    }

    func leavePrivate() {
        guard isPrivate else { return }
        if privateTurns.contains(where: { $0.speaker == .you }) {
            askKeep = true
        } else {
            isPrivate = false
        }
    }

    func keepPrivate() {
        let kept = privateTurns
        privateTurns = []
        isPrivate = false
        askKeep = false
        add(Turn(device: "mac", speaker: .topic, text: "Kept from a private conversation", project: project))
        kept.forEach(add)
    }

    func discardPrivate() {
        privateTurns = []
        isPrivate = false
        askKeep = false
    }

    // MARK: Voice

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

    /// fn held: start listening; let go: send what was said.
    func holdStart() {
        guard !voice.listening else { return }
        synthesizer.stopSpeaking(at: .immediate)
        voice.start()
    }

    func holdEnd() {
        if voice.listening { toggleVoice() }
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text.replacingOccurrences(of: "*", with: ""))
        utterance.rate = 0.52
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
}

struct HomeView: View {
    /// The design system's private-text colour: Paper #94560a, Ink #ffbe4d (both pass 4.5:1 on their banner).
    static let privateText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.745, blue: 0.302, alpha: 1)
            : NSColor(srgbRed: 0.580, green: 0.337, blue: 0.039, alpha: 1)
    })

    @ObservedObject var model: HomeModel
    @ObservedObject var voice: VoiceInput
    var openDashboard: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isPrivate { privateBanner }
            conversation
            Divider()
            composer
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: BroskiArt.avatar(diameter: 30, crowned: false)).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Broski").font(.system(size: 14, weight: .semibold))
                Text(model.isPrivate ? "Private · starts blank, keeps nothing" : "Remembers your projects")
                    .font(.system(size: 11)).foregroundStyle(model.isPrivate ? Self.privateText : .secondary)
            }
            Spacer()
            Text(model.modelLabel)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.5)))
                .padding(1)
                .foregroundStyle(Brand.purple)
                .help(model.deep ? "Replies come from the deep model" : "Replies come from the everyday model")
            Toggle("Speak", isOn: Binding(get: { model.speak }, set: { model.speak = $0; model.onSpeakChange($0) }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Read Broski's replies aloud")
            Button(action: openDashboard) { Image(systemName: "square.grid.2x2") }
                .buttonStyle(.borderless).help("Open the dashboard")
            Button { model.togglePrivate() } label: {
                Image(systemName: model.isPrivate ? "lock.fill" : "lock").foregroundStyle(model.isPrivate ? Self.privateText : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.isPrivate ? "Leave private mode" : "Go private: Broski starts blank and keeps nothing")
        }
        .padding(12)
    }

    @ViewBuilder private var privateBanner: some View {
        if model.askKeep {
            HStack(spacing: 8) {
                Text("Keep this private conversation in your memory?").font(.system(size: 12))
                Spacer()
                Button("Keep it") { model.keepPrivate() }.buttonStyle(.borderedProminent).tint(Brand.purple).controlSize(.small)
                Button("Discard", role: .destructive) { model.discardPrivate() }.controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.orange.opacity(0.15))
        } else {
            Text("Private: Broski starts blank and keeps nothing. When you leave, you choose whether to keep it.")
                .font(.system(size: 12)).foregroundStyle(Self.privateText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.visibleTurns.isEmpty {
                        Text(model.isPrivate
                             ? "A blank slate. Nothing you say here is kept unless you choose to keep it."
                             : "Talk to Broski about anything: a project, an idea, a decision. It remembers, and saves notes only when you say so. Type, click the mic, or hold fn.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .padding(.top, 30)
                    }
                    ForEach(model.visibleTurns) { turn in
                        row(turn).id(turn.id)
                    }
                    if model.thinking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.deep ? "Thinking harder…" : "Thinking…").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12)).id("thinking")
                    }
                    if let card = model.card { saveCard(card).id("card") }
                    if let problem = model.problem ?? voice.problem {
                        Text(problem).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(16)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.visibleTurns.count) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: model.card) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder private func row(_ turn: Turn) -> some View {
        switch turn.speaker {
        case .topic:
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                Text(turn.text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            }
        case .note:
            Label(turn.text, systemImage: "checkmark")
                .font(.system(size: 12)).foregroundStyle(.green)
                .padding(.leading, 34)
        case .you:
            HStack {
                Spacer(minLength: 60)
                Text(turn.text)
                    .font(.system(size: 13.5)).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Brand.purple.opacity(0.15)))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .broski:
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: BroskiArt.avatar(diameter: 24, crowned: false)).frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 6) {
                    Text((try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(turn.text))
                        .font(.system(size: 13.5)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sources = turn.sources, !sources.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(sources, id: \.self) { source in
                                Text(source).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }
                Spacer(minLength: 40)
            }
        }
    }

    private func saveCard(_ card: SaveCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save to \(card.project ?? "the inbox")?").font(.system(size: 14, weight: .semibold))
            ForEach(Array(card.items.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .top, spacing: 8) {
                    Text(entry.kind.rawValue.capitalized)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(color(entry.kind))
                    Text(entry.title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { model.removeFromCard(index) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Leave this one out")
                }
            }
            HStack {
                Button("Save") { model.saveCard() }.buttonStyle(.borderedProminent).tint(Brand.purple)
                Button("Not now") { model.card = nil }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Brand.purple.opacity(0.1)))
        .padding(.leading, 34)
    }

    private func color(_ kind: SaveCard.Entry.Kind) -> Color {
        switch kind {
        case .todo: return .blue
        case .bug: return .red
        case .idea: return .orange
        case .decision: return Brand.purple
        case .note: return .secondary
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                chip("Save that") { model.suggestSave(force: true) }
                chip(model.deep ? "Back to everyday" : "Think harder") { model.deep.toggle() }
                if let project = model.project, !model.isPrivate {
                    chip("What do you know about \(project)?") {
                        model.draft = "What do you know about \(project)?"
                        model.send()
                    }
                }
            }
            .padding(.horizontal, 1)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Talk to Broski, or type “note: …”", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.send() }
                if voice.transcribing { ProgressView().controlSize(.small) }
                Button("Note") { model.quickNote() }
                    .buttonStyle(.borderless).foregroundStyle(Brand.purple)
                    .help("Save what's typed as a note, without a reply")
                Button { model.toggleVoice() } label: {
                    Image(systemName: voice.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(voice.listening ? Color.red : Brand.purple))
                }
                .buttonStyle(.plain)
                .help(voice.listening ? "Done talking" : "Talk (or hold fn)")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.4)))
            HStack(spacing: 8) {
                Menu {
                    Button("No project") { model.project = nil }
                    Divider()
                    ForEach(model.library.projectNames, id: \.self) { name in
                        Button(name) { model.project = name }
                    }
                } label: {
                    Text(model.project ?? "No project").font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("The project this conversation is about")
                Text("Return sends · hold fn to talk · “note: …” saves without a reply")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .overlay(Capsule().stroke(Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(model.thinking)
    }
}
