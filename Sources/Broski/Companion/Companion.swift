import AppKit
import BroskiCore
import SwiftUI

/// The companion on the Mac: the pill at the top of the screen, nudges within a daily budget, the opt-in
/// morning check-in, and "Help with this". It never interrupts a capture and never takes keyboard focus.
@MainActor
final class Companion: ObservableObject {
    enum Card: Equatable {
        case nudge(Nudge)
        case checkIn(CheckIn)
        case help(Help)
    }

    struct Help: Equatable {
        enum State: Equatable {
            case looking
            case answer(String, [NoteRef])
            case failed(String)
            case needsPermission
            case needsKey
        }

        var state: State
        var project: String?
        var context: ItemContext
        var screenshot: URL?
        var saved: String?
    }

    @Published private(set) var card: Card? { didSet { updateExpanded() } }
    @Published var hovering = false { didSet { if hovering != oldValue { updateExpanded() } } }
    @Published private(set) var calling = false
    /// The pill shows its buttons: always when not tucked; otherwise while you point at it, while a card or a call
    /// needs it, and for a moment after.
    @Published private(set) var expanded = true
    private var collapseTask: Task<Void, Never>?

    /// Recomputes `expanded`, waiting a moment before tucking so the pill doesn't flicker as the pointer passes.
    func updateExpanded() {
        let wanted = !config().pillTucked || hovering || card != nil || calling
        collapseTask?.cancel()
        if wanted {
            expanded = true
        } else if expanded {
            collapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, let self else { return }
                if !(!self.config().pillTucked || self.hovering || self.card != nil || self.calling) { self.expanded = false }
            }
        }
    }

    let library: Library
    let brain: Brain
    let capture: CaptureController
    var config: () -> BroskiConfig
    var onAsk: (String?) -> Void = { _ in }
    var onRiff: (String?, String?) -> Void = { _, _ in }
    var onCall: () -> Void = {}
    var onOpenNote: (String) -> Void = { _ in }

    private var ledger: CompanionLedger
    private let ledgerURL: URL
    private var pill: CompanionPanel?
    private var timer: Timer?
    private var activationTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var helpTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init(library: Library, brain: Brain, capture: CaptureController, config: @escaping () -> BroskiConfig) {
        self.library = library
        self.brain = brain
        self.capture = capture
        self.config = config
        ledgerURL = library.store.root.appendingPathComponent(".broski/companion.json")
        ledger = CompanionLedger.load(from: ledgerURL)
    }

    func start() {
        applyConfig()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(app) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.tick() }
    }

    func applyConfig() {
        // Hiding the pill closes any card on it, so no card nobody can see holds back nudges or the check-in.
        if config().showPill { showPill() } else { close() }
        updateExpanded()
    }

    // MARK: The pill

    private func showPill() {
        makePill()
        pill?.show(focus: false)
    }

    private func makePill() {
        guard pill == nil else { return }
        pill = CompanionPanel(placement: .top, focusable: false, width: 460) { PillView(companion: self) }
        pill?.onHover = { [weak self] inside in self?.hovering = inside }
    }

    /// Whether the pill's bar shows at all (with it off, only cards appear, and only while they're needed).
    var showsBar: Bool { config().showPill }

    func setCalling(_ on: Bool) {
        calling = on
        updateExpanded()
    }

    /// Snapshots: the pill as it looks tucked.
    func previewTucked() {
        collapseTask?.cancel()
        expanded = false
    }

    // MARK: Nudges

    private func tick() {
        let config = config()
        if config.checkInEnabled, CheckIn.isDue(at: config.checkInTime, lastShown: ledger.lastCheckIn) {
            // Not over a capture or a Help answer still on its way (it would be lost); a later tick shows it.
            // Any finished card is replaced, so one left open can't swallow the day's check-in.
            guard !capture.isCapturing, !helpInProgress else { return }
            checkInNow(scheduled: true)
            return
        }
        guard config.companionMode != .quiet, card == nil, !capture.isCapturing, idleSeconds > 20 else { return }
        // Once a day at most, an old idea worth another look.
        if Calendar.current.component(.hour, from: Date()) >= 11, let nudge = CompanionPlanner.staleIdea(items: library.allItems, excluding: ledger.muted) {
            offer(nudge)
        }
    }

    private var helpInProgress: Bool {
        if case .help(let help) = card, help.state == .looking { return true }
        return false
    }

    /// Seconds since you last touched the keyboard or mouse; nudges wait for a pause.
    private var idleSeconds: Double {
        [CGEventType.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    private func appActivated(_ app: NSRunningApplication?) {
        guard config().companionMode != .quiet, app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        activationTask?.cancel()
        // Reading the window costs AppleScript and Accessibility calls; skip it once today's nudges are used up.
        guard ledger.hasBudget(for: .backToProject, mode: config().companionMode) else { return }
        activationTask = Task {
            // Wait until you've settled into the app (not just alt-tabbing through).
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !capture.isCapturing, card == nil else { return }
            let config = config()
            guard ledger.hasBudget(for: .backToProject, mode: config.companionMode) else { return }
            // A passive nudge never shows the Automation prompt: read the browser's page only if that's already allowed.
            let browser = config.captureBrowserPage ? await Self.canAutomate(app) : false
            guard !Task.isCancelled, !capture.isCapturing, card == nil else { return }
            let context = ContextCapture.snapshot(includeBrowser: browser, includeAccessibility: config.captureWindowDetails)
            guard let project = CompanionPlanner.project(for: context, catalog: library.catalog, items: library.allItems),
                  let nudge = CompanionPlanner.backToProject(project, items: library.allItems) else { return }
            offer(nudge)
        }
    }

    /// Whether macOS already lets Broski send Apple Events to this browser. Asked without prompting, off the main thread.
    private static func canAutomate(_ app: NSRunningApplication?) async -> Bool {
        guard let id = app?.bundleIdentifier, ContextCapture.browsers[id] != nil else { return false }
        return await Task.detached { () -> Bool in
            let target = NSAppleEventDescriptor(bundleIdentifier: id)
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) == OSStatus(noErr)
        }.value
    }

    private func offer(_ nudge: Nudge) {
        guard ledger.allows(nudge, mode: config().companionMode) else { return }
        ledger.shown(nudge)
        ledger.save(to: ledgerURL)
        Log.info("Nudge: \(nudge.kind.rawValue)")
        show(.nudge(nudge), for: 25)
    }

    func feedback(_ value: CompanionLedger.Feedback) {
        let nudge: Nudge?
        switch card {
        case .nudge(let n): nudge = n
        case .checkIn(let c): nudge = c.nudge
        default: nudge = nil
        }
        if let nudge {
            ledger.record(value, for: nudge)
            ledger.save(to: ledgerURL)
            Log.info("Nudge feedback: \(nudge.kind.rawValue) \(value.rawValue)")
        }
        // On the check-in this is "Turn off": it switches the setting off, where you can see it and turn it back on.
        if value == .never, case .checkIn = card { BroskiUI.app?.update { $0.checkInEnabled = false } }
        close()
    }

    /// The morning check-in, on its schedule or when you ask for it.
    func checkInNow(scheduled: Bool = false) {
        let config = config()
        let brief = CheckIn.build(items: library.allItems, options: config.checkInOptions, muted: ledger.muted)
        if scheduled {
            ledger.shown(brief.nudge)
            ledger.save(to: ledgerURL)
            if brief.isEmpty { return }
        }
        show(.checkIn(brief), for: scheduled ? 90 : nil)
    }

    // MARK: Help with this

    func helpWithThis() {
        let config = config()
        // Read what you're looking at before any Broski window appears.
        let context = ContextCapture.snapshot(includeBrowser: config.captureBrowserPage, includeAccessibility: config.captureWindowDetails)
        let project = CompanionPlanner.project(for: context, catalog: library.catalog, items: library.allItems)
        // A local-only project's window (its screenshot, title, URL and selection) never goes to Claude.
        let seen = [context.window, context.url, context.selection].compactMap { $0 }.joined(separator: "\n")
        if LocalOnly.touches(seen, projects: [project], localOnly: Set(config.localOnlyProjects), catalog: library.catalog) {
            show(.help(Help(state: .failed("\(project ?? "This project") is local only, so Help won't send this window to Claude."), project: project, context: context)), for: nil)
            return
        }
        guard let client = brain.client else {
            show(.help(Help(state: .needsKey, project: project, context: context)), for: nil)
            return
        }
        show(.help(Help(state: .looking, project: project, context: context)), for: nil)
        helpTask?.cancel()
        helpTask = Task {
            switch await WindowGrabber.frontWindow() {
            case .needsPermission:
                update(Help(state: .needsPermission, project: project, context: context))
            case .failed(let message):
                update(Help(state: .failed(message), project: project, context: context))
            case .image(let jpeg, let png):
                let shot = FileManager.default.temporaryDirectory.appendingPathComponent("broski-help-\(UUID().uuidString).png")
                try? png.write(to: shot)
                let page = project.flatMap { library.pages[$0] }
                do {
                    let text = try await ScreenHelp.help(screenshot: jpeg, mediaType: "image/jpeg", context: context,
                                                         page: page, question: nil, client: client)
                    let known = Dictionary(library.index.refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let (markdown, sources) = Ask.resolve(text, known: known)
                    update(Help(state: .answer(markdown, sources), project: project, context: context, screenshot: shot))
                    Log.info("Helped with \(context.app ?? "screen")")
                } catch where Brain.isCancellation(error) {
                    // No card will hold it: the screenshot of your window goes now.
                    try? FileManager.default.removeItem(at: shot)
                } catch {
                    update(Help(state: .failed(error.localizedDescription), project: project, context: context, screenshot: shot))
                }
            }
        }
    }

    private func update(_ help: Help) {
        guard case .help = card else {
            // The card closed while Help was still looking.
            if let shot = help.screenshot { try? FileManager.default.removeItem(at: shot) }
            return
        }
        dropHelpShot(keeping: .help(help))
        card = .help(help)
    }

    /// Deletes the Help card's screenshot (a full-size temp copy of your window) once the card closes or is
    /// replaced. A saved note has its own copy.
    private func dropHelpShot(keeping next: Card? = nil) {
        guard case .help(let help) = card, let shot = help.screenshot else { return }
        if case .help(let kept) = next, kept.screenshot == shot { return }
        try? FileManager.default.removeItem(at: shot)
    }

    /// Keeps the help (with the screenshot) as a note in the project you were working on.
    func saveHelp() {
        guard case .help(var help) = card, case .answer(let text, _) = help.state else { return }
        let title = "Help: " + (help.context.window ?? help.context.app ?? "screen")
        do {
            let item = try library.store.create(ItemDraft(project: help.project, kind: .note, title: String(title.prefix(90)),
                                                          body: text, context: help.context, attachments: help.screenshot.map { [$0] } ?? []))
            library.reload()
            help.saved = "Saved to \(item.project ?? "Inbox")"
            card = .help(help)
        } catch {
            help.saved = "Couldn't save: \(error.localizedDescription)"
            card = .help(help)
        }
    }

    // MARK: Showing cards

    private func show(_ new: Card, for seconds: Double?) {
        // A Help answer still on its way would be dropped once another card replaces it; stop the request.
        if case .help = new {} else { helpTask?.cancel() }
        dropHelpShot(keeping: new)
        card = new
        if pill == nil || !(pill?.isVisible ?? false) {
            makePill()
            pill?.show(focus: false)
        }
        dismissTask?.cancel()
        guard let seconds else { return }
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Wait while you're reading it (pointer over the card).
            while hovering, !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            guard !Task.isCancelled, card == new else { return }
            close()
        }
    }

    /// Shows a card without its side effects (snapshots).
    func preview(_ card: Card?) {
        self.card = card
    }

    func close() {
        dismissTask?.cancel()
        helpTask?.cancel()
        dropHelpShot()
        card = nil
        if !config().showPill { pill?.orderOut(nil) }
    }

    func open(_ id: String) { onOpenNote(id) }
}

// MARK: Views

struct PillView: View {
    @ObservedObject var companion: Companion

    var body: some View {
        VStack(spacing: 0) {
            if companion.showsBar { pill }
            if let card = companion.card {
                CompanionCard {
                    cardView(card).padding(14)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(duration: 0.25), value: companion.card)
        .onHover { companion.hovering = $0 }
    }

    private var pill: some View {
        HStack(spacing: 2) {
            Image(nsImage: BroskiArt.avatar(diameter: companion.expanded ? 20 : 16, crowned: false))
                .frame(width: companion.expanded ? 22 : 18, height: companion.expanded ? 22 : 18)
                .padding(.trailing, companion.expanded ? 4 : 0)
                .help(companion.expanded ? "" : "Broski: point here for Ask, Help with this, Riff, call notes and the check-in")
            if companion.expanded {
                if companion.calling {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("Call notes").font(.system(size: 11, weight: .semibold)).padding(.trailing, 6)
                }
                pillButton("sparkle.magnifyingglass", "Ask Broski (\(BroskiUI.app?.askLabel ?? "⌥⇧A"))") { companion.onAsk(nil) }
                pillButton("eye", "Help with this: Broski looks at your screen (\(BroskiUI.app?.helpLabel ?? "⌥⇧H"))") { companion.helpWithThis() }
                pillButton("bubble.left.and.text.bubble.right", "Riff: think out loud with Claude") { companion.onRiff(nil, nil) }
                pillButton(companion.calling ? "phone.down.fill" : "phone", companion.calling ? "Stop call notes" : "Take notes on a call") { companion.onCall() }
                pillButton("sun.max", "Check-in now") { companion.checkInNow() }
            }
        }
        .padding(.horizontal, companion.expanded ? 8 : 5)
        .padding(.vertical, companion.expanded ? 4 : 3)
        .background(VisualEffect().clipShape(Capsule()))
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        // Tucked, the head stays out of the way: smaller and see-through until you point at it.
        .opacity(companion.expanded ? 1 : 0.6)
        .padding(.top, 2)
        .padding(.bottom, companion.card == nil ? 8 : 0)
        .animation(.easeOut(duration: 0.18), value: companion.expanded)
    }

    private func pillButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private func cardView(_ card: Companion.Card) -> some View {
        switch card {
        case .nudge(let nudge): NudgeCard(nudge: nudge, companion: companion)
        case .checkIn(let brief): CheckInCard(brief: brief, companion: companion)
        case .help(let help): HelpCard(help: help, companion: companion)
        }
    }
}

struct NudgeCard: View {
    let nudge: Nudge
    @ObservedObject var companion: Companion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: nudge.kind == .staleIdea ? "lightbulb" : "arrow.uturn.backward.circle")
                    .foregroundStyle(Brand.purple)
                Text(nudge.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                closeButton { companion.feedback(.notNow) }
            }
            Text(nudge.body).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if !nudge.cites.isEmpty {
                HStack(spacing: 4) {
                    ForEach(nudge.cites, id: \.self) { id in
                        CitationChip(id: id, library: companion.library) { companion.open(id) }
                    }
                }
            }
            FeedbackRow(companion: companion)
        }
    }
}

struct CheckInCard: View {
    let brief: CheckIn
    @ObservedObject var companion: Companion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                Text("\(brief.greeting). \(brief.headline)").font(.system(size: 13, weight: .semibold))
                Spacer()
                closeButton { companion.close() }
            }
            if brief.isEmpty {
                Text("Nothing open in the projects you picked.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(brief.groups.prefix(4), id: \.project) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.project).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(Array(group.lines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Button { line.cites.first.map(companion.open) } label: {
                            Text("• " + line.text).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Button("Plan my day with Claude") {
                    guard let plan = plan else { return }
                    companion.onRiff(nil, plan)
                    companion.close()
                }
                .disabled(plan == nil || !companion.brain.hasKey)
                Spacer()
                FeedbackRow(companion: companion, neverLabel: "Turn off", neverHelp: "Stop the check-in (turn it back on in Settings)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12, weight: .medium))
        }
    }

    /// What goes to Claude: everything open except local-only projects.
    private var plan: String? {
        brief.planPrompt(excluding: Set(companion.config().localOnlyProjects))
    }
}

struct HelpCard: View {
    let help: Companion.Help
    @ObservedObject var companion: Companion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "eye").foregroundStyle(Brand.purple)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                closeButton { companion.close() }
            }
            switch help.state {
            case .looking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at \(help.context.app ?? "your screen")" + (help.project.map { " with your \($0) notes" } ?? "") + "…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            case .answer(let text, let sources):
                let answer = AnswerText(answer: Ask.Answer(markdown: text, sources: sources, usedAI: true)) { companion.open($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                // Short answers take only their own height; long ones scroll.
                ViewThatFits(in: .vertical) {
                    answer
                    ScrollView { answer }
                }
                .frame(maxHeight: 320)
                HStack(spacing: 14) {
                    if let saved = help.saved { Text(saved).foregroundStyle(.green) }
                    Spacer()
                    Button("Copy") { Exporter.copy(text) }
                    Button("Ask a follow-up") {
                        companion.onRiff(help.project, "I asked for help with what's on my screen (\(help.context.summary)). You said:\n\n\(text)")
                        companion.close()
                    }
                    Button("Save as note") { companion.saveHelp() }
                        .disabled(help.saved != nil)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
            case .failed(let message):
                Text("That didn't work: \(message)").font(.system(size: 12)).foregroundStyle(.orange)
            case .needsPermission:
                HStack {
                    Text("Broski needs Screen Recording to see your screen.").font(.system(size: 12))
                    Spacer()
                    Button("Open Settings") { Screenshot.openScreenRecordingSettings() }
                }
            case .needsKey:
                Text("Add a Claude key in Broski Settings › AI to use Help with this.").font(.system(size: 12))
            }
        }
    }

    private var title: String {
        "Help with " + (help.context.window.map { "“\($0.prefix(40))”" } ?? help.context.app ?? "this")
    }
}

struct FeedbackRow: View {
    @ObservedObject var companion: Companion
    var neverLabel = "Never"
    var neverHelp = "Don't show this again"

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Useful") { companion.feedback(.useful) }
            Button("Not now") { companion.feedback(.notNow) }
            Button(neverLabel) { companion.feedback(.never) }
                .help(neverHelp)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

private func closeButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.primary.opacity(0.06)))
    }
    .buttonStyle(.plain)
    .help("Close")
}
