import BroskiCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The conversation on the iPhone: the same one as on the Mac (the same files, this device's own `.iphone.jsonl`),
/// with the same memory, recall, decisions and save cards. Nothing is saved without a tap, or a "note: …".
@MainActor
final class PhoneHome: ObservableObject {
    @Published private(set) var turns: [Turn] = []
    @Published var draft = ""
    @Published private(set) var thinking = false
    /// "Reading example.com…" while links you shared are being opened.
    @Published private(set) var reading: String?
    /// Your rules for riffs, kept for every riff (the same ones as on the Mac).
    @Published private(set) var riffRules: [String] = []
    /// Opens the private vault, with a note to add once it's open.
    var openVault: (String?) -> Void = { _ in }
    @Published private(set) var isPrivate = false
    /// Leaving private mode after saying something: keep it, or let it go.
    @Published var askKeep = false
    @Published var deep = false
    @Published var project: String?
    @Published private(set) var topic: String?
    @Published var card: SaveCard?
    /// Photos and files for the next message (copies in this app's temporary folder).
    @Published var pending: [URL] = []
    /// A new project the review noticed; it's set up from the Mac, which keeps the project list.
    @Published var proposal: ProjectProposal?
    @Published var problem: String?
    @Published var speak: Bool { didSet { UserDefaults.standard.set(speak, forKey: Self.speakKey) ; if !speak { voice.stop() } } }

    private let store: PhoneStore
    private let voice = ReplyVoice()
    /// A private conversation lives only here, never on disk.
    private var privateTurns: [Turn] = []
    private var task: Task<Void, Never>?
    private var recallIndex: NotesIndex?
    private static let speakKey = "BroskiTalkSpeak"
    private var conversation: ConversationStore { ConversationStore(root: store.root, device: "iphone") }

    init(store: PhoneStore) {
        self.store = store
        speak = UserDefaults.standard.bool(forKey: Self.speakKey)
        reload()
    }

    private var lastFingerprint = ""

    /// Checks iCloud for what your Mac said since (cheap: file sizes and dates), and shows it, unless a reply is on
    /// its way. Talk calls this every few seconds while it's on screen.
    func refreshFromDisk() {
        guard !thinking else { return }
        conversation.requestLatest()
        let fingerprint = conversation.fingerprint()
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        let fresh = conversation.recent(80)
        guard fresh.map(\.id) != turns.map(\.id) else { return }
        turns = fresh
        recallIndex = nil
    }

    /// The recent conversation from every device.
    func reload() {
        guard !thinking else { return }
        turns = conversation.recent(80)
        recallIndex = nil
        riffRules = RiffMode.rules(root: store.root)
        // Someone new (nothing said, known or noted yet): Broski opens the conversation.
        if FirstRun.needed(turns: turns, aboutYou: Memory.aboutYou(root: store.root)), store.items.isEmpty, !store.sharedUnavailable {
            add(FirstRun.greetingTurn(device: "iphone"))
        }
        if project == nil { project = turns.last(where: { $0.project != nil })?.project }
        if topic == nil { topic = turns.last?.topic }
    }

    var visibleTurns: [Turn] { isPrivate ? privateTurns : turns }

    /// Riff mode is on: from its start marker until it's wrapped up (on either device).
    var riffing: Bool { RiffMode.active(turns: visibleTurns) }

    var settings: ModelSettings { store.models ?? .defaults }

    /// A model to talk to: Claude with a key, any other server the Mac set up, or Apple's on-device model.
    var canTalk: Bool {
        ModelSetup.ready(settings, claudeKey: Keychain.claudeKey != nil, appleAvailable: Self.appleAvailable)
    }

    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return AppleOnDeviceConnector.isAvailable }
        #endif
        return false
    }

    var gateway: ModelGateway {
        ModelGateway(settings: settings, root: store.root, device: "iphone") { id in
            id == "claude" ? Keychain.claudeKey : Keychain.get("model.\(id)")
        }
    }

    /// Projects the conversation can be about: local-only ones never leave the Mac's own models, so they aren't offered.
    var projects: [String] { store.projects.filter { !store.localOnly.contains($0) } }

    private func touchesLocalOnly(_ text: String) -> Bool {
        store.refreshLocalOnly()
        return LocalOnly.touches(text, projects: [project], localOnly: store.localOnly, catalog: store.catalog)
    }

    // MARK: Talking

    func send() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pending
        guard !text.isEmpty || !files.isEmpty, !thinking else { return }
        draft = ""
        if let command = ConversationCommand.parse(text, catalog: store.catalog, riffing: riffing) {
            guard case .startRiff(let about) = command else { return run(command) }
            startRiff(about: about)
            // "Let's riff about pricing": the riff opens with those words.
            guard about != nil else { return }
        }
        pending = []
        if text.isEmpty { text = "Shared " + files.map(\.lastPathComponent).joined(separator: ", ") }
        var stored: [String] = []
        if !isPrivate {
            for file in files {
                do {
                    stored.append(try Resources.add(file: file, project: project, root: store.root))
                } catch {
                    problem = "Couldn't keep \(file.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
        let turn = Turn(device: "iphone", speaker: .you, text: text, files: isPrivate ? files.map(\.path) : (stored.isEmpty ? nil : stored),
                        project: project, topic: topic, mode: riffing ? "riff" : nil)
        add(turn)
        let links = Resources.links(in: text)
        if !isPrivate, !links.isEmpty {
            try? Resources.record(links: links, project: project, turn: turn.id, root: store.root, device: "iphone")
        }
        let shared = isPrivate ? Resources.parts(forFiles: files) : Resources.parts(for: stored, root: store.root)
        let toRead = store.readLinks ? Array(links.prefix(3)) : []
        guard !toRead.isEmpty else { return reply(attachments: shared) }
        read(toRead, site: WebReader.wantsSite(text), then: shared)
    }

    /// Opens the links you shared on this iPhone (a site's pages when you asked for the site), keeps copies with the
    /// project, then replies with the pages' text.
    private func read(_ urls: [URL], site: Bool, then shared: [ModelPart]) {
        thinking = true
        let (project, root, wasPrivate) = (project, store.root, isPrivate)
        task = Task {
            let outcome = await WebReader.readAll(urls, site: site, project: project, root: root, keep: !wasPrivate,
                                                  render: { await WebRenderer.render($0) }) { [unowned self] status in
                // The conversation model lives as long as the app.
                await MainActor.run { self.reading = status }
            }
            reading = nil
            thinking = false
            guard wasPrivate == isPrivate, !Task.isCancelled else { return }
            for note in outcome.notes {
                add(Turn(device: "iphone", speaker: .note, text: note.text, files: note.files.isEmpty ? nil : note.files, project: project))
            }
            store.reload()
            reply(attachments: shared + outcome.parts)
        }
    }

    /// Words from the mic: into the box, and sent.
    func voiceDone(_ text: String) {
        addHeard(text)
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { send() }
    }

    /// Words from a recording that ended without being sent (leaving the tab, the mic taken away): they wait in the box.
    func addHeard(_ text: String) {
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        draft = draft.isEmpty ? heard : draft + " " + heard
    }

    func stopSpeaking() { voice.stop() }

    private func add(_ turn: Turn) {
        if isPrivate { return privateTurns.append(turn) }
        turns.append(turn)
        recallIndex = nil
        do {
            try conversation.append(turn)
        } catch {
            problem = "Couldn't keep that in your Broski folder: \(error.localizedDescription)"
        }
    }

    /// Notes, standing decisions and the conversation older than what's on screen.
    private func recallSearch() -> NotesIndex {
        if let recallIndex { return recallIndex }
        let shown = Set(turns.map(\.id))
        let older = conversation.recent(3000).filter { !shown.contains($0.id) }
        let decisions = ([nil] + store.projects.map(Optional.some)).flatMap { DecisionLog.current(root: store.root, project: $0) }
        let index = NotesIndex(store.index.refs + Recall.refs(turns: older, root: store.root) + Recall.refs(decisions: decisions, root: store.root)
                               + Recall.refs(webPages: WebReader.saved(root: store.root), root: store.root))
        recallIndex = index
        return index
    }

    private func reply(attachments: [ModelPart] = []) {
        let history = visibleTurns
        let said = history.last(where: { $0.speaker == .you })?.text ?? ""
        let localOnly = touchesLocalOnly(history.suffix(12).map(\.text).joined(separator: "\n"))
        let recall = isPrivate ? [] : Recall.find(said, index: recallSearch(), excluding: Set(history.map { "turn:\($0.id)" }),
                                                   hidden: localOnly ? [] : store.localOnly)
        let decisions = isPrivate ? [] : project.map { DecisionLog.current(root: store.root, project: $0) } ?? []
        let request = ConversationContext.build(aboutYou: isPrivate ? nil : Memory.aboutYou(root: store.root),
                                                page: isPrivate ? nil : project.flatMap { store.pages[$0] },
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
                let (reply, route) = try await gateway.send(request, role: role, project: project, localOnly: localOnly)
                guard wasPrivate == isPrivate else { return }
                let (text, cited) = Recall.cited(in: reply.text, hits: recall)
                var sources = cited
                if route.overBudget { sources.append("Past today's limit: \(route.model)") }
                if route.substituted { sources.append("On this iPhone: \(route.model)") }
                add(Turn(device: "iphone", speaker: .broski, text: text, project: project, topic: topic, model: route.model,
                         sources: sources.isEmpty ? nil : sources, mode: riff ? "riff" : nil))
                if speak { voice.say(text) }
                // No save cards while you riff: the wrap-up offers one at the end.
                if !wasPrivate, !riff { suggestSave(force: false) }
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func run(_ command: ConversationCommand) {
        switch command {
        case .note(let text): quickNote(text)
        case .goPrivate: goPrivate()
        case .leavePrivate: leavePrivate()
        case .thinkHarder: deep = true
        case .saveThat: suggestSave(force: true)
        case .remember(let fact):
            guard !isPrivate else { return problem = "Private conversations keep nothing, so that isn't remembered." }
            do {
                try Memory.remember(fact, root: store.root, device: "iphone")
                add(Turn(device: "iphone", speaker: .note, text: "Remembered: \(fact)", project: project))
            } catch {
                problem = "Couldn't remember that: \(error.localizedDescription)"
            }
        case .forget(let phrase):
            if (try? Memory.forget(phrase, root: store.root, device: "iphone")) == true {
                add(Turn(device: "iphone", speaker: .note, text: "Forgotten.", project: project))
            } else {
                problem = "Nothing Broski remembers matches that."
            }
        case .switchProject(let name):
            project = name
            add(Turn(device: "iphone", speaker: .topic, text: name, project: name))
        case .connect:
            problem = "Folders are connected from the Mac: say it in the conversation there."
        case .openVault:
            openVault(nil)
        case .toVault(let secret):
            // Straight to the vault: never sent to a model, never kept in the conversation.
            openVault(secret)
            add(Turn(device: "iphone", speaker: .note, text: "Sent to your private vault (not kept here)", project: project))
        case .startRiff(let about):
            startRiff(about: about)
        case .endRiff:
            endRiff()
        case .riffRule(let rule):
            do {
                try RiffMode.addRule(rule, root: store.root, device: "iphone")
                riffRules = RiffMode.rules(root: store.root)
                add(Turn(device: "iphone", speaker: .note, text: "Riff rule kept: \(rule)", project: project))
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        case .dropRiffRule(let phrase):
            if (try? RiffMode.dropRule(phrase, root: store.root, device: "iphone")) == true {
                riffRules = RiffMode.rules(root: store.root)
                add(Turn(device: "iphone", speaker: .note, text: phrase.isEmpty ? "Riff rules cleared" : "Dropped the riff rule about \(phrase)", project: project))
            } else {
                problem = "No riff rule mentions “\(phrase)”."
            }
        case .newPack(let name):
            let context = turns
            let gateway = canTalk ? self.gateway : nil
            thinking = true
            Task {
                defer { thinking = false }
                do {
                    let said = try await Packs.draft(name: name, context: context, gateway: gateway, root: store.root)
                    add(Turn(device: "iphone", speaker: .note, text: said, project: project))
                } catch {
                    problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    // MARK: Saving

    /// "note: …": saved at once, filed by the rules, no reply.
    func quickNote(_ text: String) {
        let decision = Rules.interpret(text, catalog: store.catalog, activeSession: nil)
        let target = project ?? (decision.project.isEmpty ? nil : decision.project)
        do {
            let item = try store.store.create(ItemDraft(
                project: target, kind: NoteKind(rawValue: decision.kind) ?? .note,
                priority: Priority(rawValue: decision.priority) ?? .normal, tags: decision.tags,
                title: decision.title.isEmpty ? String(text.prefix(90)) : decision.title, body: decision.body,
                context: ItemContext(app: "Broski conversation")))
            store.reload()
            add(Turn(device: "iphone", speaker: .note, text: "Noted in \(item.project ?? "the inbox"): \(item.title)", project: item.project))
        } catch {
            problem = "Couldn't save the note: \(error.localizedDescription)"
        }
    }

    func suggestSave(force: Bool) {
        let standing = project.map { DecisionLog.current(root: store.root, project: $0) } ?? []
        guard let request = SaveCard.request(turns: turns, projects: projects, decisions: standing, project: project) else {
            if force { problem = "Nothing to save yet." }
            return
        }
        let localOnly = touchesLocalOnly(request.messages.map(\.text).joined())
        let gateway = gateway
        let project = project
        Task {
            do {
                let (reply, _) = try await gateway.send(request, role: .fast, project: project, localOnly: localOnly)
                guard let review = SaveCard.review(reply.text, catalog: store.catalog, decisions: standing) else {
                    if force { problem = "Nothing in the last few turns to save." }
                    return
                }
                if self.project == nil, let found = review.project, !isPrivate {
                    self.project = found
                    add(Turn(device: "iphone", speaker: .topic, text: found, project: found, topic: review.topic))
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
            let saved = try SaveCard.save(card, store: store.store, root: store.root, device: "iphone",
                                          turn: turns.last(where: { $0.speaker == .you })?.id)
            add(Turn(device: "iphone", speaker: .note, text: saved, project: card.project))
            self.card = nil
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
        store.reload()
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
        add(RiffMode.startTurn(device: "iphone", project: isPrivate ? nil : project, about: about))
    }

    /// Ends the riff and offers what came of it as one save card.
    func endRiff() {
        guard riffing else { return }
        let request = RiffMode.wrapRequest(turns: visibleTurns)
        add(RiffMode.endTurn(device: "iphone", project: isPrivate ? nil : project))
        guard let request else { return }
        let gateway = gateway
        let project = isPrivate ? nil : project
        let localOnly = touchesLocalOnly(request.messages.map(\.text).joined())
        thinking = true
        reading = "Wrapping up the riff…"
        Task {
            defer { thinking = false; reading = nil }
            do {
                let (reply, _) = try await gateway.send(request, role: .everyday, project: project, localOnly: localOnly)
                if let wrapped = RiffMode.card(from: reply.text, project: project) { card = wrapped } else { problem = "Nothing from the riff to save." }
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func removeRiffRule(_ rule: String) {
        _ = try? RiffMode.dropRule(rule, root: store.root, device: "iphone")
        riffRules = RiffMode.rules(root: store.root)
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
        if privateTurns.contains(where: { $0.speaker == .you }) { askKeep = true } else { isPrivate = false }
    }

    func keepPrivate() {
        let kept = Resources.keep(privateTurns, root: store.root)
        privateTurns = []
        isPrivate = false
        askKeep = false
        add(Turn(device: "iphone", speaker: .topic, text: "Kept from a private conversation", project: project))
        kept.forEach(add)
    }

    func discardPrivate() {
        privateTurns = []
        isPrivate = false
        askKeep = false
    }

    // MARK: Attachments

    /// Photos come in as JPEG, at most 1568 px on the long side (what Claude reads best), in a temporary file.
    func attach(photo data: Data) {
        guard let image = UIImage(data: data) else { return problem = "Couldn't read that photo." }
        let scale = min(1, 1568 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Photo \(stamp)-\(pending.count + 1).jpg")
        do {
            try jpeg.write(to: url)
            pending.append(url)
        } catch {
            problem = "Couldn't attach that photo: \(error.localizedDescription)"
        }
    }

    /// A file from Files: copied out of its security scope into a temporary file.
    func attach(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            pending.append(copy)
        } catch {
            problem = "Couldn't attach \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removePending(_ url: URL) { pending.removeAll { $0 == url } }

    /// A file a turn points at: in the Broski folder, or (private mode) where it was shared from.
    func url(for path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : store.root.appendingPathComponent(path)
    }
}

// MARK: Screen

struct TalkScreen: View {
    @ObservedObject var model: PhoneHome
    @ObservedObject var store: PhoneStore
    @ObservedObject var recorder: Recorder
    var onRiff: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.isPrivate { privateBanner }
                if model.riffing { riffBanner }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if !model.canTalk {
                                Label("Add your Claude key in Settings › Claude to talk to Broski.", systemImage: "key")
                                    .font(.callout).foregroundStyle(.orange)
                            } else if model.visibleTurns.isEmpty {
                                Text(model.isPrivate
                                     ? "Private: Broski starts blank, reads none of your notes or memory, and keeps nothing unless you choose to when you leave."
                                     : "Talk about anything: a project, an idea, a photo. Broski remembers the conversation, and offers to save what matters.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            ForEach(model.visibleTurns) { turn in row(turn).id(turn.id) }
                            if model.thinking {
                                HStack(spacing: 8) { ProgressView(); Text(model.reading ?? "Thinking…").foregroundStyle(.secondary) }.font(.callout)
                            }
                            if let card = model.card { cardView(card) }
                            if let proposal = model.proposal { proposalView(proposal) }
                            if let problem = model.problem ?? recorder.problem {
                                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                    .onChange(of: model.visibleTurns.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: model.card) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                }
                Divider()
                composer
            }
            .navigationTitle(model.isPrivate ? "Private" : (model.project ?? "Broski"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert("Keep this conversation?", isPresented: $model.askKeep) {
                Button("Keep it") { model.keepPrivate() }
                Button("Let it go", role: .destructive) { model.discardPrivate() }
                Button("Stay private", role: .cancel) {}
            } message: {
                Text("Keeping it adds it to your conversation and its files to the project. Letting it go leaves no trace.")
            }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 4, matching: .images)
        .onChange(of: photos) { _, items in
            guard !items.isEmpty else { return }
            photos = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { model.attach(photo: data) }
                }
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.pdf, .plainText, .image, .json, .commaSeparatedText],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach(model.attach(file:)) }
        }
        .onAppear { model.reload() }
        .onDisappear { model.stopSpeaking() }
        // Talking on both devices: what your Mac says shows up here within a few seconds of iCloud bringing it.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                model.refreshFromDisk()
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Project", selection: Binding(get: { model.project ?? "" }, set: { model.project = $0.isEmpty ? nil : $0 })) {
                    Text("No project").tag("")
                    ForEach(model.projects, id: \.self) { Text($0).tag($0) }
                }
            } label: {
                Image(systemName: "folder")
            }
            .accessibilityLabel("Project")
            .disabled(model.isPrivate)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.togglePrivate() } label: {
                Image(systemName: model.isPrivate ? "lock.fill" : "lock.open")
            }
            .accessibilityLabel(model.isPrivate ? "Leave private" : "Go private")
            Menu {
                Toggle(isOn: $model.deep) { Label("Think harder", systemImage: "brain") }
                Toggle(isOn: $model.speak) { Label("Read replies aloud", systemImage: "speaker.wave.2") }
                Button { model.suggestSave(force: true) } label: { Label("Save that", systemImage: "tray.and.arrow.down") }
                    .disabled(model.isPrivate || model.riffing)
                Divider()
                Button { onRiff() } label: {
                    Label(model.riffing ? "Wrap up the riff" : "Riff", systemImage: "bubble.left.and.bubble.right")
                }
                if model.riffing {
                    Menu {
                        ForEach(RiffMode.moves, id: \.name) { move in
                            Button(move.name) { model.draft = move.ask; model.send() }
                        }
                    } label: { Label("Thinking moves", systemImage: "sparkles") }
                }
                NavigationLink { AskScreen(store: store, recorder: recorder, onRiff: onRiff) } label: {
                    Label("Search my notes", systemImage: "magnifyingglass")
                }
                Button { model.openVault(nil) } label: { Label("Private vault", systemImage: "lock.shield") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    /// Riffing: your rules as chips (each removable) and Wrap up. Say “rule: …” to add one.
    private var riffBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                Text("Riffing. Say “rule: …” to add a rule.").font(.footnote.weight(.semibold))
                Spacer()
                Button("Wrap up") { model.endRiff() }.font(.footnote.weight(.semibold)).disabled(model.thinking)
            }
            .foregroundStyle(Brand.purple)
            if !model.riffRules.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.riffRules, id: \.self) { rule in
                            HStack(spacing: 4) {
                                Text(rule).font(.caption).lineLimit(1)
                                Button { model.removeRiffRule(rule) } label: { Image(systemName: "xmark").font(.caption2) }
                                    .accessibilityLabel("Drop this rule")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Brand.purple.opacity(0.14)))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Brand.purple.opacity(0.07))
    }

    private var privateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text("Private. Nothing is read or kept.").font(.footnote.weight(.semibold))
            Spacer()
            Button("Leave") { model.leavePrivate() }.font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Brand.privateText)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Brand.privateText.opacity(0.12))
    }

    // MARK: Turns

    @ViewBuilder private func row(_ turn: Turn) -> some View {
        switch turn.speaker {
        case .you, .broski:
            VStack(alignment: turn.speaker == .you ? .trailing : .leading, spacing: 4) {
                HStack {
                    if turn.speaker == .you { Spacer(minLength: 48) }
                    Text((try? AttributedString(markdown: turn.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(turn.text))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16).fill(turn.speaker == .you ? Brand.purple.opacity(0.15) : Color(.secondarySystemBackground)))
                        .fixedSize(horizontal: false, vertical: true)
                    if turn.speaker == .broski { Spacer(minLength: 48) }
                }
                if turn.speaker == .you, turn.device != "iphone" {
                    Text("on your Mac").font(.caption2).foregroundStyle(.secondary)
                }
                if let files = turn.files, !files.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { path in fileChip(model.url(for: path)) }
                    }
                }
                if let sources = turn.sources, !sources.isEmpty {
                    Text(sources.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: turn.speaker == .you ? .trailing : .leading)
        case .note:
            Label(turn.text, systemImage: turn.text.hasPrefix("Couldn't") ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.footnote).foregroundStyle(turn.text.hasPrefix("Couldn't") ? Color.orange : Color.secondary)
        case .topic:
            Text(turn.text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 6)
        }
    }

    @ViewBuilder private func fileChip(_ url: URL) -> some View {
        if ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(url.pathExtension.lowercased()), let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Label(url.lastPathComponent, systemImage: url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc")
                .font(.caption).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(Color(.secondarySystemBackground)))
        }
    }

    // MARK: Cards

    private func cardView(_ card: SaveCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SAVE TO \((card.project ?? "the inbox").uppercased())?").font(.caption.weight(.semibold)).foregroundStyle(Brand.purple)
            ForEach(Array(card.items.enumerated()), id: \.offset) { i, entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: symbol(entry.kind)).foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.callout)
                        if entry.replaces != nil { Text("Replaces an earlier decision").font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { model.removeFromCard(i) } label: { Image(systemName: "xmark").font(.caption) }
                        .accessibilityLabel("Leave this one out")
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Save") { model.saveCard() }.buttonStyle(.borderedProminent).tint(Brand.purple)
                Button("Not now") { model.card = nil }.buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).stroke(Brand.purple.opacity(0.35)))
    }

    private func symbol(_ kind: SaveCard.Entry.Kind) -> String {
        switch kind {
        case .decision: return "signpost.right"
        case .todo: return "checkmark.circle"
        case .bug: return "ladybug"
        case .idea: return "lightbulb"
        case .note: return "note.text"
        }
    }

    private func proposalView(_ proposal: ProjectProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOUNDS LIKE A NEW PROJECT").font(.caption.weight(.semibold)).foregroundStyle(Brand.purple)
            Text(proposal.name).font(.headline)
            Text(proposal.summary).font(.callout).foregroundStyle(.secondary)
            Text("Set it up from the conversation on your Mac, which keeps the project list.").font(.caption).foregroundStyle(.secondary)
            Button("Dismiss") { model.proposal = nil }.font(.callout)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pending, id: \.self) { url in
                            ZStack(alignment: .topTrailing) {
                                fileChip(url)
                                Button { model.removePending(url) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .accessibilityLabel("Remove")
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            if recorder.isRecording {
                HStack(alignment: .top, spacing: 8) {
                    LevelDot(level: recorder.level)
                    Text(recorder.transcript.isEmpty ? "Listening · tap stop when you're done" : recorder.transcript)
                        .font(.callout).foregroundStyle(recorder.transcript.isEmpty ? .secondary : .primary).lineLimit(4)
                }
            } else if recorder.finishing {
                Label("Writing it out…", systemImage: "waveform").font(.callout).foregroundStyle(Brand.purple)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { choosingPhotos = true } label: { Label("Photos", systemImage: "photo") }
                    Button { choosingFiles = true } label: { Label("Files", systemImage: "doc") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 18, weight: .semibold)).frame(width: 36, height: 44)
                }
                .accessibilityLabel("Attach")
                TextField(model.riffing ? "Riff: say what's on your mind…" : model.isPrivate ? "Private…" : "Talk to Broski…",
                          text: $model.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.vertical, 8)
                if (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pending.isEmpty), !recorder.isRecording {
                    Button { model.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).foregroundStyle(Brand.purple)
                    }
                    .disabled(model.thinking)
                    .accessibilityLabel("Send")
                }
                Button { toggleMic() } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(recorder.isRecording ? Color.red : Brand.purple))
                }
                .disabled(recorder.finishing || (!recorder.isRecording && model.thinking))
                .accessibilityLabel(recorder.isRecording ? "Done talking" : "Talk")
            }
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemBackground)))
        }
        .padding(12)
        .disabled(!model.canTalk)
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

    /// Starts listening (Siri, the Action Button, Control Center).
    func listen() {
        guard model.canTalk, !recorder.isRecording else { return }
        model.stopSpeaking()
        Task { await recorder.start() }
    }
}
