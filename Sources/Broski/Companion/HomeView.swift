import AVFoundation
import AppKit
import BroskiCore
import SwiftUI
import UniformTypeIdentifiers

/// The home conversation: one ongoing conversation with Broski, kept as files in the Broski folder. Replies come
/// through the model gateway; notes, todos and decisions are saved only from a card you tap, or a "note: …".
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var turns: [Turn] = []
    @Published var draft = ""
    @Published private(set) var thinking = false
    /// "Reading example.com…" while links you shared are being opened.
    @Published private(set) var reading: String?
    /// Your rules for riffs, kept for every riff.
    @Published private(set) var riffRules: [String] = []
    @Published private(set) var isPrivate = false
    /// Leaving private mode after saying something: keep it, or let it go.
    @Published var askKeep = false
    /// Replies come from the deep model.
    @Published var deep = false
    @Published var project: String?
    /// What's being discussed now ("launch plan"), from the review after each reply; stored on each turn.
    @Published private(set) var topic: String?
    /// Showing one thread (a topic) instead of the whole conversation.
    @Published var thread: String?
    @Published var card: SaveCard?
    /// Files chosen for the next message, not sent yet.
    @Published var pending: [URL] = []
    /// A new project Broski proposes; nothing is created until you tap Create.
    @Published var proposal: ProjectProposal?
    @Published var problem: String?
    @Published var speak: Bool
    /// Reading a reply aloud now: the window offers Stop.
    @Published private(set) var speaking = false

    let library: Library
    let voice: VoiceInput
    var onSpeakChange: (Bool) -> Void = { _ in }
    var openSettings: (SettingsTab) -> Void = { _ in }
    var useAppleModel: () -> Void = {}
    /// The first run's third answer is in: reflect now, so what they said is remembered from the start.
    var firstRunDone: () async -> String = { "" }
    /// Opens the private vault, with a note to add once it's open.
    var openVault: (String?) -> Void = { _ in }
    private let root: URL
    private let config: () -> BroskiConfig
    let speaker = ReplySpeaker()
    /// A private conversation lives only here, never on disk.
    private var privateTurns: [Turn] = []
    private var task: Task<Void, Never>?
    private var store: ConversationStore { ConversationStore(root: root, device: "mac") }
    /// Notes, decisions and past turns, searchable for recall; rebuilt when something new is saved or said.
    private var recallIndex: NotesIndex?

    init(root: URL, library: Library, voice: VoiceInput, config: @escaping () -> BroskiConfig) {
        self.root = root
        self.library = library
        self.voice = voice
        self.config = config
        speak = config().speakReplies
        reload()
        speaker.onSpeaking = { [weak self] on in self?.speaking = on }
    }

    /// The recent conversation from every device, and the project it was last about.
    func reload() {
        guard !thinking else { return }
        turns = store.recent(80)
        recallIndex = nil
        riffRules = RiffMode.rules(root: root)
        // Someone new (nothing said, known or noted yet): Broski opens the conversation.
        if FirstRun.needed(turns: turns, aboutYou: Memory.aboutYou(root: root)), ItemStore(root: root).allItems().isEmpty {
            add(FirstRun.greetingTurn(device: "mac"))
        }
        if project == nil { project = turns.last(where: { $0.project != nil })?.project }
        if topic == nil { topic = turns.last?.topic }
    }

    /// The conversation's files changed on disk (your iPhone said something): show it, unless a reply is on its way.
    func refreshFromDisk() {
        guard !thinking else { return }
        let fresh = store.recent(80)
        guard fresh.map(\.id) != turns.map(\.id) else { return }
        turns = fresh
        recallIndex = nil
    }

    var visibleTurns: [Turn] {
        if isPrivate { return privateTurns }
        guard let thread else { return turns }
        return turns.filter { $0.topic == thread }
    }

    /// Recent topics, newest first: each is a thread you can come back to.
    var threads: [String] {
        var seen: [String] = []
        for turn in turns.reversed() {
            if let topic = turn.topic, !seen.contains(topic) { seen.append(topic) }
            if seen.count == 8 { break }
        }
        return seen
    }

    func show(thread: String?) {
        self.thread = thread
        if let thread { topic = thread }
    }

    var modelLabel: String { riffing ? "Riff" : deep ? "Deep" : "Everyday" }

    /// Riff mode is on: from its start marker in the conversation until it's wrapped up, so it survives a restart.
    var riffing: Bool { RiffMode.active(turns: isPrivate ? privateTurns : turns) }

    /// Packs a new project can use: the built-ins (but core, which every project has) and your own.
    var packs: [Pack] { Packs.all(root: root).filter { $0.id != "core" } }

    /// Nothing can answer yet: no Claude key, no local server, Apple's model not set up.
    var needsModel: Bool {
        !ModelSetup.ready(config().models ?? .defaults, claudeKey: Secrets.get(Secrets.claudeKey) != nil,
                          appleAvailable: ModelsSettings.appleAvailable)
    }

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
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pending
        guard !text.isEmpty || !files.isEmpty, !thinking else { return }
        draft = ""
        if let command = ConversationCommand.parse(text, catalog: library.catalog, riffing: riffing) {
            guard case .startRiff(let about) = command else { return run(command) }
            startRiff(about: about)
            // "Let's riff about pricing": the riff opens with those words.
            guard about != nil else { return }
        }
        pending = []
        if text.isEmpty { text = "Shared " + files.map(\.lastPathComponent).joined(separator: ", ") }
        // What you share is kept with the project; a private conversation keeps nothing, so nothing is copied.
        var stored: [String] = []
        if !isPrivate {
            for file in files {
                do {
                    let path = try Resources.add(file: file, project: project, root: root)
                    stored.append(path)
                    if let project {
                        try? ChangeStream.append([ChangeEvent(at: Date(), project: project, source: "broski", kind: "added",
                                                              id: "\(project):resource/\((path as NSString).lastPathComponent)",
                                                              title: file.lastPathComponent)], root: root, project: project)
                    }
                } catch {
                    problem = "Couldn't keep \(file.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        let turn = Turn(device: "mac", speaker: .you, text: text, files: isPrivate ? files.map(\.path) : (stored.isEmpty ? nil : stored),
                        project: project, topic: topic, mode: riffing ? "riff" : nil)
        add(turn)
        let links = Resources.links(in: text)
        if !isPrivate, !links.isEmpty {
            try? Resources.record(links: links, project: project, turn: turn.id, root: root, device: "mac")
        }
        let shared = isPrivate ? Resources.parts(forFiles: files) : Resources.parts(for: stored, root: root)
        let toRead = config().readLinks ? Array(links.prefix(3)) : []
        guard !toRead.isEmpty else { return reply(attachments: shared) }
        read(toRead, site: WebReader.wantsSite(text), then: shared)
    }

    /// Opens the links you shared on this Mac (a site's pages when you asked for the site), keeps copies with the
    /// project, then replies with the pages' text.
    private func read(_ urls: [URL], site: Bool, then shared: [ModelPart]) {
        thinking = true
        let (project, root, wasPrivate) = (project, root, isPrivate)
        task = Task {
            let outcome = await WebReader.readAll(urls, site: site, project: project, root: root, keep: !wasPrivate,
                                                  render: { await WebRenderer.render($0) }) { [unowned self] status in
                // The home model lives as long as the app.
                await MainActor.run { self.reading = status }
            }
            reading = nil
            thinking = false
            guard wasPrivate == isPrivate, !Task.isCancelled else { return }
            for note in outcome.notes {
                add(Turn(device: "mac", speaker: .note, text: note.text, files: note.files.isEmpty ? nil : note.files, project: project))
            }
            reply(attachments: shared + outcome.parts)
        }
    }

    // MARK: Attachments

    /// Something dropped on the window: a file is attached, an image (from a browser, Photos) is saved and
    /// attached, a web link goes into what you're typing.
    func drop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.attach([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data, let png = NSImage(data: data)?.pngData() else { return }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped image \(UUID().uuidString.prefix(6)).png")
                    guard (try? png.write(to: url)) != nil else { return }
                    Task { @MainActor in self.attach([url]) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.scheme?.hasPrefix("http") == true else { return }
                    Task { @MainActor in self.draft = self.draft.isEmpty ? url.absoluteString : self.draft + " " + url.absoluteString }
                }
            }
        }
        return true
    }

    func attach(_ urls: [URL]) {
        pending += urls.filter { url in !pending.contains(url) }
    }

    func removePending(_ url: URL) {
        pending.removeAll { $0 == url }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Share files with Broski. They're kept in the project's resources."
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    /// A screenshot for the next message: this window steps aside, then click a window or drag an area (Esc cancels).
    func takeScreenshot() {
        Task {
            switch await Screenshot.capture() {
            case .image(let url): attach([url])
            case .cancelled: break
            case .needsPermission: problem = "Turn on Broski in System Settings › Privacy & Security › Screen Recording, then restart Broski."
            case .failed(let message): problem = "Screenshot failed: \(message)"
            }
        }
    }

    /// Opens a shared file, or the project's folder in Finder.
    func open(file path: String) {
        NSWorkspace.shared.open(path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
    }

    func openProjectFolder() {
        guard let project else { return }
        let folder = root.appendingPathComponent("projects/\(project)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: New projects

    func createProject() {
        guard var proposal else { return }
        proposal.name = proposal.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let id = try ProjectSetup.create(proposal, root: root)
            self.proposal = nil
            library.reload()
            library.loadRegistry()
            project = id
            add(Turn(device: "mac", speaker: .topic, text: "New project: \(proposal.name)", project: id))
            let packs = (["core"] + proposal.packs).joined(separator: " + ")
            add(Turn(device: "mac", speaker: .note,
                     text: "Set up \(proposal.name): a tracker (\(packs)), a first note, and setup drafts in projects/\(id)/setup", project: id))
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func add(_ turn: Turn) {
        if isPrivate {
            privateTurns.append(turn)
            return
        }
        turns.append(turn)
        recallIndex = nil
        do {
            try store.append(turn)
        } catch {
            problem = "Couldn't keep that in your Broski folder: \(error.localizedDescription)"
        }
    }

    /// Your notes, every project's standing decisions and the conversation older than what's on screen.
    private func recallSearch() -> NotesIndex {
        if let recallIndex { return recallIndex }
        let shown = Set(turns.map(\.id))
        let older = store.recent(3000).filter { !shown.contains($0.id) }
        let decisions = ([nil] + library.projectNames.map(Optional.some)).flatMap { DecisionLog.current(root: root, project: $0) }
        let index = NotesIndex(library.index.refs + Recall.refs(turns: older, root: root) + Recall.refs(decisions: decisions, root: root)
                               + Recall.refs(webPages: WebReader.saved(root: root), root: root))
        recallIndex = index
        return index
    }

    private func reply(attachments: [ModelPart] = []) {
        let history = visibleTurns
        let said = history.last(where: { $0.speaker == .you })?.text ?? ""
        let localOnly = touchesLocalOnly(history.suffix(12).map(\.text).joined(separator: "\n"))
        // Private starts blank; otherwise recall leaves out local-only projects unless this conversation stays local anyway.
        let recall = isPrivate ? [] : Recall.find(said, index: recallSearch(), excluding: Set(history.map { "turn:\($0.id)" }),
                                                   hidden: localOnly ? [] : localOnlyProjects)
        let decisions = isPrivate ? [] : project.map { DecisionLog.current(root: root, project: $0) } ?? []
        let request = ConversationContext.build(aboutYou: isPrivate ? nil : Memory.aboutYou(root: root),
                                                page: isPrivate ? nil : project.flatMap { library.pages[$0] },
                                                project: isPrivate ? nil : project, turns: history, isPrivate: isPrivate,
                                                decisions: decisions, recall: recall, attachments: attachments,
                                                firstRun: !isPrivate && FirstRun.active(turns: history),
                                                riff: riffing ? riffRules : nil)
        // Riffs think on the deep model.
        let riff = riffing
        let role: ModelRole = deep || riff ? .deep : .everyday
        let gateway = gateway
        let project = project
        let wasPrivate = isPrivate
        thinking = true
        problem = nil
        task = Task {
            defer { thinking = false }
            do {
                let (reply, route) = try await gateway.send(request, role: role, project: project, localOnly: localOnly,
                                                            task: riff ? "riff" : "conversation")
                guard wasPrivate == isPrivate, !Task.isCancelled else { return }
                let (text, cited) = Recall.cited(in: reply.text, hits: recall)
                var sources = cited
                if route.overBudget { sources.append("Past today's limit: \(route.model)") }
                if route.substituted { sources.append("On this Mac: \(route.model)") }
                add(Turn(device: "mac", speaker: .broski, text: text, project: project, topic: topic, model: route.model,
                         sources: sources.isEmpty ? nil : sources, mode: riff ? "riff" : nil))
                if speak { speaker.say(text) }
                // No save cards while you riff: the wrap-up offers one at the end.
                if !wasPrivate, !riff { suggestSave(force: false) }
                if !wasPrivate, FirstRun.justFinished(turns: turns) {
                    let result = await firstRunDone()
                    if !result.isEmpty {
                        add(Turn(device: "mac", speaker: .note, text: "Getting to know you: \(result) See or undo it in What Broski knows.",
                                 project: self.project))
                    }
                }
            } catch where !Cancellation.isStop(error) {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            } catch {}
        }
    }

    /// Stop: drops the reply being written (or the links being read, the wrap-up, the pack draft). What you said stays.
    func stopReply() {
        guard thinking else { return }
        task?.cancel()
        task = nil
        thinking = false
        reading = nil
    }

    func stopSpeaking() { speaker.stop() }

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
        case .openVault:
            openVault(nil)
        case .toVault(let secret):
            // Straight to the vault: never sent to a model, never kept in the conversation.
            openVault(secret)
            add(Turn(device: "mac", speaker: .note, text: "Sent to your private vault (not kept here)", project: project))
        case .startRiff(let about):
            startRiff(about: about)
        case .endRiff:
            endRiff()
        case .riffRule(let rule):
            do {
                try RiffMode.addRule(rule, root: root, device: "mac")
                riffRules = RiffMode.rules(root: root)
                add(Turn(device: "mac", speaker: .note, text: "Riff rule kept: \(rule)", project: project))
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .dropRiffRule(let phrase):
            dropRiffRule(phrase)
        case .newPack(let name):
            let context = turns
            let gateway = needsModel ? nil : self.gateway
            thinking = true
            task = Task {
                defer { thinking = false }
                do {
                    let said = try await Packs.draft(name: name, context: context, gateway: gateway, root: root)
                    guard !Task.isCancelled else { return }
                    add(Turn(device: "mac", speaker: .note, text: said, project: project))
                } catch where !Cancellation.isStop(error) {
                    problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                } catch {}
            }
        case .connect(let path):
            guard let project else { return problem = "Pick the project first (the menu below), then connect its folder." }
            let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            do {
                let found = try ProjectSetup.connect(folder: folder, project: project, root: root)
                library.loadRegistry()
                var said = "Connected \(folder.path) to \(project)."
                said += found.tracker.map { " Its tracker (\($0)) is read in place, read-only." } ?? " No tracker there, so its docs are read."
                if !found.packs.isEmpty { said += " Packs that fit: \(found.packs.joined(separator: ", "))." }
                add(Turn(device: "mac", speaker: .note, text: said, project: project))
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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
        // The model isn't told local-only projects exist, so it can't file anything into them.
        let known = library.projectNames.filter { !localOnlyProjects.contains($0) }
        let standing = project.map { DecisionLog.current(root: root, project: $0) } ?? []
        guard let request = SaveCard.request(turns: turns, projects: known, decisions: standing, project: project) else {
            if force { problem = "Nothing to save yet." }
            return
        }
        let localOnly = touchesLocalOnly(request.messages.map(\.text).joined())
        let gateway = gateway
        let project = project
        Task {
            do {
                let (reply, _) = try await gateway.send(request, role: .fast, project: project, localOnly: localOnly, task: "review")
                guard let review = SaveCard.review(reply.text, catalog: library.catalog, decisions: standing) else {
                    if force { problem = "Nothing in the last few turns to save." }
                    return
                }
                // A conversation with no project yet is filed under the one it turned out to be about.
                if self.project == nil, let found = review.project, !isPrivate {
                    self.project = found
                    add(Turn(device: "mac", speaker: .topic, text: found, project: found, topic: review.topic))
                }
                if let topic = review.topic { self.topic = topic }
                if let proposed = review.newProject, proposal == nil, !isPrivate { proposal = proposed }
                if var found = review.card {
                    if found.project == nil { found.project = self.project }
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
        do {
            let saved = try SaveCard.save(card, store: library.store, root: root, device: "mac",
                                          turn: turns.last(where: { $0.speaker == .you })?.id)
            library.reload()
            add(Turn(device: "mac", speaker: .note, text: saved, project: card.project))
            self.card = nil
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
            library.reload()
        }
    }

    func removeFromCard(_ index: Int) {
        guard var card, card.items.indices.contains(index) else { return }
        card.items.remove(at: index)
        self.card = card.items.isEmpty ? nil : card
    }

    // MARK: Riff mode

    func toggleRiff() { riffing ? endRiff() : startRiff(about: nil) }

    func startRiff(about: String?) {
        guard !riffing else { return }
        card = nil
        add(RiffMode.startTurn(device: "mac", project: isPrivate ? nil : project, about: about))
    }

    /// Ends the riff and offers what came of it as one save card.
    func endRiff() {
        guard riffing else { return }
        let request = RiffMode.wrapRequest(turns: isPrivate ? privateTurns : turns)
        add(RiffMode.endTurn(device: "mac", project: isPrivate ? nil : project))
        guard let request else { return }
        let gateway = gateway
        let project = isPrivate ? nil : project
        let localOnly = touchesLocalOnly(request.messages.map(\.text).joined())
        thinking = true
        reading = "Wrapping up the riff…"
        task = Task {
            defer { thinking = false; reading = nil }
            do {
                let (reply, _) = try await gateway.send(request, role: .everyday, project: project, localOnly: localOnly, task: "wrap-up")
                guard !Task.isCancelled else { return }
                if let wrapped = RiffMode.card(from: reply.text, project: project) {
                    card = wrapped
                } else {
                    problem = "Nothing from the riff to save."
                }
            } catch where !Cancellation.isStop(error) {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            } catch {}
        }
    }

    func dropRiffRule(_ phrase: String) {
        do {
            if try RiffMode.dropRule(phrase, root: root, device: "mac") {
                riffRules = RiffMode.rules(root: root)
                add(Turn(device: "mac", speaker: .note, text: phrase.isEmpty ? "Riff rules cleared" : "Dropped the riff rule about \(phrase)", project: project))
            } else {
                problem = "No riff rule mentions “\(phrase)”."
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    func addRiffRule(_ rule: String) {
        do {
            try RiffMode.addRule(rule, root: root, device: "mac")
            riffRules = RiffMode.rules(root: root)
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func removeRiffRule(_ rule: String) {
        _ = try? RiffMode.dropRule(rule, root: root, device: "mac")
        riffRules = RiffMode.rules(root: root)
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
        // Files shared privately were never copied; keeping the conversation keeps them with the project too.
        let kept = Resources.keep(privateTurns, root: root)
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
            speaker.stop()
            voice.start()
        }
    }

    /// Esc: lets go of the mic without sending, or stops the reply, or stops reading it aloud.
    func escape() {
        if voice.listening { return voice.cancel() }
        if thinking { return stopReply() }
        stopSpeaking()
    }

    /// fn held: start listening; let go: send what was said.
    func holdStart() {
        guard !voice.listening else { return }
        speaker.stop()
        voice.start()
    }

    func holdEnd() {
        if voice.listening { toggleVoice() }
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
    var openMemory: () -> Void
    @FocusState private var focused: Bool
    @State private var dropping = false
    @State private var showingRules = false
    @State private var newRule = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isPrivate { privateBanner }
            if model.riffing { riffBanner }
            conversation
            Divider()
            composer
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        // Drop anywhere in the window: files, images from a browser or Photos, or a link.
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $dropping) { model.drop($0) }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Brand.purple, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12).fill(Brand.purple.opacity(0.06)))
                    .overlay(Text("Drop to share with Broski").font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.purple))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { focused = true }
        // Back from Settings with a key or a model: look again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.objectWillChange.send()
            voice.refreshMic()
        }
        .onExitCommand { model.escape() }
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
                .help(model.riffing ? "Riffing: brainstorming on the deep model, by the rules"
                      : model.deep ? "Replies come from the deep model" : "Replies come from the everyday model")
            voiceMenu
            if model.project != nil {
                Button { model.openProjectFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless).help("Open the project's folder: resources, setup drafts, tracker")
            }
            Button(action: openMemory) { Image(systemName: "book") }
                .buttonStyle(.borderless).help("What Broski knows")
            Button(action: openDashboard) { Image(systemName: "square.grid.2x2") }
                .buttonStyle(.borderless).help("Open the dashboard")
            Button { model.toggleRiff() } label: {
                Image(systemName: model.riffing ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    .foregroundStyle(model.riffing ? Brand.purple : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(model.thinking)
            .help(model.riffing ? "Wrap up the riff: what came of it, as one card to save"
                  : "Riff: brainstorm by the rules (yours too). Or say “let's riff about …”")
            Button { model.togglePrivate() } label: {
                Image(systemName: model.isPrivate ? "lock.fill" : "lock").foregroundStyle(model.isPrivate ? Self.privateText : .secondary)
            }
            .buttonStyle(.borderless)
            .help(model.isPrivate ? "Leave private mode" : "Go private: Broski starts blank and keeps nothing")
        }
        .padding(12)
    }

    /// Reading replies aloud: on or off, which voice, how fast, and Stop.
    private var voiceMenu: some View {
        Menu {
            Toggle("Read replies aloud", isOn: Binding(get: { model.speak }, set: { model.speak = $0; model.onSpeakChange($0) }))
            Picker("Voice", selection: Binding(get: { ReplySpeaker.voice ?? "" }, set: { ReplySpeaker.voice = $0.isEmpty ? nil : $0; model.objectWillChange.send() })) {
                Text("System voice").tag("")
                Divider()
                ForEach(ReplySpeaker.voices, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker("Speed", selection: Binding(get: { ReplySpeaker.speed }, set: { ReplySpeaker.speed = $0; model.objectWillChange.send() })) {
                ForEach(ReplySpeed.allCases, id: \.self) { Text($0.name).tag($0) }
            }
            Divider()
            Button("Stop speaking") { model.stopSpeaking() }.disabled(!model.speaking)
        } label: {
            Image(systemName: model.speak ? "speaker.wave.2.fill" : "speaker.slash")
                .foregroundStyle(model.speak ? Brand.purple : .secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(model.speak ? "Replies are read aloud: voice, speed, stop" : "Replies aren't read aloud: turn it on, pick a voice and speed")
    }

    /// Riffing: the rules in play (yours as chips, each removable), adding one, and Wrap up.
    private var riffBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Brand.purple)
                Text("Riffing. Broski builds on your ideas, brings facts and the 10x version, pushes back, keeps it honest.")
                    .font(.system(size: 12))
                Spacer()
                Menu("Moves") {
                    ForEach(RiffMode.moves, id: \.name) { move in
                        Button(move.name) { model.draft = move.ask; model.send() }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                .disabled(model.thinking)
                .help("Thinking moves: pre-mortem, first principles, 10x, ethics check and more")
                Button("Rules") { showingRules.toggle() }
                    .controlSize(.small)
                    .help("The brainstorming rules, and yours")
                    .popover(isPresented: $showingRules, arrowEdge: .bottom) { rulesPopover }
                Button("Wrap up") { model.endRiff() }
                    .buttonStyle(.borderedProminent).tint(Brand.purple).controlSize(.small)
                    .disabled(model.thinking)
                    .help("End the riff: the summary, ideas, decisions and todos, as one card to save")
            }
            if !model.riffRules.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.riffRules, id: \.self) { rule in
                            HStack(spacing: 4) {
                                Text(rule).font(.system(size: 11)).lineLimit(1)
                                Button { model.removeRiffRule(rule) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.borderless).help("Drop this rule")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Brand.purple.opacity(0.14)))
                        }
                    }
                    .padding(1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Brand.purple.opacity(0.07))
    }

    private var rulesPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EVERY RIFF").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(RiffMode.baseRules, id: \.self) { rule in
                Text("• " + rule).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            Text("YOURS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            if model.riffRules.isEmpty {
                Text("None yet. Add one here, or say “rule: …” while riffing.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(model.riffRules, id: \.self) { rule in
                HStack {
                    Text(rule).font(.system(size: 12))
                    Spacer()
                    Button("Drop") { model.removeRiffRule(rule) }.buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            HStack {
                TextField("A rule for every riff, like “no code talk”", text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRule() }
                Button("Add") { addRule() }.disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func addRule() {
        model.addRiffRule(newRule)
        newRule = ""
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
                    if model.needsModel && !model.isPrivate { modelSetup }
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
                            Text(model.reading ?? (model.deep ? "Thinking harder…" : "Thinking…")).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12)).id("thinking")
                    }
                    if let card = model.card { saveCard(card).id("card") }
                    if let proposal = model.proposal { projectCard(proposal).id("proposal") }
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

    /// No model yet: the three ways to get one.
    private var modelSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PICK A MODEL TO TALK TO").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.purple)
            Text("Broski needs a model to reply. Claude is the best at this; a model on this Mac keeps everything here.")
                .font(.system(size: 13))
            HStack(spacing: 8) {
                Button("Add a Claude key") { model.openSettings(.ai) }.buttonStyle(.borderedProminent).tint(Brand.purple)
                Button("Use a model on this Mac") { model.openSettings(.models) }
                if ModelsSettings.appleAvailable {
                    Button("Use Apple's on-device model") { model.useAppleModel() }
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).stroke(Brand.purple.opacity(0.35)))
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
            let failed = turn.text.hasPrefix("Couldn't")
            HStack(spacing: 8) {
                Label(turn.text, systemImage: failed ? "exclamationmark.triangle" : "checkmark")
                    .font(.system(size: 12)).foregroundStyle(failed ? Color.orange : Color.green)
                if let file = turn.files?.first {
                    Button("Open copy") { model.open(file: file) }
                        .buttonStyle(.borderless).font(.system(size: 11))
                        .help("The copy Broski kept in the project's resources")
                }
            }
            .padding(.leading, 34)
        case .you:
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer(minLength: 60)
                    Text(turn.text)
                        .font(.system(size: 13.5)).textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.purple.opacity(0.15)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.device != "mac" {
                    Text("on your iPhone").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let files = turn.files, !files.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { file in
                            Button { model.open(file: file) } label: {
                                Label((file as NSString).lastPathComponent, systemImage: "doc")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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

    private func projectCard(_ proposal: ProjectProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("NEW PROJECT").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.purple)
            TextField("Name", text: Binding(get: { model.proposal?.name ?? "" }, set: { model.proposal?.name = $0 }))
                .textFieldStyle(.roundedBorder).font(.system(size: 14, weight: .semibold))
            if !proposal.summary.isEmpty { Text(proposal.summary).font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                Text("Packs").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(model.packs, id: \.id) { pack in
                    let on = proposal.packs.contains(pack.id)
                    Button(pack.name) {
                        if on { model.proposal?.packs.removeAll { $0 == pack.id } } else { model.proposal?.packs.append(pack.id) }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(on ? Brand.purple : Color.primary.opacity(0.06)))
                    .foregroundStyle(on ? Color.white : .primary)
                }
            }
            if !proposal.goals.isEmpty {
                Text("First goals").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(proposal.goals, id: \.self) { Text("• " + $0).font(.system(size: 12)) }
            }
            if !proposal.questions.isEmpty {
                Text("Open questions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(proposal.questions, id: \.self) { Text("• " + $0).font(.system(size: 12)) }
            }
            HStack {
                Button("Create project") { model.createProject() }.buttonStyle(.borderedProminent).tint(Brand.purple)
                Button("Not now") { model.proposal = nil }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Text("Creates its folder, a tracker, a first note and setup drafts in your Broski folder. Repos aren't touched.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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
                if model.riffing {
                    ForEach(RiffMode.moves.filter { ["Pre-mortem", "10x it", "First principles", "Ethics check"].contains($0.name) }, id: \.name) { move in
                        chip(move.name) {
                            model.draft = move.ask
                            model.send()
                        }
                        .help(move.ask)
                    }
                    chip("Wrap up") { model.endRiff() }
                } else {
                chip("Save that") { model.suggestSave(force: true) }
                chip(model.deep ? "Back to everyday" : "Think harder") { model.deep.toggle() }
                chip("Riff") { model.startRiff(about: nil) }
                }
                if let project = model.project, !model.isPrivate, !model.riffing {
                    chip("What do you know about \(project)?") {
                        model.draft = "What do you know about \(project)?"
                        model.send()
                    }
                }
            }
            .padding(.horizontal, 1)
            if voice.listening {
                HStack(spacing: 8) {
                    MicMeter(meter: voice.meter)
                    Text("Listening on \(voice.micName)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Cancel") { voice.cancel() }
                        .buttonStyle(.borderless).font(.system(size: 12))
                        .keyboardShortcut(.cancelAction)
                        .help("Stop listening without sending (Esc)")
                }
            } else if model.speaking && !model.thinking {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Brand.purple)
                    Text("Reading the reply aloud").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.stopSpeaking() } label: { Label("Stop speaking", systemImage: "stop.fill") }
                        .buttonStyle(.borderless).font(.system(size: 12))
                        .keyboardShortcut(.cancelAction)
                        .help("Stop reading the reply aloud (Esc)")
                }
            }
            if !model.pending.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.pending, id: \.self) { url in
                        HStack(spacing: 4) {
                            Image(systemName: "doc").font(.system(size: 10))
                            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                            Button { model.removePending(url) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                                .buttonStyle(.borderless).help("Leave this file out")
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { model.chooseFiles() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).help("Share files: kept in the project's resources")
                Button { model.takeScreenshot() } label: { Image(systemName: "camera.viewfinder") }
                    .buttonStyle(.borderless).help("Screenshot: this window steps aside; click a window or drag an area (Esc cancels)")
                TextField(model.riffing ? "Riff: say what's on your mind, or “rule: …”" : "Talk to Broski, or type “note: …”",
                          text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.send() }
                if voice.transcribing { ProgressView().controlSize(.small) }
                Button("Note") { model.quickNote() }
                    .buttonStyle(.borderless).foregroundStyle(Brand.purple)
                    .help("Save what's typed as a note, without a reply")
                HStack(spacing: 1) {
                    Button { model.toggleVoice() } label: {
                        Image(systemName: voice.listening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(voice.listening ? Color.red : Brand.purple))
                    }
                    .buttonStyle(.plain)
                    .disabled(voice.transcribing)
                    .help(voice.listening ? "Done talking: send what you said" : "Talk on \(voice.micName) (or hold fn)")
                    micMenu
                }
                Button {
                    model.thinking ? model.stopReply() : model.send()
                } label: {
                    Image(systemName: model.thinking ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 26)).foregroundStyle(model.thinking || canSend ? Brand.purple : Color.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .disabled(!model.thinking && !canSend)
                .keyboardShortcut(model.thinking ? .cancelAction : nil)
                .help(model.thinking ? "Stop the reply (Esc)" : "Send (Return)")
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
                if !model.threads.isEmpty && !model.isPrivate {
                    Menu {
                        Button("The whole conversation") { model.show(thread: nil) }
                        Divider()
                        ForEach(model.threads, id: \.self) { thread in
                            Button(thread) { model.show(thread: thread) }
                        }
                    } label: {
                        Text(model.thread.map { "Thread: \($0)" } ?? "All threads").font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Show one thread of the conversation")
                }
                Text("Return sends · Esc stops · hold fn to talk · “note: …” saves without a reply")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pending.isEmpty
    }

    /// Which mic to listen on: the system's, or one you pick (kept on this Mac).
    private var micMenu: some View {
        Menu {
            Picker("Listen on", selection: Binding(get: { Microphones.chosen ?? "" }, set: { voice.choose(mic: $0.isEmpty ? nil : $0) })) {
                Text("System mic (\(voice.systemMicName))").tag("")
                Divider()
                ForEach(voice.mics, id: \.uid) { Text($0.name).tag($0.uid) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Voice settings…") { model.openSettings(.voice) }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(voice.listening)
        .help("Choose the mic: now \(voice.micName)")
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
