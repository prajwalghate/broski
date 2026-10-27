import AppKit
import BroskiCore
import BroskiWhisper
import Combine
import ServiceManagement
import SwiftUI

/// Owns Broski's parts and windows, and applies settings the moment they change.
/// Broski lives in the menu bar; while one of its windows is open it also shows in the Dock.
@MainActor
final class AppModel: NSObject, ObservableObject, NSWindowDelegate {
    static let onboardingVersion = 2
    private static let onboardingKey = "BroskiOnboardingVersion"

    let root: URL
    let configURL: URL
    let store: ItemStore
    let brain: Brain
    let transcription: Transcription
    let library: Library
    let capture: CaptureController

    @Published private(set) var config: BroskiConfig { didSet { WaitingOn.ownerAliases = config.ownerAliases } }
    @Published var configWarning: String?
    /// False while config.json can't be read: every project counts as local only and settings aren't saved over it.
    private(set) var configTrusted = true
    @Published private(set) var shortcutLabel = "⌥⇧B"
    @Published private(set) var shortcutProblem: String?
    @Published private(set) var screenshotLabel = "⌥⇧S"
    @Published private(set) var clipLabel = "⌥⇧C"
    @Published private(set) var askLabel = "⌥⇧A"
    @Published private(set) var helpLabel = "⌥⇧H"

    // The companion
    private(set) lazy var voice = VoiceInput(capture: capture)
    private(set) lazy var companion = Companion(library: library, brain: brain, capture: capture) { [weak self] in
        self?.config ?? .defaults
    }
    private lazy var askModel = AskModel(library: library, voice: voice)
    private var askPanel: CompanionPanel?
    /// Speech from a mic that closing Ask stopped: the next open keeps the question instead of wiping it.
    private var askKeepsDraft = false
    private(set) lazy var homeModel: HomeModel = {
        let model = HomeModel(root: root, library: library, voice: voice) { [weak self] in self?.config ?? .defaults }
        model.onSpeakChange = { [weak self] on in self?.update { $0.speakReplies = on } }
        model.openSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        model.useAppleModel = { [weak self] in
            self?.update { $0.models = ModelSetup.appleOnDevice($0.models ?? .defaults) }
        }
        model.firstRunDone = { [weak self] in await self?.reflector.run() ?? "" }
        model.openVault = { [weak self] note in self?.showVault(adding: note) }
        // Your iPhone's side of the conversation shows up in the open window as iCloud brings it.
        library.onConversationsChanged = { [weak model] in model?.refreshFromDisk() }
        return model
    }()
    private lazy var callModel = CallModel(library: library, brain: brain, transcription: transcription)
    private var askHotKey: HotKey?
    private var helpHotKey: HotKey?

    private var bubble: BubbleController?
    private var hotKey: HotKey?
    /// Quick notes while the conversation is the front door.
    private var noteHotKey: HotKey?
    private var screenshotHotKey: HotKey?
    private var clipHotKey: HotKey?
    private let services = BroskiServices()
    private var windows: [String: NSWindow] = [:]
    var onStatusChange: (() -> Void)?
    /// The menu shown when right-clicking the floating button.
    var quickMenu: (() -> NSMenu)?

    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: Notes folder

    private static let notesFolderKey = "BroskiNotesFolder"

    /// The notes folder you picked, when it isn't there right now (a drive not mounted, iCloud signed out).
    static var missingNotesFolder: String? {
        guard let path = UserDefaults.standard.string(forKey: notesFolderKey), !FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Asks before Broski would quietly use ~/Broski instead: new notes there would be missing from your real folder,
    /// with default settings (no local-only projects).
    static func resolveMissingNotesFolder() {
        while let path = missingNotesFolder {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Broski can't find your notes folder"
            alert.informativeText = "\(path) isn't there right now. If it's on a drive or in iCloud Drive, connect it and try again."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Choose Folder…")
            alert.addButton(withTitle: "Use ~/Broski This Time")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                continue
            case .alertSecondButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Use This Folder"
                if panel.runModal() == .OK, let url = panel.url { UserDefaults.standard.set(url.path, forKey: notesFolderKey) }
            default:
                return  // notesRoot falls back for this run; the choice is asked again next launch.
            }
        }
    }
    static let localRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Broski", isDirectory: true)
    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)

    /// ~/Broski, or iCloud Drive › Broski once notes are shared with the iPhone.
    static var notesRoot: URL {
        if let path = UserDefaults.standard.string(forKey: notesFolderKey), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return localRoot
    }

    var syncsWithPhone: Bool { root.path.hasPrefix(Self.iCloudDrive.path) }
    var iCloudDriveAvailable: Bool { FileManager.default.fileExists(atPath: Self.iCloudDrive.path) }

    /// Moves every note into iCloud Drive › Broski, where the iPhone app can open the same folder, then restarts Broski there.
    func moveNotesToICloud(keptDraft: Bool = false) {
        // An open note is kept as a draft first, so it moves (and comes back) with the rest.
        if capture.isCapturing, !keptDraft {
            Task { await capture.keepDraftForQuit(); moveNotesToICloud(keptDraft: true) }
            return
        }
        let destination = Self.iCloudDrive.appendingPathComponent("Broski", isDirectory: true)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) {
                let existing = (try? fm.contentsOfDirectory(atPath: destination.path))?.filter { $0 != ".DS_Store" } ?? []
                guard existing.allSatisfy({ $0.hasPrefix(".") }) else {
                    configWarning = "iCloud Drive already has a Broski folder with files in it. Move or rename it, then try again."
                    return
                }
                // Hidden files can still be someone's (an old trash, a config iCloud hasn't fetched): set the folder aside.
                if existing.isEmpty {
                    try fm.removeItem(at: destination)
                } else {
                    let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
                    try fm.moveItem(at: destination, to: destination.deletingLastPathComponent().appendingPathComponent("Broski (old \(stamp))"))
                }
            }
            capture.engine.stop()
            try fm.moveItem(at: root, to: destination)
            UserDefaults.standard.set(destination.path, forKey: Self.notesFolderKey)
            Log.fileURL = destination.appendingPathComponent(".broski/broski.log")
            Log.info("Notes moved to iCloud Drive for iPhone sync")
            Screenshot.relaunchBroski()
        } catch {
            configWarning = "Couldn't move your notes: \(error.localizedDescription)"
        }
    }

    func useNotesFolder(_ destination: URL, keptDraft: Bool = false) {
        if capture.isCapturing, !keptDraft {
            Task { await capture.keepDraftForQuit(); useNotesFolder(destination, keptDraft: true) }
            return
        }
        let fm = FileManager.default
        let source = root.resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard target != source else { return }
        let hasNotes = ["inbox", "projects"].contains { fm.fileExists(atPath: destination.appendingPathComponent($0).path) }
        if !hasNotes {
            // Check everything before moving anything, so a move can't stop halfway.
            guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else {
                configWarning = "Pick a folder outside your notes folder, and not one that contains it."
                return
            }
            let existing = (try? fm.contentsOfDirectory(atPath: target.path)) ?? []
            guard existing.allSatisfy({ $0.hasPrefix(".") }) else {
                configWarning = "That folder isn't empty and has no Broski notes. Pick an empty folder, or one with Broski notes."
                return
            }
            let children: [URL]
            do {
                // Finder's .DS_Store stays behind: nearly every folder has one, and it isn't a note.
                children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent != ".DS_Store" }
            } catch {
                configWarning = "Couldn't read your notes folder: \(error.localizedDescription)"
                return
            }
            let clashes = children.map(\.lastPathComponent).filter { existing.contains($0) }
            guard clashes.isEmpty else {
                configWarning = "That folder already has \(clashes.joined(separator: ", ")). Pick an empty folder, or one with Broski notes."
                return
            }
            capture.engine.stop()
            // All or nothing: if one item can't move, the ones that did go back, so no notes are stranded.
            var moved: [(from: URL, to: URL)] = []
            do {
                for child in children {
                    let to = target.appendingPathComponent(child.lastPathComponent)
                    try fm.moveItem(at: child, to: to)
                    moved.append((from: child, to: to))
                }
            } catch {
                let reason = error.localizedDescription
                var stuck: [String] = []
                for item in moved.reversed() {
                    do { try fm.moveItem(at: item.to, to: item.from) } catch { stuck.append(item.to.lastPathComponent) }
                }
                if !capture.isCapturing { capture.engine.resumeIdle() }
                configWarning = stuck.isEmpty
                    ? "Couldn't use that folder (\(reason)). Your notes stayed where they were."
                    : "Couldn't use that folder (\(reason)), and \(stuck.joined(separator: ", ")) couldn't be moved back from \(target.path)."
                return
            }
        }
        UserDefaults.standard.set(destination.path, forKey: Self.notesFolderKey)
        Log.fileURL = destination.appendingPathComponent(".broski/broski.log")
        Log.info("Notes folder is now \(destination.path)")
        Screenshot.relaunchBroski()
    }

    init(root: URL) {
        self.root = root
        configURL = root.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".broski"), withIntermediateDirectories: true)
        var (loaded, warning, trusted) = BroskiConfig.load(at: configURL)
        // An unreadable config can't say which projects are local only, so all of them are until it can.
        if !trusted {
            loaded.localOnlyProjects = Array(Set(loaded.localOnlyProjects + ItemStore(root: root).projectNames()
                                                 + ProjectRegistry.load(from: root).projects.map(\.notes))).sorted()
        }
        config = loaded
        WaitingOn.ownerAliases = loaded.ownerAliases
        configTrusted = trusted
        configWarning = warning
        store = ItemStore(root: root)
        brain = Brain()
        transcription = Transcription()
        library = Library(store: store, brain: brain)
        capture = CaptureController(config: loaded, library: library, brain: brain, transcription: transcription)
        super.init()
        transcription.settings = { [weak self] in (self?.config.speechEngine ?? "auto", self?.config.locale ?? "auto") }
        library.projectRoots = { [weak self] in self?.config.projectRootURLs ?? [] }
        library.brainSettings = { [weak self] in (self?.config.autoCompilePages ?? true, Set(self?.config.localOnlyProjects ?? [])) }
        brain.localOnly = { [weak self] in Set(self?.config.localOnlyProjects ?? []) }
        // Calls that don't go through the model gateway yet (pages, filing, Ask, help, calls, reports) are logged with
        // the rest, so Settings › Models shows every dollar.
        ClaudeClient.onUsage = { [root] model, task, usage in
            try? UsageLog.append(UsageLog.Entry(device: "mac", role: UsageLog.role(forModel: model), provider: "claude", model: model,
                                                project: nil, usage: usage, task: task ?? "other"), root: root)
        }
        capture.onStateChange = { [weak self] in self?.captureChanged() }
        capture.onOpenDashboard = { [weak self] project in self?.showDashboard(project: project) }
        capture.onOpenSettings = { [weak self] in self?.showSettings() }
    }

    func start() {
        WhisperTranscriber.setLogging(enabled: false)
        do {
            let moved = try store.migrateLegacyNotes()
            if moved > 0 { Log.info("Upgraded \(moved) notes to the new layout") }
        } catch {
            Log.info("Upgrading notes failed: \(error.localizedDescription)")
        }
        library.startWatching()
        capture.engine.voiceIsolation = config.voiceIsolation
        transcription.warmUp()
        BroskiUI.app = self
        setUpCompanion()
        registerHotKey()
        services.onText = { [weak self] text, context in self?.capture.addFromService(text: text, context: context) }
        services.onImages = { [weak self] urls, context in self?.capture.addFromService(images: urls, context: context) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // 0.7.1: Broski lives in the menu bar and on its shortcuts. The floating head and the pill are off once for
        // everyone upgrading (both stay a menu toggle away).
        let surfacesKey = "BroskiMenuBarOnly071"
        if !UserDefaults.standard.bool(forKey: surfacesKey) {
            UserDefaults.standard.set(true, forKey: surfacesKey)
            if config.showFloatingButton || config.showPill { update { $0.showFloatingButton = false; $0.showPill = false } }
        }
        if config.showFloatingButton { makeBubble().setVisible(true) }
        applyFnKey()
        reflector.start()
        automator.start()
        if config.wakeWordEnabled { capture.setWakeListening(true) }
        if UserDefaults.standard.integer(forKey: Self.onboardingKey) < Self.onboardingVersion {
            showOnboarding()
        }
    }

    // MARK: Settings

    func update(_ change: (inout BroskiConfig) -> Void) {
        var new = config
        change(&new)
        guard new != config else { return }
        let old = config
        config = new
        // Saving now would write "everything is local only" (or defaults) over a file that just can't be read yet.
        if configTrusted {
            do {
                try new.save(to: configURL)
                configWarning = nil
            } catch {
                configWarning = "Couldn't save settings: \(error.localizedDescription)"
            }
        }
        capture.apply(config: new)
        capture.engine.voiceIsolation = new.voiceIsolation
        if old.hotkey != new.hotkey || old.frontDoor != new.frontDoor || old.noteHotkey != new.noteHotkey { registerHotKey() }
        if old.fnHoldToTalk != new.fnHoldToTalk { applyFnKey() }
        if old.showFloatingButton != new.showFloatingButton {
            if new.showFloatingButton { makeBubble().setVisible(true) } else { bubble?.setVisible(false) }
        }
        if old.screenshotHotkey != new.screenshotHotkey || old.clipHotkey != new.clipHotkey
            || old.askHotkey != new.askHotkey || old.helpHotkey != new.helpHotkey { registerHotKey() }
        if old.showPill != new.showPill || old.pillTucked != new.pillTucked || old.companionMode != new.companionMode { companion.applyConfig() }
        if old.localOnlyProjects != new.localOnlyProjects || old.autoCompilePages != new.autoCompilePages { library.reload() }
        if old.projectRoots != new.projectRoots { library.refreshFolders() }
        onStatusChange?()
    }

    func binding<T: Equatable>(_ keyPath: WritableKeyPath<BroskiConfig, T>) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } }
        )
    }

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchesAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            configWarning = "Couldn't change the login item: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    // MARK: Shortcut

    private var fnKey: FnKeyMonitor?

    /// Hold fn to talk: on while the setting is on (it does nothing until Accessibility is allowed).
    func applyFnKey() {
        fnKey?.stop()
        fnKey = nil
        guard config.fnHoldToTalk else { return }
        // Read at each press, so switching the front door needs no restart.
        fnKey = FnKeyMonitor(onHold: { [weak self] in
            guard let self else { return }
            if self.config.conversationFirst { self.showHome(listening: true) } else { self.capture.press(.fn) }
        }, onRelease: { [weak self] in
            guard let self else { return }
            if self.config.conversationFirst { self.homeModel.holdEnd() } else { self.capture.release(.fn) }
        })
        Log.info("Hold fn to talk: on (accessibility \(ContextCapture.accessibilityAllowed ? "allowed" : "not allowed yet"))")
    }

    func registerHotKey() {
        hotKey = nil
        noteHotKey = nil
        if config.conversationFirst {
            // The main shortcut opens the conversation; the note shortcut keeps the quick-note panel one key away.
            hotKey = HotKey(spec: config.hotkey) { [weak self] in self?.showHome() }
            noteHotKey = HotKey(spec: config.noteHotkey, released: { [weak self] in self?.capture.release(.shortcut) }) { [weak self] in
                self?.capture.press(.shortcut)
            }
        } else {
            hotKey = HotKey(spec: config.hotkey, released: { [weak self] in self?.capture.release(.shortcut) }) { [weak self] in
                self?.capture.press(.shortcut)
            }
        }
        if let hotKey {
            shortcutLabel = hotKey.display
            shortcutProblem = nil
            Log.info("Shortcut \(hotKey.display)")
        } else {
            shortcutLabel = HotKey.parse(config.hotkey)?.display ?? config.hotkey
            shortcutProblem = "\(shortcutLabel) is taken by another app. Pick another in Settings."
        }
        screenshotHotKey = nil
        screenshotHotKey = HotKey(spec: config.screenshotHotkey) { [weak self] in self?.capture.screenshotShortcut() }
        screenshotLabel = screenshotHotKey?.display ?? HotKey.parse(config.screenshotHotkey)?.display ?? config.screenshotHotkey
        if screenshotHotKey == nil { shortcutProblem = "\(screenshotLabel) is taken by another app. Pick another in Settings." }
        clipHotKey = nil
        clipHotKey = HotKey(spec: config.clipHotkey) { [weak self] in self?.capture.clipSelection() }
        clipLabel = clipHotKey?.display ?? HotKey.parse(config.clipHotkey)?.display ?? config.clipHotkey
        if clipHotKey == nil { shortcutProblem = "\(clipLabel) is taken by another app. Pick another in Settings." }
        askHotKey = nil
        askHotKey = HotKey(spec: config.askHotkey) { [weak self] in self?.showAsk(nil) }
        askLabel = askHotKey?.display ?? HotKey.parse(config.askHotkey)?.display ?? config.askHotkey
        helpHotKey = nil
        helpHotKey = HotKey(spec: config.helpHotkey) { [weak self] in self?.companion.helpWithThis() }
        helpLabel = helpHotKey?.display ?? HotKey.parse(config.helpHotkey)?.display ?? config.helpHotkey
        capture.setShortcutLabels(note: shortcutLabel, screenshot: screenshotLabel, clip: clipLabel)
        let main = config.conversationFirst ? "talk" : "note"
        let quick = config.conversationFirst ? ", note \(noteHotKey == nil ? "unavailable" : HotKey.parse(config.noteHotkey)?.display ?? config.noteHotkey)" : ""
        Log.info("Shortcuts: \(main) \(hotKey == nil ? "unavailable" : shortcutLabel)\(quick), screenshot \(screenshotHotKey == nil ? "unavailable" : screenshotLabel), clip \(clipHotKey == nil ? "unavailable" : clipLabel)")
        onStatusChange?()
    }

    /// While recording a new shortcut, the old one mustn't fire.
    func suspendHotKey(_ suspended: Bool) {
        if suspended {
            hotKey = nil
            screenshotHotKey = nil
            clipHotKey = nil
            askHotKey = nil
            helpHotKey = nil
        } else {
            registerHotKey()
        }
    }

    // MARK: Floating button

    private func makeBubble() -> BubbleController {
        if let bubble { return bubble }
        let made = BubbleController()
        made.onClick = { [weak self] frame in self?.capture.trigger(.button, anchor: frame) }
        made.onHoldStart = { [weak self] frame in self?.capture.press(.button, anchor: frame) }
        made.onHoldEnd = { [weak self] in self?.capture.release(.button) }
        made.menuProvider = { [weak self] in self?.quickMenu?() ?? NSMenu() }
        bubble = made
        return made
    }

    private func captureChanged() {
        bubble?.show(capture.activity)
        onStatusChange?()
    }

    var statusLine: String {
        if capture.isCapturing { return "Taking a note…" }
        if isOnCall { return "Taking call notes…" }
        if let session = library.activeSession { return "\(session.kind.label) running: \(session.title)" }
        if capture.wakeListening { return "Listening for “\(config.wakeWords.first ?? "broski")”" }
        return config.showFloatingButton ? "Click the Broski button or press \(shortcutLabel)" : "Press \(shortcutLabel) to take a note"
    }

    var problems: [String] {
        var list = [capture.speechProblem, shortcutProblem, configWarning].compactMap { $0 }
        if case .failed(let message) = transcription.state { list.append("Voice model: \(message)") }
        if let ai = brain.lastProblem { list.append("Claude: \(ai)") }
        return list
    }

    // MARK: The companion

    private func setUpCompanion() {
        companion.onAsk = { [weak self] project in self?.showAsk(project) }
        companion.onRiff = { [weak self] project, opening in self?.showRiff(project: project, opening: opening) }
        companion.onCall = { [weak self] in self?.toggleCall() }
        companion.onOpenNote = { [weak self] id in self?.openNote(id) }
        askModel.onOpenNote = { [weak self] id in self?.openNote(id) }
        askModel.onRiff = { [weak self] project, opening in
            self?.closeAsk()
            self?.showRiff(project: project, opening: opening)
        }
        askModel.onClose = { [weak self] in self?.closeAsk() }
        callModel.locale = { [weak self] in self?.config.locale ?? "auto" }
        callModel.onStateChange = { [weak self] on in
            self?.companion.setCalling(on)
            self?.onStatusChange?()
        }
        companion.start()
    }

    /// Ask Broski: a question about your notes, answered with sources.
    func showAsk(_ project: String?) {
        if askPanel == nil {
            let panel = CompanionPanel(placement: .center, focusable: true, width: 640) { [askModel, voice] in
                AskView(model: askModel, voice: voice)
            }
            panel.onClose = { [weak self] in self?.closeAsk() }
            askPanel = panel
        }
        if (askPanel?.isVisible != true && !askKeepsDraft) || project != nil { askModel.reset(project: project) }
        askKeepsDraft = false
        askPanel?.show(focus: true)
        askModel.focusTick += 1
    }

    /// Ask with a question already typed (from a record, the waiting panel).
    func prefillAsk(_ question: String) {
        askModel.question = question
        askModel.ask()
    }

    func closeAsk() {
        askPanel?.orderOut(nil)
        // A question typed but not asked yet is still there next time (not just the "In strado, " it opens with).
        let typed = askModel.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if askModel.answer == nil, !typed.isEmpty, !typed.hasSuffix(",") { askKeepsDraft = true }
        // The open riff window's mic button can still stop the mic, and it may be the riff's dictation.
        guard windows["riff"] == nil else { return }
        stopVoice { [weak self] text in
            guard let self else { return }
            self.askModel.question = TextTools.joinPhrase(self.askModel.question, text)
            if self.askPanel?.isVisible != true { self.askKeepsDraft = true }
        }
    }

    /// Ask and Riff share one mic: closing the last of them mustn't leave it recording, with nothing left to stop it.
    /// What was said goes into the closed surface's draft, unsent, so closing never throws speech away.
    private func stopVoice(keeping keep: @escaping (String) -> Void) {
        Task { [voice, capture, library] in
            // A note that took the mic since owns it now; stopping here would cut it off.
            guard voice.listening, !capture.isCapturing else { return }
            let text = await voice.stop(vocabulary: library.projectNames)
            if !text.isEmpty { keep(text) }
        }
    }

    /// The home conversation: the front door to Broski. `listening` starts the mic (fn held).
    func showHome(listening: Bool = false) {
        let fresh = windows["home"] == nil
        showWindow("home", title: "Broski", size: NSSize(width: 560, height: 700), resizable: true) {
            HomeView(model: self.homeModel, voice: self.voice, openDashboard: { [weak self] in self?.showDashboard() },
                     openMemory: { [weak self] in self?.showMemory() })
        }
        if fresh { homeModel.reload() }
        if listening { homeModel.holdStart() }
    }

    private(set) lazy var memoryModel: MemoryModel = {
        let model = MemoryModel(root: root, library: library)
        model.reflect = { [weak self] in await self?.reflector.run() ?? "" }
        model.reflectionOn = ({ [weak self] in self?.config.reflection ?? true }, { [weak self] on in self?.update { $0.reflection = on } })
        return model
    }()

    /// Every model call goes through one gateway: Claude's key from the Keychain, others under "model.<id>".
    func makeGateway() -> ModelGateway {
        ModelGateway(settings: config.models ?? .defaults, root: root, device: "mac") { id in
            id == "claude" ? Secrets.get(Secrets.claudeKey) : Secrets.get("model.\(id)")
        }
    }

    private(set) lazy var automator = Automator(root: root) { [weak self] in self?.config ?? .defaults }

    private(set) lazy var reflector: Reflector = {
        let reflector = Reflector(root: root, library: library, config: { [weak self] in self?.config ?? .defaults },
                                  gateway: { [weak self] in self?.makeGateway() })
        reflector.onChange = { [weak self] in self?.memoryModel.reload() }
        return reflector
    }()

    private(set) lazy var vaultModel: VaultSession = {
        let session = VaultSession(root: root)
        // The vault locks when the Mac sleeps or the screen locks.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in session.lock() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in session.lock() }
        }
        return session
    }()

    /// The private vault. Its window is left out of screenshots and screen recording, and closing it locks the vault.
    /// A note said as "vault: …" waits (in memory only) until the vault is open.
    func showVault(adding note: String? = nil) {
        if let note { vaultModel.queue(note) }
        showWindow("vault", title: "Private vault", size: NSSize(width: 720, height: 520), resizable: true) {
            VaultView(model: self.vaultModel)
        }
        windows["vault"]?.sharingType = .none
        vaultModel.refresh()
    }

    /// What Broski knows about you, and every project's decisions.
    func showMemory() {
        showWindow("memory", title: "What Broski knows", size: NSSize(width: 560, height: 560), resizable: true) {
            MemoryView(model: self.memoryModel)
        }
        memoryModel.reload()
    }

    /// Riff mode, in the conversation: from the menu, the pill, Ask or a project page. An opening (a suggested action)
    /// is said as the riff's first words.
    func showRiff(project: String?, opening: String?) {
        showHome()
        if let project { homeModel.project = project }
        homeModel.startRiff(about: nil)
        if let opening, !opening.isEmpty {
            homeModel.draft = opening
            homeModel.send()
        }
    }

    /// Call notes: opens the call window, or stops a call in progress.
    func toggleCall() {
        // While the notes are still being written the call isn't over: show it, never reset it.
        if callModel.phase == .recording || callModel.phase == .writing {
            callModel.stop()
            showWindow("call", title: "Call notes", size: NSSize(width: 420, height: 420), resizable: false) {
                CallView(model: self.callModel) { [weak self] in self?.windows["call"]?.close() }
            }
            return
        }
        switch callModel.phase {
        case .done:
            break  // notes are waiting to be saved: keep them and the project picked for them
        case .idle where windows["call"] != nil:
            break  // the setup window is already open: keep what was picked there
        default:
            // A fresh call: guess the project from the window you're in, with your context settings, while it's still in front.
            callModel.reset()
            let context = ContextCapture.snapshot(includeBrowser: config.captureBrowserPage, includeAccessibility: config.captureWindowDetails)
            callModel.project = CompanionPlanner.project(for: context, catalog: library.catalog, items: library.allItems)
        }
        showWindow("call", title: "Call notes", size: NSSize(width: 420, height: 420), resizable: false) {
            CallView(model: self.callModel) { [weak self] in self?.windows["call"]?.close() }
        }
        windows["call"]?.level = .floating
    }

    var isOnCall: Bool { callModel.phase == .recording }

    /// Opens a note (or the session an observation came from) in the dashboard.
    func openNote(_ id: String) {
        if let record = library.record(id: id) {
            UserDefaults.standard.set(ProjectTab.tracker.rawValue, forKey: "BroskiDashboardTab")
            showDashboard(project: record.project)
            DispatchQueue.main.async { self.library.selectRequest = id }
        } else if let item = library.item(id: id) {
            // An inbox note opens the Inbox, not whatever the dashboard was showing.
            showDashboard(project: item.project ?? Library.inboxID)
            library.selectRequest = id
        } else if let session = library.session(forRef: id) {
            NSWorkspace.shared.open(session.file)
        }
    }

    // MARK: Windows

    func showDashboard(project: String? = nil) {
        library.reload()
        library.focusRequest = project.map { name in library.projects.first { $0.name == name }?.id ?? name }
        showWindow("dashboard", title: "Broski", size: NSSize(width: 1180, height: 740), resizable: true) {
            DashboardView(library: self.library, shortcut: self.shortcutLabel,
                          onCapture: { [weak self] in self?.capture.trigger(.shortcut) },
                          onScreenshot: { [weak self] in self?.capture.screenshotShortcut() })
        }
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab, let window = windows["settings"] {
            window.contentView = NSHostingView(rootView: SettingsView(app: self, tab: tab))
            return bringForward(window)
        }
        showWindow("settings", title: "Broski Settings", size: NSSize(width: 640, height: 520), resizable: false) {
            SettingsView(app: self, tab: tab ?? .general)
        }
    }

    func showOnboarding() {
        showWindow("onboarding", title: "Welcome to Broski", size: NSSize(width: 640, height: 560), resizable: false) {
            OnboardingView(app: self)
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(Self.onboardingVersion, forKey: Self.onboardingKey)
        windows["onboarding"]?.close()
    }

    private func showWindow<Content: View>(_ id: String, title: String, size: NSSize, resizable: Bool, content: () -> Content) {
        if let window = windows[id] {
            bringForward(window)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("Broski.\(id)")
        windows[id] = window
        bringForward(window)
    }

    private func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Closing the call window mid-call asks first, so a recording can't carry on with no window to stop it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === windows["call"], callModel.phase == .recording else { return true }
        let alert = NSAlert()
        alert.messageText = "The call is still being recorded"
        alert.informativeText = "Keep recording in the background, or stop now and write the notes."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Stop and Write Notes")
        if alert.runModal() == .alertSecondButtonReturn { callModel.stop() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        // Ask's mic button can still stop the mic while Ask is open, and it may be Ask's dictation.
        if id == "vault" { vaultModel.lock() }
        if id == "home" {
            stopVoice { [weak self] text in
                guard let self else { return }
                self.homeModel.draft = TextTools.joinPhrase(self.homeModel.draft, text)
            }
        }
        if id == "onboarding" {
            UserDefaults.standard.set(Self.onboardingVersion, forKey: Self.onboardingKey)
        }
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }

    // MARK: Support

    /// Version, setup, and the tail of the event log, for beta testers to paste into feedback.
    func diagnostics() -> String {
        let log = (try? String(contentsOf: root.appendingPathComponent(".broski/broski.log"), encoding: .utf8))?
            .split(separator: "\n").suffix(40).joined(separator: "\n") ?? "(no log)"
        return """
        Broski \(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Microphone: \(Permissions.microphone), speech: \(Permissions.speech), language: \(config.locale) (\(capture.engine.localeIdentifier), on-device \(capture.engine.isOnDevice))
        Floating button: \(config.showFloatingButton), wake word: \(config.wakeWordEnabled), shortcut: \(config.hotkey)
        Voice model: \(transcription.state), Claude key: \(brain.hasKey ? "set" : "none")
        Project folders: \(config.projectRoots.count), projects: \(library.projects.count), notes: \(library.allItems.count), sessions: \(library.allSessions.count)
        Problems: \(problems.isEmpty ? "none" : problems.joined(separator: " | "))

        Recent events:
        \(log)
        """
    }
}
