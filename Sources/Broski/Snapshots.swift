import AppKit
import BroskiCore
import SwiftUI

/// `Broski --snapshot <folder>` renders every screen with sample notes into PNGs,
/// for checking the UI and for screenshots. Uses a throwaway notes folder; touches nothing real.
@MainActor
enum Snapshots {
    static func run(to folder: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broski-snapshot-\(UUID().uuidString)")
        seed(root)
        let app = AppModel(root: root)
        app.library.reload()
        // The tracker is read off the main thread; wait for it so the Tracker tab has records to show.
        app.library.loadRegistry()
        let deadline = Date().addingTimeInterval(15)
        while (app.library.readingTrackers || app.library.allRecords.isEmpty) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            renderAll(app, to: folder.appendingPathComponent(name, isDirectory: true))
        }
        try? FileManager.default.removeItem(at: root)
    }

    private static func renderAll(_ app: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let size = NSSize(width: 1180, height: 740)
        func dashboard(_ selection: String?, tab: ProjectTab, _ name: String) {
            UserDefaults.standard.set(tab.rawValue, forKey: "BroskiDashboardTab")
            render(DashboardView(library: app.library, shortcut: "⌥⇧B", onCapture: {}, onScreenshot: {}, selection: selection), size: size, to: folder, name)
        }
        dashboard("strado", tab: .board, "dashboard-board")
        renderCompanion(app, to: folder)
        UserDefaults.standard.set(ProjectTab.board.rawValue, forKey: "BroskiDashboardTab")
        render(DashboardView(library: app.library, shortcut: "⌥⇧B", onCapture: {}, onScreenshot: {}, selection: "strado"),
               size: NSSize(width: 860, height: 600), to: folder, "dashboard-narrow")
        dashboard(DashboardView.allID, tab: .list, "dashboard-list")
        dashboard("strado", tab: .sessions, "dashboard-sessions")
        dashboard("strado", tab: .screenshots, "dashboard-screenshots")
        if let item = app.library.project(named: "strado")?.items.first(where: { !$0.attachments.isEmpty }) {
            render(ItemInspector(library: app.library, item: item, githubRepo: nil, onClose: {}), size: NSSize(width: 340, height: 740), to: folder, "inspector")
        }

        let model = PanelModel()
        model.projects = app.library.catalog.projects
        model.whisperState = .ready
        model.aiEnabled = true
        model.phase = .listening
        model.level = 0.7
        model.text = ""
        model.liveText = "In the strado project, add a bug: the login button overlaps the logo on narrow windows"
        model.context = ItemContext(app: "Safari", window: "Strado — Sign in", url: "https://staging.strado.app/login")
        model.attachments = app.library.project(named: "strado")?.items.flatMap(\.attachmentURLs).prefix(1).map { $0 } ?? []
        renderPanel(PanelView(model: model), to: folder, "panel-listening")
        model.holding = true
        model.text = "In the strado project, add a bug: the login button stays disabled"
        model.liveText = "after you paste the password"
        model.transcribingChunk = true
        model.attachments = []
        renderPanel(PanelView(model: model), to: folder, "panel-holding")
        model.holding = false
        model.transcribingChunk = false
        model.text = ""
        model.phase = .typing
        model.liveText = ""
        model.attachments = []
        model.context = ItemContext(app: "Xcode")
        renderPanel(PanelView(model: model), to: folder, "panel-typing")
        model.text = "In the strado project, add a bug: the login button overlaps the logo when the window is narrow"
        model.attachments = app.library.project(named: "strado")?.items.flatMap(\.attachmentURLs).prefix(1).map { $0 } ?? []
        model.context = ItemContext(app: "Brave Browser", window: "Strado — Sign in", url: "https://staging.strado.app/login")
        model.proposal = Interpretation(project: "strado", kind: "bug", title: "Login button overlaps the logo on narrow windows")
        renderPanel(PanelView(model: model), to: folder, "panel-review")
        model.proposal = nil
        model.text = ""
        model.attachments = []
        model.session = app.library.activeSession
        model.phase = .typing
        renderPanel(PanelView(model: model), to: folder, "panel-session")
        model.session = nil
        let stripe = ItemContext(app: "Brave Browser", window: "API keys – Stripe Docs", url: "https://docs.stripe.com/keys")
        model.clips = [
            Clip(text: "Restricted keys can only access the resources you allow. Use them for any service that doesn't need full access.", source: stripe),
            Clip(text: "Keys you roll stay valid for up to 7 days so you can deploy the new one first.", source: stripe),
        ]
        model.context = stripe
        model.proposal = Interpretation(title: Clip.title(for: model.clips))
        renderPanel(PanelView(model: model), to: folder, "panel-clips")
        model.clips = []
        model.proposal = nil
        model.appendTarget = app.library.project(named: "strado")?.items.first
        model.lastItem = model.appendTarget
        model.text = "Also check it on the signup screen"
        renderPanel(PanelView(model: model), to: folder, "panel-add-more")
        model.appendTarget = nil
        model.text = "Ask Priya whether the onboarding copy is final"
        model.restoredDraft = true
        renderPanel(PanelView(model: model), to: folder, "panel-draft")
        model.restoredDraft = false
        model.text = ""
        model.phase = .saved
        model.savedTitle = "Login button overlaps the logo on narrow windows"
        model.savedDetail = "strado · bug · 1 screenshot"
        renderPanel(PanelView(model: model), to: folder, "panel-saved")

        for (activity, name) in [(CaptureController.Activity.idle, "idle"), (.listening, "listening"), (.saved, "saved")] {
            let view = BubbleView(frame: NSRect(x: 0, y: 0, width: BubbleView.size, height: BubbleView.size))
            view.activity = activity
            renderView(view, size: view.frame.size, background: NSColor(white: 0.9, alpha: 1), to: folder, "bubble-\(name)")
        }
        for step in 0...5 {
            render(OnboardingView(app: app, step: step), size: NSSize(width: 640, height: 560), to: folder, "onboarding-\(step)")
        }
        for tab in SettingsTab.allCases {
            render(SettingsView(app: app, tab: tab), size: NSSize(width: 660, height: 580), to: folder, "settings-\(tab.rawValue)")
        }
    }

    /// The brain and the companion: a project's living page, Ask, the pill's cards, a riff, call notes.
    private static func renderCompanion(_ app: AppModel, to folder: URL) {
        let library = app.library
        let strado = library.project(named: "strado")?.items ?? []
        let bug = strado.first { $0.kind == .bug }?.id ?? ""
        let todo = strado.first { $0.kind == .todo }?.id ?? ""
        let idea = strado.first { $0.kind == .idea }?.id ?? ""
        let refs = library.index.refs.filter { $0.project == "strado" }
        library.usePage(ProjectPage(project: "strado", summary: "Strado is in pre-launch polish: the trading flow works end to end, and the open work is the Safari login bug and rotating keys before launch.",
            sections: [
                .init(title: "Where it stands", lines: [.init(text: "Signup and the first bot run work; QA is down to the login screen.", cites: [bug])]),
                .init(title: "Open bugs", lines: [.init(text: "Login button overlaps the logo on narrow windows (high)", cites: [bug])]),
                .init(title: "To do", lines: [.init(text: "Rotate the Stripe API keys before launch", cites: [todo])]),
                .init(title: "Ideas", lines: [.init(text: "Show a sample bot on the empty dashboard", cites: [idea])]),
                .init(title: "Decisions", lines: [.init(text: "Free tier stays at 3 bots.", cites: [])]),
                .init(title: "Open questions", lines: [.init(text: "Ship the referral program in v1 or after launch?", cites: [])]),
            ],
            actions: [
                ProposedAction(kind: .issue, title: "File the login overlap as a GitHub issue", detail: "It has a screenshot and clear steps.", cites: [bug]),
                ProposedAction(kind: .claudePrompt, title: "Hand the key rotation to Claude Code", detail: "Rotate the Stripe keys…", cites: [todo]),
            ],
            compiled: Date().addingTimeInterval(-240), source: .claude, fingerprint: ProjectPage.fingerprint(refs)))
        let size = NSSize(width: 1180, height: 740)
        UserDefaults.standard.set(ProjectTab.overview.rawValue, forKey: "BroskiDashboardTab")
        render(DashboardView(library: library, shortcut: "⌥⇧B", onCapture: {}, onScreenshot: {}, selection: "strado"), size: size, to: folder, "dashboard-overview")
        render(DashboardView(library: library, shortcut: "⌥⇧B", onCapture: {}, onScreenshot: {}, selection: DashboardView.allID), size: size, to: folder, "dashboard-home")

        let ask = AskModel(library: library, voice: app.voice)
        ask.question = "What's still open on strado before launch?"
        let sources = [bug, todo].compactMap { library.index.ref(id: $0) }
        ask.answer = Ask.Answer(markdown: "Two things: the **login button overlapping the logo** on narrow windows, which is high priority [[\(bug)]], and **rotating the Stripe keys** [[\(todo)]]. Fix the login bug first; it blocks the QA pass.", sources: sources, usedAI: true)
        // Sized the way the panel sizes it (its ideal height), so the picture matches the app.
        func askPanel() -> some View {
            AskView(model: ask, voice: app.voice).frame(width: 640).fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        renderTransparent(askPanel(), size: NSSize(width: 640, height: 330), to: folder, "ask")
        // A long answer has to scroll inside the panel, with the sources and buttons still on screen.
        ask.answer = Ask.Answer(markdown: (1...40).map { "- Point \($0): the login bug, the keys, and what blocks the QA pass [[\(bug)]]." }.joined(separator: "\n"),
                                sources: sources, usedAI: true)
        renderTransparent(askPanel(), size: NSSize(width: 640, height: 700), to: folder, "ask-long")

        let companion = app.companion
        companion.preview(.nudge(CompanionPlanner.backToProject("strado", items: library.allItems) ?? Nudge(kind: .backToProject, key: "x", project: "strado", title: "Back on strado", body: "")))
        renderTransparent(PillView(companion: companion).frame(width: 460), size: NSSize(width: 460, height: 230), to: folder, "pill-nudge")
        companion.preview(.checkIn(CheckIn.build(items: library.allItems, options: .init())))
        renderTransparent(PillView(companion: companion).frame(width: 460), size: NSSize(width: 460, height: 330), to: folder, "pill-checkin")
        companion.preview(.help(Companion.Help(state: .answer("That's a **CORS error**: the API at api.strado.app doesn't allow requests from localhost:3000.\n\n- Add `http://localhost:3000` to the allowed origins in the API config\n- You hit the same thing on staging last week [[\(bug)]]", sources), project: "strado", context: ItemContext(app: "Brave Browser", window: "Strado — Console"))))
        renderTransparent(PillView(companion: companion).frame(width: 460), size: NSSize(width: 460, height: 300), to: folder, "pill-help")
        companion.preview(nil)
        renderTransparent(PillView(companion: companion).frame(width: 460), size: NSSize(width: 460, height: 50), to: folder, "pill")
        companion.previewTucked()
        renderTransparent(PillView(companion: companion).frame(width: 460), size: NSSize(width: 460, height: 50), to: folder, "pill-tucked")

        // The home conversation, read from the Broski folder the way the real one is (seeded once, both appearances).
        let store = ConversationStore(root: app.root, device: "mac")
        if store.recent(1).isEmpty {
            let start = Date().addingTimeInterval(-600)
            let seeded: [Turn] = [
                Turn(at: start, device: "mac", speaker: .topic, text: "strado", project: "strado"),
                Turn(at: start.addingTimeInterval(5), device: "mac", speaker: .you, text: "Should I run a week of paper trading before real money, or just start small?", project: "strado"),
                Turn(at: start.addingTimeInterval(20), device: "mac", speaker: .broski, text: "Your notes say the stop-loss guard is still open, so I'd do the paper week, with a pass bar set before it starts. What would make you trust it?", project: "strado", model: "claude-sonnet-5-5"),
                Turn(at: start.addingTimeInterval(60), device: "iphone", speaker: .you, text: "Paper week first. Pass bar: fills within 0.2% of the quote. The guard lands before that.", project: "strado"),
                Turn(at: start.addingTimeInterval(80), device: "mac", speaker: .note, text: "Noted in strado: Replay the March crash day", project: "strado"),
            ]
            for turn in seeded { try? store.append(turn) }
        }
        let home = app.homeModel
        home.reload()
        home.card = SaveCard(project: "strado", items: [
            .init(kind: .decision, title: "Paper-trade one week before real money; pass bar: fills within 0.2% of the quote"),
            .init(kind: .todo, title: "Write the stop-loss guard before the paper week"),
        ])
        render(HomeView(model: home, voice: app.voice, openDashboard: {}, openMemory: {}), size: NSSize(width: 560, height: 700), to: folder, "home")
        home.card = nil
        home.proposal = ProjectProposal(name: "Set Log", summary: "Log gym sets by voice on the iPhone.", packs: ["mobile", "ai"],
                                        goals: ["Parse “bench, 60 kilos, 8 reps” offline", "Log a whole workout hands-free"],
                                        questions: ["Kilos only, or pounds too?"])
        render(HomeView(model: home, voice: app.voice, openDashboard: {}, openMemory: {}), size: NSSize(width: 560, height: 900), to: folder, "home-new-project")
        home.proposal = nil
        home.goPrivate()
        render(HomeView(model: home, voice: app.voice, openDashboard: {}, openMemory: {}), size: NSSize(width: 560, height: 420), to: folder, "home-private")
        home.discardPrivate()

        // What Broski knows, with a remembered fact and a decision that replaced an earlier one.
        try? Memory.remember("Prefers short, direct answers", root: app.root, device: "mac")
        let first = Decision(at: Date().addingTimeInterval(-3 * 86_400), device: "mac", project: "strado", text: "Start live with $500")
        try? DecisionLog.record(first, root: app.root)
        try? DecisionLog.record(Decision(device: "mac", project: "strado", text: "Paper-trade one week before real money", replaces: first.id), root: app.root)
        app.memoryModel.reload()
        render(MemoryView(model: app.memoryModel), size: NSSize(width: 560, height: 480), to: folder, "memory")
        // Someone new with no model yet: the greeting and the setup card.
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("broski-snapshot-new-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        let newcomer = HomeModel(root: fresh, library: app.library, voice: app.voice) {
            var config = BroskiConfig.defaults
            config.models = ModelSettings(providers: [], roles: [:])
            return config
        }
        render(HomeView(model: newcomer, voice: app.voice, openDashboard: {}, openMemory: {}), size: NSSize(width: 560, height: 700), to: folder, "home-first-run")
        try? FileManager.default.removeItem(at: fresh)

        // Riff mode: the banner with your rules, a riff in progress, and the riff chips.
        let riffRoot = FileManager.default.temporaryDirectory.appendingPathComponent("broski-snapshot-riff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: riffRoot, withIntermediateDirectories: true)
        try? RiffMode.addRule("No code or tech-stack talk, ideas only", root: riffRoot, device: "mac")
        try? RiffMode.addRule("Push back harder", root: riffRoot, device: "mac")
        let riffStore = ConversationStore(root: riffRoot, device: "mac")
        let riffStart = Date().addingTimeInterval(-300)
        for (i, turn) in [RiffMode.startTurn(device: "mac", project: "strado", about: "a referral program", at: riffStart),
                          Turn(at: riffStart.addingTimeInterval(10), device: "mac", speaker: .you, text: "What if every user gets a free month for each friend who signs up?", project: "strado", mode: "riff"),
                          Turn(at: riffStart.addingTimeInterval(20), device: "mac", speaker: .broski, text: "A free month is easy to explain, but your free tier already covers three bots, so only a month of Pro means anything. Two directions: reward the referrer only when the friend's bot runs a week, or let profitable traders share a results card as their link. Who refers people: traders already winning, or anyone who signs up?", project: "strado", model: ClaudeModel.deep, mode: "riff")].enumerated() {
            _ = i
            try? riffStore.append(turn)
        }
        let riffing = HomeModel(root: riffRoot, library: app.library, voice: app.voice) { BroskiConfig.defaults }
        riffing.project = "strado"
        render(HomeView(model: riffing, voice: app.voice, openDashboard: {}, openMemory: {}), size: NSSize(width: 560, height: 700), to: folder, "home-riff")
        try? FileManager.default.removeItem(at: riffRoot)

        // The private vault: making one, locked, and open (a throwaway vault, quick key stretching, no Touch ID).
        let vaultRoot = FileManager.default.temporaryDirectory.appendingPathComponent("broski-snapshot-vault-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        let newVault = VaultSession(root: vaultRoot)
        render(VaultView(model: newVault), size: NSSize(width: 720, height: 520), to: folder, "vault-create")
        if let (made, _) = try? Vault.create(root: vaultRoot, passphrase: "snapshot passphrase", iterations: 1_000) {
            try? made.save(VaultItem(title: "Spare key", body: "Under the blue pot by the back door.", updated: Date().addingTimeInterval(-3600)))
            try? made.save(VaultItem(title: "Wi-Fi at the studio", body: "Network: Studio-5G\nAsk Sam for the guest password.", updated: Date().addingTimeInterval(-86_400)))
        }
        let session = VaultSession(root: vaultRoot)
        session.useTouchID = false
        render(VaultView(model: session), size: NSSize(width: 720, height: 520), to: folder, "vault-locked")
        session.unlock(passphrase: "snapshot passphrase")
        let until = Date().addingTimeInterval(5)
        while session.state != .open && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        render(VaultView(model: session), size: NSSize(width: 720, height: 520), to: folder, "vault-open")
        session.lock()
        try? FileManager.default.removeItem(at: vaultRoot)

        // Reflection's log: one change undone, one standing.
        try? Reflection.apply(Reflection.Proposal(remember: [.init(text: "Reads replies on the phone between meetings", why: "Oct 24: said so while planning strado")],
                                                  forget: [.init(text: "Prefers short, direct answers", why: "Oct 24: asked for fuller explanations")]),
                              root: app.root, device: "mac", at: Date().addingTimeInterval(-3600))
        if let dropped = Reflection.log(root: app.root).first(where: { $0.op == "forget" }) { try? Reflection.undo(dropped, root: app.root, device: "mac") }
        try? Reflection.saveState(.init(lastRun: Date().addingTimeInterval(-3600), through: Date().addingTimeInterval(-3700)), root: app.root)
        app.memoryModel.reload()
        render(MemoryView(model: app.memoryModel, tab: 2), size: NSSize(width: 560, height: 480), to: folder, "memory-reflection")

        // Models with a local server added and a month of spending.
        var models = ModelSettings.defaults
        models.add(ModelProvider(id: "ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", local: true))
        models.set(.everyday, to: ModelChoice(provider: "ollama", model: "qwen2.5:7b"), local: true)
        models.dailyLimitUSD = 2
        let saved = app.config.models
        app.update { $0.models = models }
        for (days, model, tokens) in [(0.0, ClaudeModel.brain, 40_000), (0, ClaudeModel.fast, 90_000), (2, ClaudeModel.deep, 30_000), (0, "qwen2.5:7b", 12_000)] {
            try? UsageLog.append(UsageLog.Entry(at: Date().addingTimeInterval(-days * 86_400), device: "mac", role: .everyday, provider: "claude",
                                                model: model, project: nil, usage: ModelUsage(input: tokens, output: tokens / 10)), root: app.root)
        }
        render(ModelsSettings(app: app).frame(width: 640, height: 1180), size: NSSize(width: 640, height: 1180), to: folder, "settings-models-filled")
        app.update { $0.models = saved }

        let call = CallModel(library: library, brain: app.brain, transcription: app.transcription)
        var transcript = CallTranscript(started: Date().addingTimeInterval(-754))
        transcript.lines = [
            .init(time: Date().addingTimeInterval(-700), speaker: .them, text: "So the main thing for us is the onboarding takes too long."),
            .init(time: Date().addingTimeInterval(-690), speaker: .you, text: "How long are people taking before their first bot runs?"),
            .init(time: Date().addingTimeInterval(-680), speaker: .them, text: "About twenty minutes. Most of it is connecting the exchange."),
        ]
        call.preview(phase: .recording, transcript: transcript)
        render(CallView(model: call) {}, size: NSSize(width: 420, height: 330), to: folder, "call-recording")
        call.preview(phase: .done, transcript: transcript, notes: CallTranscript.Notes(title: "Onboarding call with Ankit", summary_markdown: "Onboarding takes about 20 minutes, mostly connecting the exchange. We agreed to try a guided connect flow.", decisions: ["Try a guided exchange-connect flow"], action_items: ["Me: sketch the guided connect flow", "Them: send screen recordings of setup"], follow_ups: ["Which exchanges matter most?"]))
        render(CallView(model: call) {}, size: NSSize(width: 420, height: 520), to: folder, "call-notes")

        // Trackers: the Tracker tab, onboarding, and adding to a tracker Broski keeps.
        UserDefaults.standard.set(ProjectTab.tracker.rawValue, forKey: "BroskiDashboardTab")
        render(DashboardView(library: library, shortcut: "⌥⇧B", onCapture: {}, onScreenshot: {}, selection: "strado"), size: size, to: folder, "dashboard-tracker")

        // A project set up in a conversation: its command center from its packs, with a build in its tracker.
        if library.project(named: "set-log") == nil {
            _ = try? ProjectSetup.create(ProjectProposal(name: "Set Log", summary: "Log gym sets by voice.", packs: ["mobile", "ai"],
                                                         goals: ["Parse a spoken set offline"], questions: []), root: app.root)
            let builds = app.root.appendingPathComponent("projects/set-log/tracker/layers/builds")
            try? "# 0.3 on TestFlight\n\nVoice parsing on device.\n".write(to: builds.appendingPathComponent("0.3.md"), atomically: true, encoding: .utf8)
            _ = try? library.store.create(ItemDraft(project: "set-log", kind: .bug, title: "Mic cuts out after 30 seconds"))
            try? DecisionLog.record(Decision(device: "mac", project: "set-log", text: "Kilos only for now"), root: app.root)
            library.reload()
            library.loadRegistry()
            let until = Date().addingTimeInterval(15)
            while (library.readingTrackers || library.project(named: "set-log")?.records.isEmpty != false) && Date() < until {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        UserDefaults.standard.set(ProjectTab.center.rawValue, forKey: "BroskiDashboardTab")
        render(DashboardView(library: library, shortcut: "⌥⇧B", onCapture: {}, onScreenshot: {}, selection: "set-log"), size: size, to: folder, "dashboard-center")
        UserDefaults.standard.set(ProjectTab.tracker.rawValue, forKey: "BroskiDashboardTab")
        if let strado = library.project(named: "strado") {
            render(OnboardSheet(library: library, project: strado) {}, size: NSSize(width: 640, height: 300), to: folder, "tracker-onboard")
            if let tracker = strado.entry?.trackers.first {
                render(NewItemSheet(library: library, project: strado, tracker: tracker) {}, size: NSSize(width: 520, height: 330), to: folder, "tracker-new-item")
            }
        }
        UserDefaults.standard.set(ProjectTab.board.rawValue, forKey: "BroskiDashboardTab")
    }

    private static func renderTransparent<V: View>(_ view: V, size: NSSize, to folder: URL, _ name: String) {
        renderView(NSHostingView(rootView: view), size: size, background: NSColor(white: 0.55, alpha: 1), to: folder, name)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to folder: URL, _ name: String) {
        // cacheDisplay skips the window's own background, so paint it into the view.
        let painted = view.background(Color(nsColor: .windowBackgroundColor))
        renderView(NSHostingView(rootView: painted), size: size, background: .windowBackgroundColor, to: folder, name)
    }

    private static func renderPanel<V: View>(_ view: V, to folder: URL, _ name: String) {
        let card = view.background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .windowBackgroundColor)))
        let height = (view as? PanelView).map { PanelView.height(for: $0.model) } ?? PanelView.height
        renderView(NSHostingView(rootView: card.padding(20)), size: NSSize(width: PanelView.width + 40, height: height + 40),
                   background: NSColor(white: 0.82, alpha: 1), to: folder, name)
    }

    private static func renderView(_ view: NSView, size: NSSize, background: NSColor, to folder: URL, _ name: String) {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40000, y: -40000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = background
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderFrontRegardless()
        for _ in 0..<6 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            view.layoutSubtreeIfNeeded()
        }
        defer { window.orderOut(nil) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    /// A few projects with notes, screenshots, and a QA session.
    private static func seed(_ root: URL) {
        let store = ItemStore(root: root)
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        let shot = root.appendingPathComponent("sample.png")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let png = sampleScreenshot().pngData() { try? png.write(to: shot) }
        let notes: [(String, NoteKind, String?, Double, ItemStatus?, Priority, [URL])] = [
            ("Login button overlaps the logo on narrow windows", .bug, "strado", 0.3, nil, .high, [shot]),
            ("Rotate the API keys before launch", .todo, "strado", 2, .doing, .urgent, []),
            ("Dark mode for the dashboard", .idea, "strado", 26, nil, .normal, []),
            ("Customers keep asking for CSV export", .note, "strado", 30, nil, .normal, []),
            ("Write the onboarding email sequence", .todo, "strado", 80, .done, .normal, []),
            ("Retry failed orders with exponential backoff", .todo, "trading-bot", 1.5, nil, .high, []),
            ("Alert on Slack after three failed fills", .idea, "trading-bot", 50, nil, .normal, []),
            ("Landing page needs social proof", .idea, "marketroom", 6, nil, .normal, []),
            ("Buy a better microphone", .note, nil, 2, nil, .low, []),
        ]
        for (title, kind, project, hours, status, priority, files) in notes {
            var draft = ItemDraft(project: project, kind: kind, status: status, priority: priority, tags: kind == .bug ? ["ui", "safari"] : [],
                                  title: title, context: ItemContext(app: "Safari", url: "https://staging.strado.app"), attachments: files)
            if kind == .note { draft.body = "Three of the last five demos asked for it. Probably a settings page export." }
            _ = try? store.create(draft, date: ago(hours))
        }
        // A tracker Broski keeps for strado, so the Tracker tab and onboarding have something real to show.
        if let tracker = try? TrackerTemplate.create(project: "strado", title: "Strado", about: "Copy-trading layer, starting on Hyperliquid.", root: root) {
            _ = try? TrackerTemplate.add(kind: "bug", title: "Fills arrive twice after a reconnect", severity: "high", tracker: tracker, root: root, date: ago(5))
            _ = try? TrackerTemplate.add(kind: "risk", title: "A leaked agent key loses the capital", severity: "crit", tracker: tracker, root: root, date: ago(30))
            _ = try? TrackerTemplate.add(kind: "task", title: "Backtest the copy rule on 2025 data", owner: "you", tracker: tracker, root: root, date: ago(10))
            _ = try? TrackerTemplate.add(kind: "decision", title: "Which venue goes live first?", tracker: tracker, root: root, date: ago(48))
            // A file no mapping reads, so the Tracker tab shows its drift strip.
            try? FileManager.default.createDirectory(at: tracker.appendingPathComponent("backtests"), withIntermediateDirectories: true)
            try? #"{"runs": []}"#.write(to: tracker.appendingPathComponent("backtests/results.json"), atomically: true, encoding: .utf8)
            let registry = ProjectRegistry(projects: [
                .init(name: "Strado", notes: "strado", about: "Copy-trading layer, starting on Hyperliquid.",
                      trackers: [TrackerSource(id: "strado", name: "Strado tracker", path: tracker.path, readOnly: false)]),
            ])
            try? registry.save(to: root)
        }
        if var session = try? store.startSession(kind: .qa, project: "strado", title: "Login flow on Safari", date: ago(1)) {
            session = (try? store.append(text: "Login button overlaps the logo when the window is narrow", files: [shot],
                                         context: ItemContext(app: "Safari", url: "https://staging.strado.app/login"), to: session, date: ago(0.9))) ?? session
            session = (try? store.append(text: "Error toast never disappears after a wrong password", files: [],
                                         context: ItemContext(app: "Safari"), to: session, date: ago(0.8))) ?? session
            _ = session
        }
        try? BroskiConfig.defaults.save(to: root.appendingPathComponent("config.json"))
    }

    /// A stand-in for a real screenshot: a fake login page.
    private static func sampleScreenshot() -> NSImage {
        NSImage(size: NSSize(width: 800, height: 500), flipped: false) { rect in
            NSColor(white: 0.97, alpha: 1).setFill(); rect.fill()
            NSColor(srgbRed: 0.49, green: 0.30, blue: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 300, y: 300, width: 200, height: 60), xRadius: 10, yRadius: 10).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(roundedRect: NSRect(x: 330, y: 280, width: 220, height: 50), xRadius: 8, yRadius: 8).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 250, y: 190, width: 300, height: 36), xRadius: 6, yRadius: 6).fill()
            NSBezierPath(roundedRect: NSRect(x: 250, y: 140, width: 300, height: 36), xRadius: 6, yRadius: 6).fill()
            return true
        }
    }
}
