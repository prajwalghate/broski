import AVFoundation
import AppKit
import BroskiCore
import Combine

/// Runs one capture at a time. A capture starts from the floating button, a shortcut, or the wake word.
/// You talk, type, clip, add screenshots, or all of it; nothing is saved until you press ⌘Return or Save.
/// Speech is recorded and transcribed by local Whisper, then Claude (or Broski's rules) decides what it is:
/// a note for a project, an observation for the running session, or a command.
@MainActor
final class CaptureController: NSObject {
    enum Source: String { case wake = "wake word", shortcut, button, screenshot, clip, fn = "fn key" }
    enum Activity { case idle, listening, typing, saving, saved }

    private struct Capture {
        let id = UUID()
        let source: Source
        var listening = false
        var lastVoice = Date()
        var voiceStarted = Date()
        var voiced: TimeInterval = 0
        /// Loud speech since the last chunk was sent to Whisper.
        var spokeSinceCut = false
        var lastCut = Date()
        var stripsWakeWord = false
        var everListened = false
        var spokeSomething = false
        /// Push-to-talk: the shortcut or head is held down; letting go stops the mic.
        var holding = false
        /// This mic session was started by the wake word, so it ends on a pause. Set on every start.
        var handsFree = false
        /// Apple's recognizer is streaming a preview for this mic session.
        var live = false
        /// Typing stopped the mic: focus stays in the editor and the last phrase never auto-saves.
        var typedOver = false
        /// Why transcription failed in this mic session, shown once you stop talking.
        var problem: String?
        /// ⌘Return (or Wrap up) is saving; voice can't start, or its recording would close with the note.
        var committing = false
        /// Closing without saving; the last phrase still lands in the draft.
        var closing = false
        /// Which Esc started the close; reopening clears it, so only the latest close can end the capture.
        var closeID: UUID?
        /// This capture opened with the kept draft, so saving it uses the draft up and closing replaces it.
        var carriesDraft = false
    }

    /// Unsaved text and screenshots kept when you close the panel, restored next time.
    private struct Draft {
        var text: String
        var attachments: [URL]
        var clips: [Clip]
        var appendTarget: Item?
    }

    /// The draft as written to `.broski/draft.json`. Attachments without a leading "/" live in `.broski/draft-files/`.
    private struct StoredDraft: Codable {
        struct StoredClip: Codable {
            var text: String
            var app, window, url: String?
        }
        var text: String
        var attachments: [String]
        var clips: [StoredClip]
        var appendID: String?
        var appendProject: String?
    }

    private enum LastAction {
        case item(Item)
        /// Added more to a note; holds the note as it was before.
        case edit(Item)
        case entry(Session)
    }

    let model: PanelModel
    let engine: SpeechEngine
    let library: Library
    let brain: Brain
    let transcription: Transcription
    private(set) var config: BroskiConfig
    private var panel: FloatingPanel!
    private var matcher: WakeWordMatcher
    private var accumulator = TranscriptAccumulator()
    private var capture: Capture?
    private var lastAction: LastAction?
    private var hideTask: Task<Void, Never>?
    private var ticker: Timer?
    private var speechConfigured = false
    private var noiseFloor: Float = 0.2
    private var lastLevelAt = Date()
    private var pressedAt: Date?
    /// What Broski would do with the current text, worked out while you review it.
    private var proposalFor: (text: String, spoken: Bool)?
    private var proposalTask: Task<Void, Never>?
    private var spokenCapture = false
    private var holdTask: Task<Void, Never>?
    /// Whisper chunks run one after another so text lands in order.
    private var chunkChain: Task<Void, Never>?
    private var pendingChunks = 0
    /// Apple preview text already covered by a Whisper chunk; the live preview shows what comes after.
    private var liveCutPrefix = ""
    /// Without Whisper, Apple's recognizer finishes the last words after you stop; the final chunk waits for it.
    private var awaitingFinal: (capture: UUID, token: UUID)?
    private var finalWaiter: CheckedContinuation<Void, Never>?
    private var finalPreviews: [UUID: String] = [:]
    /// You typed while the mic was on: the text voice had written by then, so later phrases go in before your typing.
    private var voiceAnchor: String?
    /// Also kept on disk, so quitting or restarting Broski doesn't lose it.
    private var draft: Draft? {
        didSet { draft = persist(draft) }
    }
    /// The note saved most recently, for "Add more".
    private var lastItem: Item?
    /// Bumped by every new capture, so a slow session report knows whether the panel is still its own.
    private var captureGeneration = 0
    private var sizing: AnyCancellable?
    private var sessionWatch: AnyCancellable?
    private var whisperWatch: AnyCancellable?
    private var accessWatch: Timer?

    private(set) var activity: Activity = .idle
    private(set) var speechProblem: String?
    private(set) var onDeviceProblem: String?
    var onStateChange: (() -> Void)?
    var onOpenDashboard: ((String?) -> Void)?
    var onOpenSettings: (() -> Void)?

    var isCapturing: Bool { capture != nil }
    var wakeListening: Bool { engine.wantsWake }

    init(config: BroskiConfig, library: Library, brain: Brain, transcription: Transcription) {
        self.config = config
        self.library = library
        self.brain = brain
        self.transcription = transcription
        model = PanelModel()
        engine = SpeechEngine()
        matcher = WakeWordMatcher(wakeWords: config.wakeWords)
        super.init()
        panel = FloatingPanel(rootView: PanelView(model: model))
        panel.onCancel = { [weak self] in self?.cancelRequested() }
        panel.onDropFiles = { [weak self] urls in self?.attach(urls) }
        wireUp()
        draft = loadDraft()
    }

    private func wireUp() {
        // Clips, the "adding to" bar, the session bar, the related row and a long plan all change the panel's
        // height, whoever changes them. Read once the change has landed (the publisher fires before it).
        sizing = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutPanel() }
        // The "Get better voice" badge follows the download: progress, Ready, or failed.
        whisperWatch = transcription.$voiceState.sink { [weak self] state in
            guard let self else { return }
            self.model.whisperState = state
            self.model.voiceEngine = self.transcription.barkUsable(Transcription.language(for: self.config.locale)) ? "Bark" : "Whisper"
        }
        // A session wrapped up elsewhere (menu, iPhone) takes its bar out of the open panel.
        sessionWatch = library.$activeSession.sink { [weak self] session in
            guard let self, self.capture != nil else { return }
            self.model.session = session
        }
        engine.onWakeTranscript = { [weak self] text in self?.heardWhileWaiting(text) }
        engine.onDictationTranscript = { [weak self] text in self?.heardWhileDictating(text) }
        engine.onDictationEnded = { [weak self] error in self?.liveRecognitionEnded(error: error) }
        engine.onLevel = { [weak self] level in self?.levelChanged(level) }
        engine.onProblem = { [weak self] message in self?.speechFailed(message) }
        model.onSave = { [weak self] in self?.saveRequested() }
        model.onCancel = { [weak self] in self?.cancelRequested() }
        model.onUndo = { [weak self] in self?.undoLast() }
        model.onOpen = { [weak self] in self?.openDashboardFromPanel() }
        model.onUserEdit = { [weak self] text in self?.userEdited(text) }
        model.onToggleVoice = { [weak self] in self?.toggleVoice() }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        model.onScreenshot = { [weak self] in self?.addScreenshot() }
        model.onPaste = { [weak self] in self?.pasteClipboard() }
        model.onRemoveAttachment = { [weak self] url in self?.model.attachments.removeAll { $0 == url } }
        model.onEndSession = { [weak self] in self?.endActiveSession() }
        model.onDownloadModel = { [weak self] in self?.transcription.downloadPreferred() }
        model.onDiscardDraft = { [weak self] in self?.discardDraft() }
        model.onUseDuplicate = { [weak self] in self?.useDuplicate() }
        model.onOpenRelated = { id in BroskiUI.app?.openNote(id) }
        model.onRemoveClip = { [weak self] id in
            self?.model.clips.removeAll { $0.id == id }
            self?.layoutPanel()
            self?.propose()
        }
        model.onQuoteSelection = { [weak self] in self?.quoteSelection() }
        model.onAddMore = { [weak self] in self?.continueLastNote() }
        model.onAllowAccessibility = { [weak self] in self?.allowAccessibility() }
        model.onRestart = { [weak self] in self?.restartKeepingDraft() }
        model.onPickAppendTarget = { [weak self] item in
            self?.model.appendTarget = item
            self?.model.manualDestination = nil
            self?.layoutPanel()
        }
    }

    // MARK: Settings

    func apply(config new: BroskiConfig) {
        let old = config
        config = new
        matcher = WakeWordMatcher(wakeWords: new.wakeWords)
        if old.locale != new.locale, speechConfigured { configureSpeech() }
        if old.wakeWordEnabled != new.wakeWordEnabled || old.locale != new.locale {
            setWakeListening(new.wakeWordEnabled)
        }
    }

    func setShortcutLabels(note: String, screenshot: String, clip: String) {
        model.shortcut = note
        model.screenshotShortcut = screenshot
        model.clipShortcut = clip
    }

    var canAddMore: Bool { lastItem.flatMap { FileManager.default.fileExists(atPath: $0.file.path) ? $0 : nil } != nil }

    private func configureSpeech() {
        onDeviceProblem = engine.configure(locale: config.locale)
        speechConfigured = true
        Log.info("Speech: \(engine.localeIdentifier), on-device: \(engine.isOnDevice)")
    }

    /// Wake-word mode keeps the mic on and needs Apple's on-device recognizer.
    func setWakeListening(_ on: Bool) {
        guard on else {
            engine.wantsWake = false
            // Keyed on the engine, not the panel: a typing-only capture leaves the wake task running.
            // A note (or Ask) that is recording keeps its mic; resumeIdle turns it off when it stops.
            if engine.mode != .dictation, capture?.listening != true { engine.stop() }
            changed()
            return
        }
        guard Permissions.voiceGranted else {
            if Permissions.voiceDenied {
                speechFailed("Allow the microphone and speech recognition in System Settings to use the wake word")
            } else {
                Task { if await Permissions.requestVoice() { self.setWakeListening(self.config.wakeWordEnabled) } }
            }
            return
        }
        if !speechConfigured { configureSpeech() }
        engine.wantsWake = engine.isOnDevice
        if let problem = onDeviceProblem, !engine.isOnDevice { speechFailed(problem) }
        // Also with the panel open: the wake word is ignored while a capture is open, and this way it works after.
        if engine.wantsWake, engine.mode == .off, capture?.listening != true { engine.startWake() }
        changed()
    }

    // MARK: Starting

    /// A click on the head or a tap of the shortcut: open the panel (mic off), stop talking, or bring it forward.
    /// Nothing here ever saves; only ⌘Return or Save does.
    func trigger(_ source: Source, anchor: NSRect? = nil) {
        guard let c = capture else { return begin(source, anchor: anchor) }
        abortClose()
        if c.listening {
            stopListening()
        } else {
            panel.present(focus: true, near: nil)
            model.focusTick += 1
        }
    }

    /// The shortcut went down, or the head is being held. Held = push-to-talk; a quick tap just opens the panel.
    func press(_ source: Source, anchor: NSRect? = nil) {
        guard pressedAt == nil else { return }  // key repeat
        // Saving is under way: a hold now would record into the note that's closing, and lose it.
        guard capture?.committing != true else { return }
        // The head and fn report a hold only once it's been held (0.3 / 0.35 s); push-to-talk replays from the real press.
        pressedAt = source == .button ? Date().addingTimeInterval(-0.3) : source == .fn ? Date().addingTimeInterval(-FnKeyMonitor.holdDelay) : Date()
        abortClose()
        if capture == nil {
            begin(source, anchor: anchor)
        } else if capture?.listening == true {
            pressedAt = nil
            return stopListening()
        } else {
            panel.present(focus: true, near: nil)
        }
        // The head and fn only report a press once it's already been held; the keyboard waits a beat.
        if source == .button || source == .fn {
            startVoice(holding: true)
        } else {
            holdTask?.cancel()
            let pressed = pressedAt ?? Date()
            holdTask = Task {
                // Timed from the key-down, so reading the context first doesn't make the wait longer.
                let wait = max(0, 0.3 - Date().timeIntervalSince(pressed))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, self.pressedAt != nil else { return }
                self.startVoice(holding: true)
            }
        }
    }

    /// Let go: if it was a hold, stop the mic and put the text in the panel to review.
    func release(_ source: Source) {
        guard pressedAt != nil else { return }
        pressedAt = nil
        holdTask?.cancel()
        if capture?.holding == true {
            Log.info("Push-to-talk released")
            stopListening()
        }
    }

    /// The screenshot shortcut: add a screenshot to the open capture, or start one with it.
    func screenshotShortcut() {
        if capture != nil {
            addScreenshot()
        } else {
            begin(.screenshot, anchor: nil)
        }
    }

    private var hasContent: Bool {
        !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments.isEmpty || !model.clips.isEmpty
    }

    private func heardWhileWaiting(_ text: String) {
        speechWorks()
        guard capture == nil, let match = matcher.firstMatch(in: text) else { return }
        Log.info("Wake word heard (\"\(match.heard)\")")
        begin(.wake, anchor: nil)
    }

    private func begin(_ source: Source, anchor: NSRect?, context known: ItemContext? = nil, appendTo target: Item? = nil) {
        hideTask?.cancel()
        Log.info("Capture started by \(source.rawValue)")
        // Read the context first, while the app you're in is still frontmost.
        let context = known ?? ContextCapture.snapshot(includeBrowser: config.captureBrowserPage, includeAccessibility: config.captureWindowDetails)
        library.reload()
        lastAction = nil
        capture = Capture(source: source)
        captureGeneration &+= 1
        model.reset(projects: library.catalog.projects)
        model.context = context
        model.session = library.activeSession
        model.aiEnabled = brain.hasKey
        model.lastItem = canAddMore ? lastItem : nil
        model.appendTarget = target
        model.phase = .typing
        if let draft, source != .wake, source != .clip, target == nil {
            model.text = draft.text
            model.attachments = draft.attachments
            model.clips = draft.clips
            // The note may have moved or been deleted since; a deleted one isn't offered.
            model.appendTarget = draft.appendTarget.flatMap { resolve($0) }
            model.restoredDraft = true
            capture?.carriesDraft = true
            propose()
        }
        layoutPanel()
        startTicker()
        setActivity(.typing)

        if source == .screenshot {
            Task {
                let shot = await Screenshot.capture()
                guard capture != nil else { return }
                if case .cancelled = shot, model.attachments.isEmpty {
                    cancel(showing: nil)
                    return
                }
                handle(shot)
                showPanel(anchor: anchor, focus: true)
            }
            return
        }
        if source == .clip { return showPanel(anchor: anchor, focus: true) }
        showPanel(anchor: anchor, focus: source != .wake)
        // The wake word means you're already talking; anything else waits for you to choose voice.
        if source == .wake || config.startMicOnOpen { startVoice() }
    }

    private func showPanel(anchor: NSRect?, focus: Bool) {
        panel.present(focus: focus, near: anchor)
        if focus { model.focusTick += 1 }
    }

    // MARK: Attachments

    private func addScreenshot() {
        guard capture != nil else { return }
        abortClose()
        let id = capture?.id
        // The mic keeps going while you pick, so you can talk about what you're capturing.
        panel.orderOut(nil)
        Task {
            let shot = await Screenshot.capture()
            if capture?.id != id {
                // The note was saved while you picked: the screenshot starts a new one instead of vanishing.
                guard case .image = shot else { return }
                if capture == nil { begin(.clip, anchor: nil) }
            }
            handle(shot)
            panel.present(focus: true, near: nil)
            if case .image = shot { propose() }
        }
    }

    private func handle(_ shot: Screenshot.Result) {
        switch shot {
        case .image(let url):
            model.attachments.append(url)
            model.detail = ""
        case .cancelled:
            break
        case .needsPermission:
            model.needsScreenPermission = true
            model.detail = "Turn on Broski in Settings › Screen Recording, then restart Broski."
        case .failed(let message):
            model.detail = "Screenshot failed: \(message)"
        }
    }

    private func pasteClipboard() {
        if let image = Screenshot.fromClipboard() {
            model.attachments.append(image)
        } else if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            userEdited(model.text.isEmpty ? quoted : model.text + "\n\n" + quoted)
        }
    }

    private func attach(_ urls: [URL]) {
        guard capture != nil else { return }
        model.attachments += urls
    }

    // MARK: Clips

    /// The clip shortcut: highlighted text from any app becomes a quote in the note, with where it came from.
    /// Press it again on more highlights to collect them into the same note.
    func clipSelection() {
        Log.info("Clip shortcut pressed")
        let context = ContextCapture.snapshot(includeBrowser: config.captureBrowserPage, includeAccessibility: true)
        Task {
            switch await SelectionGrabber.grab(context) {
            case .text(let text):
                addClip(Clip(text: text, source: context), context: context)
            case .nothing:
                if capture == nil { begin(.clip, anchor: nil, context: context) } else { abortClose() }
                model.detail = "Nothing highlighted. Select some text, then press \(model.clipShortcut)."
                panel.present(focus: true, near: nil)
            case .needsAccessibility:
                if capture == nil { begin(.clip, anchor: nil, context: context) } else { abortClose() }
                model.needsAccessibility = true
                model.detail = "Allow Accessibility so Broski can read highlighted text, or use right-click › Services › Add to Broski."
                panel.present(focus: true, near: nil)
            }
        }
    }

    /// Asks macOS, opens the right Settings page, and notices the moment access is on (no restart needed).
    private func allowAccessibility() {
        ContextCapture.requestAccessibility()
        ContextCapture.openAccessibilitySettings()
        model.detail = "Turn on Broski in the list. If it's already on, remove it with − and add it again."
        accessWatch?.invalidate()
        let started = Date()
        accessWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if ContextCapture.accessibilityAllowed {
                    timer.invalidate()
                    Log.info("Accessibility allowed")
                    self.model.needsAccessibility = false
                    self.model.detail = "Clipping is on. Highlight text anywhere and press \(self.model.clipShortcut)."
                    self.play("Glass")
                } else if Date().timeIntervalSince(started) > 180 {
                    timer.invalidate()
                }
            }
        }
    }

    /// From right-click › Services › Add to Broski.
    func addFromService(text: String, context: ItemContext) {
        addClip(Clip(text: text, source: context), context: context)
    }

    func addFromService(images: [URL], context: ItemContext) {
        if capture == nil { begin(.clip, anchor: nil, context: context) } else { abortClose() }
        model.attachments += images
        panel.present(focus: true, near: nil)
        propose()
    }

    private func addClip(_ clip: Clip, context: ItemContext) {
        guard !clip.text.isEmpty else { return }
        var context = context
        context.selection = nil
        let first = capture == nil
        if first { begin(.clip, anchor: nil, context: context) } else { abortClose() }
        guard !model.clips.contains(where: { $0.text == clip.text }) else {
            model.detail = "Already clipped that"
            // A close it just called off (or a fresh capture) must not stay open and hidden.
            panel.present(focus: first, near: nil)
            return
        }
        model.clips.append(clip)
        model.needsAccessibility = false
        model.restoredDraft = false
        model.detail = first ? "" : "\(model.clips.count) clips · keep highlighting, or add what you think"
        play("Pop")
        layoutPanel()
        // Collecting more shouldn't pull you out of what you're reading.
        panel.present(focus: first, near: nil)
        propose()
    }

    /// "+ selected text" in the panel: quote what was highlighted when the note opened.
    private func quoteSelection() {
        guard let text = model.context.selection else { return }
        model.clips.append(Clip(text: text, source: model.context))
        model.context.selection = nil
        layoutPanel()
        propose()
    }

    /// Carry on the note you just saved: what you add goes under it, with the time.
    func continueLastNote() {
        guard let item = lastItem, let fresh = resolve(item) else { return trigger(.shortcut) }
        if capture != nil {
            abortClose()
            // Clears a pinned destination too, so "Adding to…" is what ⌘Return really does.
            model.onPickAppendTarget(fresh)
            model.duplicate = nil
            model.related = []
            return panel.present(focus: true, near: nil)
        }
        begin(.shortcut, anchor: nil, appendTo: fresh)
    }

    /// The note as it is on disk now: edited, moved to another project (same id), or nil once deleted.
    private func resolve(_ target: Item) -> Item? {
        resolve(id: target.id, project: target.project)
    }

    private func resolve(id: String, project: String?) -> Item? {
        library.store.items(in: project).first { $0.id == id } ?? library.store.allItems().first { $0.id == id }
    }

    /// Notes about the same thing, found locally as you write. A near-duplicate of an open note is offered
    /// as "add to it instead", so the same bug doesn't get filed three times.
    private func findRelated(_ text: String) {
        guard text.count >= 12, model.appendTarget == nil else {
            model.duplicate = nil
            model.related = []
            return
        }
        let index = library.index
        if let hit = index.duplicate(of: text), let item = library.item(id: hit.ref.id) {
            model.duplicate = item
            model.related = []
        } else {
            model.duplicate = nil
            // Only notes can be shown here: session entries and tracker records mustn't use up the two slots.
            model.related = index.related(to: text, threshold: 0.28, limit: 2, where: { !$0.isSessionEntry && !$0.isTrackerRecord })
                .compactMap { library.item(id: $0.ref.id) }
        }
    }

    private func useDuplicate() {
        guard let item = model.duplicate else { return }
        model.appendTarget = item
        model.manualDestination = nil
        model.duplicate = nil
        model.related = []
        layoutPanel()
    }

    /// Clips, the "adding to" bar and other rows need more room; the panel grows downward from where it is.
    private func layoutPanel() {
        panel?.fit(height: PanelView.height(for: model))
    }

    // MARK: Voice

    private func toggleVoice() {
        guard let c = capture else { return }
        if c.listening { stopListening() } else { startVoice() }
    }

    private func startVoice(holding: Bool = false) {
        abortClose()
        // While saving, a recording would be thrown away with the closing note.
        guard var c = capture, !c.listening, !c.committing else { return }
        // Apple is still finishing the last words of the previous stop: take what it has now.
        if let pending = awaitingFinal { finishLive(pending.token) }
        guard Permissions.microphone == .granted else {
            if Permissions.microphone == .denied {
                model.needsPermission = true
                model.detail = "Microphone access is off. Type your note, or allow it in Settings."
            } else {
                model.detail = "Allow the microphone to talk to Broski"
                let id = c.id
                Task {
                    _ = await Permissions.requestVoice()
                    guard self.capture?.id == id else { return }
                    if Permissions.microphone == .granted { self.startVoice(holding: holding && self.pressedAt != nil) } else {
                        self.model.needsPermission = true
                        self.model.detail = "Microphone access is off. Type your note, or allow it in Settings."
                    }
                }
            }
            return
        }
        // Ask or Riff is recording; starting here would take its audio and turn its mic off.
        guard engine.mode != .dictation else {
            model.detail = "Finish talking in Ask or Riff first"
            return
        }
        if !speechConfigured, Permissions.speech == .granted { configureSpeech() }
        // Without Whisper, only Apple's recognizer can write the words; don't record with nothing to hear it.
        guard transcription.isReady || Permissions.speech == .granted && engine.hasRecognizer else {
            return explainNoTranscriber(id: c.id, holding: holding)
        }
        let wakeStart = c.source == .wake && !c.everListened
        // Push-to-talk replays from the real key-down. The ring only holds that audio when the mic was
        // already on for the wake word; a cold mic starts with an empty ring.
        var replay: TimeInterval = 0
        if wakeStart {
            replay = 2.5
        } else if holding, let pressedAt {
            replay = min(Date().timeIntervalSince(pressedAt) + 0.15, 3.5)
        }
        // Apple's recognizer gives a quick preview; Whisper writes the real text, phrase by phrase.
        let live = Permissions.speech == .granted && (!transcription.isReady || config.livePreview)
        do {
            try engine.beginDictation(replay: replay, live: live)
        } catch {
            model.detail = "Mic unavailable: \(error.localizedDescription)"
            return
        }
        accumulator = TranscriptAccumulator()
        liveCutPrefix = ""
        voiceAnchor = nil
        model.proposal = nil
        proposalTask?.cancel()
        c.listening = true
        c.holding = holding
        c.everListened = true
        // Only the wake word's own session strips the wake word and ends on a pause; a later click or hold doesn't.
        c.stripsWakeWord = wakeStart
        c.handsFree = wakeStart && !holding
        c.live = live
        c.typedOver = false
        c.problem = nil
        c.lastVoice = Date()
        c.voiceStarted = Date()
        c.lastCut = Date()
        c.voiced = 0
        c.spokeSomething = false
        c.spokeSinceCut = false
        capture = c
        model.liveText = ""
        model.holding = holding
        engine.reportLevels = true
        model.needsPermission = false
        model.detail = ""
        model.restoredDraft = false
        model.phase = .listening
        play("Tink")
        setActivity(.listening)
    }

    /// You're done talking (Done, ⌘Return, a tap, letting go, or typing). Transcribes what's left; nothing is saved.
    private func stopListening(toTyping: Bool = false) {
        guard var c = capture, c.listening else { return }
        c.listening = false
        c.holding = false
        c.typedOver = toTyping
        capture = c
        engine.reportLevels = false
        let tail = engine.takeRecording()
        // Without Whisper, Apple's recognizer is the only one writing: let it finish the last words
        // (its preview lags the audio) instead of cancelling it. Capped, in case the final never comes.
        var preview = ""
        var token: UUID?
        if !transcription.isReady, c.live, engine.mode == .dictation {
            let waiting = UUID()
            token = waiting
            awaitingFinal = (c.id, waiting)
            engine.endDictation()
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.finishLive(waiting)
            }
        } else {
            preview = model.liveText
            engine.resumeIdle()
            model.liveText = ""
        }
        model.holding = false
        // Typing keeps the editor (and its focus); the header spinner shows the last phrase is on its way.
        model.phase = toTyping ? .typing : .transcribing
        setActivity(toTyping ? .typing : .saving)
        play("Pop")
        enqueueChunk(tail, final: true, fallback: preview, waitingFor: token)
    }

    /// Apple's final words arrived, timed out, or are no longer wanted: hands its preview to the waiting chunk.
    private func finishLive(_ token: UUID) {
        guard let pending = awaitingFinal, pending.token == token else { return }
        awaitingFinal = nil
        finalPreviews[token] = model.liveText
        model.liveText = ""
        engine.resumeIdle()
        finalWaiter?.resume()
        finalWaiter = nil
    }

    /// Whisper runs on each phrase as you pause, so the text fills in while you talk and Done is instant.
    /// `fallback` is Apple's preview of the same audio, used when Whisper isn't ready or fails.
    private func enqueueChunk(_ audio: [AVAudioPCMBuffer], final: Bool, fallback: String = "", waitingFor token: UUID? = nil) {
        guard let id = capture?.id else { return }
        let previous = chunkChain
        pendingChunks += 1
        model.transcribingChunk = true
        let vocabulary = library.catalog.projects.map(\.spokenName)
        let language = Transcription.language(for: config.locale)
        chunkChain = Task {
            await previous?.value
            var fallback = fallback
            if let token {
                if awaitingFinal?.token == token { await withCheckedContinuation { finalWaiter = $0 } }
                fallback = finalPreviews.removeValue(forKey: token) ?? ""
            }
            var text = ""
            var usedFallback = false
            if transcription.isReady {
                do {
                    text = try await transcription.transcribe(audio, language: language, vocabulary: vocabulary)
                } catch {
                    Log.info("Whisper failed: \(error.localizedDescription)")
                    // Apple's preview of the same phrase beats losing it; either way, say so.
                    text = fallback
                    usedFallback = !fallback.isEmpty
                    let problem = fallback.isEmpty ? "Transcription failed: \(error.localizedDescription)" : "Whisper failed; kept Apple's preview"
                    if capture?.id == id {
                        capture?.problem = problem
                        model.detail = problem
                    }
                }
            }
            if text.isEmpty && final && !transcription.isReady {
                text = fallback
                usedFallback = true
            }
            pendingChunks -= 1
            model.transcribingChunk = pendingChunks > 0
            guard capture?.id == id else { return }
            if capture?.stripsWakeWord == true, !text.isEmpty {
                // The preview already had the wake word taken out.
                if !usedFallback { text = stripWakeWord(text) }
                capture?.stripsWakeWord = false
            }
            if !text.isEmpty {
                if let anchor = voiceAnchor, model.text.hasPrefix(anchor) {
                    // Typed while talking: the spoken words go where voice left off, before what you typed.
                    let joined = TextTools.joinPhrase(anchor, text)
                    let typed = String(model.text.dropFirst(anchor.count))
                    let gap = typed.first.map { $0.isLetter || $0.isNumber } == true ? " " : ""
                    model.text = joined + gap + typed
                    voiceAnchor = joined
                } else {
                    let current = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.text = TextTools.joinPhrase(current, text)
                }
                spokenCapture = true
            }
            if final {
                voiceAnchor = nil
                finishedTalking()
            }
        }
    }

    private func finishedTalking() {
        guard let c = capture, !c.listening, !c.closing else { return }
        // Not during Wrap up: it still has the session to end once this phrase lands.
        if !hasContent, c.handsFree, !c.committing {
            return cancel(showing: c.problem ?? "Didn't catch anything")
        }
        model.phase = .typing
        model.detail = c.problem ?? (hasContent ? "" : "Didn't catch that. Type it, or hold \(model.shortcut) and try again.")
        // Typing stopped the mic: focus never left, and a half-typed correction is never auto-saved.
        if !c.typedOver { model.focusTick += 1 }
        setActivity(.typing)
        if config.autoSave && hasContent && !c.typedOver {
            commitTyped()
        } else {
            propose()
        }
    }

    /// Speech recognition is off (or missing) and Whisper isn't downloaded: say why the mic stays off.
    private func explainNoTranscriber(id: UUID, holding: Bool) {
        let off = "Speech recognition is off. Allow it in Settings, or click Get better voice to use Whisper."
        switch Permissions.speech {
        case .notAsked:
            model.detail = "Allow speech recognition so Broski can hear you"
            Task {
                _ = await Permissions.requestVoice()
                guard self.capture?.id == id else { return }
                if Permissions.speech == .granted {
                    self.startVoice(holding: holding && self.pressedAt != nil)
                } else {
                    self.model.needsPermission = true
                    self.model.detail = off
                }
            }
        case .denied:
            model.needsPermission = true
            model.detail = off
        case .granted:
            model.detail = "\(onDeviceProblem ?? "Speech recognition isn't available.") Click Get better voice to use Whisper."
        }
    }

    private func heardWhileDictating(_ text: String) {
        speechWorks()
        // Also after you stop, while Apple finishes the last words.
        guard let c = capture, c.listening || awaitingFinal?.capture == c.id else { return }
        accumulator.feed(text)
        var spoken = accumulator.text
        // Only show what Whisper hasn't written yet.
        if !liveCutPrefix.isEmpty, spoken.hasPrefix(liveCutPrefix) {
            spoken = TextTools.trimLeadingSeparators(String(spoken.dropFirst(liveCutPrefix.count)))
        }
        if c.stripsWakeWord { spoken = stripWakeWord(spoken) }
        guard spoken != model.liveText else { return }
        model.liveText = spoken
    }

    /// Apple's live preview stopped (often because Dictation is off). Whisper keeps recording regardless.
    private func liveRecognitionEnded(error: Error?) {
        // The last words after you stopped are in; an error there only means the preview is all there is.
        if let pending = awaitingFinal { return finishLive(pending.token) }
        guard let error else { return }
        let message = SpeechEngine.describe(error)
        if !transcription.isReady {
            speechFailed(message)
            model.detail = message
            model.needsPermission = message.contains("Dictation")
        }
    }

    private func stripWakeWord(_ text: String) -> String {
        if let m = matcher.firstMatch(in: text), text.distance(from: text.startIndex, to: m.range.lowerBound) <= 80 {
            return TextTools.trimLeadingSeparators(String(text[m.range.upperBound...]))
        }
        if let first = TextTools.tokens(in: text).first {
            let heard = TextTools.squash(first.text)
            for phrase in matcher.phrases where heard.count >= 2 && heard.count < phrase.count {
                let tail = String(phrase.suffix(heard.count))
                if heard == tail || (heard.count >= 3 && TextTools.levenshtein(heard, tail) <= 1) {
                    return TextTools.trimLeadingSeparators(String(text[first.range.upperBound...]))
                }
            }
        }
        return text
    }

    /// Voice activity from the mic level, against a slowly tracked noise floor.
    private func levelChanged(_ level: Float) {
        model.level = level
        let now = Date()
        let dt = min(now.timeIntervalSince(lastLevelAt), 0.2)
        lastLevelAt = now
        if level < noiseFloor { noiseFloor = level } else { noiseFloor += (level - noiseFloor) * 0.004 }
        guard var c = capture, c.listening else { return }
        if level > noiseFloor + 0.08 { c.lastVoice = now }
        if level > noiseFloor + 0.2 && level > 0.26 {
            c.voiced += dt
            if c.voiced > 0.5 { c.spokeSomething = true }
            c.spokeSinceCut = true
        }
        capture = c
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(timeInterval: 0.2, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    /// While listening: hands the last phrase to Whisper at each pause. The mic never turns itself off
    /// mid-thought; only the wake word (hands-free) ends on a pause, plus long-silence and length safety stops.
    @objc private func tick() {
        guard var c = capture, c.listening else { return }
        let now = Date()
        let quiet = now.timeIntervalSince(c.lastVoice)
        if transcription.isReady, c.spokeSinceCut, quiet >= 0.9, now.timeIntervalSince(c.lastCut) >= 1.5 {
            c.spokeSinceCut = false
            c.lastCut = now
            capture = c
            liveCutPrefix = accumulator.text
            // Apple's preview of this phrase, in case Whisper fails on it.
            let segment = model.liveText
            model.liveText = ""
            enqueueChunk(engine.drainRecording(), final: false, fallback: segment)
            return
        }
        if c.handsFree {
            if c.spokeSomething, quiet >= max(config.silenceSeconds, 2.5) { return stopListening() }
            if !c.spokeSomething, now.timeIntervalSince(c.voiceStarted) >= 8 { return stopListening() }
        }
        if quiet >= 120 {
            Log.info("Mic stopped after 2 minutes of quiet")
            stopListening()
            model.detail = "Mic turned off after 2 minutes of quiet."
        } else if now.timeIntervalSince(c.voiceStarted) >= 900 {
            stopListening()
        }
    }

    private func userEdited(_ text: String) {
        guard capture != nil, text != model.text else { return }
        if capture?.listening == true {
            Log.info("Switched to typing")
            // Phrases still being written out go in where voice left off, not after what you type.
            voiceAnchor = model.text
            stopListening(toTyping: true)
        }
        model.text = text
        model.restoredDraft = false
        model.proposal = nil
        propose(after: 1.0)
    }

    private func commitTyped() {
        guard let id = capture?.id, capture?.committing == false else { return }
        // From here until it's saved, holding the shortcut or clicking the mic does nothing.
        capture?.committing = true
        Task {
            // A phrase still being written out is part of the note.
            await chunkChain?.value
            if capture?.id == id, hasContent { await process(spoken: spokenCapture) }
            // Still open (nothing to save, or a plan to confirm first): voice works again.
            if capture?.id == id { capture?.committing = false }
        }
    }

    /// Works out (with Claude, or the rules) where the text would go, so the panel can show it before saving.
    private func propose(after delay: TimeInterval = 0) {
        proposalTask?.cancel()
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        findRelated(text)
        guard !text.isEmpty else {
            // Only clips: no need to ask anyone, it's a quote for the inbox (or wherever you pick).
            model.proposal = model.clips.isEmpty ? nil : Interpretation(title: Clip.title(for: model.clips))
            proposalFor = model.clips.isEmpty ? nil : ("", spokenCapture)
            return
        }
        let spoken = spokenCapture
        let context = model.context
        let count = model.attachments.count
        let pinned = pinnedProject
        proposalTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            model.thinkingProposal = true
            let result = await brain.interpret(text, spoken: spoken, catalog: library.catalog, activeSession: library.activeSession,
                                               context: context, attachmentCount: count, pinned: pinned)
            model.thinkingProposal = false
            guard !Task.isCancelled, model.text.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            model.proposal = result.interpretation
            proposalFor = (text, spoken)
        }
    }

    /// The project picked in the panel, so a local-only pick keeps the text away from Claude.
    private var pinnedProject: String? {
        switch model.manualDestination {
        case .project(let p)?: return p.name
        case .newProject(let name)?: return name
        case .inbox?, nil: return nil
        }
    }

    /// Decides what the capture is and acts on it.
    private func process(spoken: Bool) async {
        guard let c = capture else { return }
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = model.context
        model.phase = .thinking
        setActivity(.saving)
        if let target = model.appendTarget, model.manualDestination == nil {
            return addMore(to: target, text: text)
        }
        let session = library.activeSession
        // The panel already showed this plan, so this ⌘Return confirms it.
        let confirmed = model.proposal != nil && proposalFor?.text == text
        var decision: Interpretation
        if text.isEmpty {
            decision = Interpretation(title: model.clips.isEmpty ? "Screenshot from \(context.app ?? "screen")" : Clip.title(for: model.clips))
        } else if let proposal = model.proposal, proposalFor?.text == text {
            decision = proposal
        } else {
            decision = await brain.interpret(text, spoken: spoken, catalog: library.catalog, activeSession: session,
                                             context: context, attachmentCount: model.attachments.count, pinned: pinnedProject).interpretation
        }
        // The mic came on while Claude was deciding: saving now would throw that recording away.
        guard capture?.id == c.id, capture?.listening != true else { return }
        if let manual = model.manualDestination {
            decision.action = "note"
            switch manual {
            case .inbox: decision.project = ""
            case .project(let p): decision.project = p.name
            case .newProject(let name): decision.project = name
            }
        }
        if let kind = model.manualKind { decision.kind = kind.rawValue }
        // Dropping it, opening the dashboard or ending the session only happens once you've seen that plan:
        // this ⌘Return shows it, the next one confirms.
        if !confirmed, ["cancel", "open_dashboard", "end_session"].contains(decision.action) {
            model.proposal = decision
            proposalFor = (text, spoken)
            model.phase = .typing
            setActivity(.typing)
            return
        }
        // Read after Claude answers, so a clip or screenshot added meanwhile is saved with the rest.
        let attachments = model.attachments
        let clips = model.clips
        let quotes = Clip.markdown(clips)
        let unsaved = Draft(text: text, attachments: attachments, clips: clips, appendTarget: model.appendTarget)
        let carries = capture?.carriesDraft == true
        endCapture()

        do {
            switch decision.action {
            case "cancel":
                if carries { draft = nil }
                show(.cancelled, "Dropped it", hideAfter: 1.5)
            case "open_dashboard":
                if carries { draft = nil }
                hidePanel()
                onOpenDashboard?(decision.project.isEmpty ? nil : decision.project)
            case "start_session":
                let kind = SessionKind(rawValue: decision.sessionKind) ?? .qa
                let title = decision.sessionTitle.isEmpty ? "\(kind.label) \(Date().formatted(date: .abbreviated, time: .shortened))" : decision.sessionTitle
                var started = try library.store.startSession(kind: kind, project: decision.project.isEmpty ? nil : decision.project, title: title)
                if !attachments.isEmpty {
                    started = try library.store.append(text: "", files: attachments, context: context, to: started)
                }
                if carries { draft = nil }
                library.reload()
                model.session = started
                model.savedTitle = "\(kind.label) started"
                model.savedDetail = "Take screenshots with \(model.screenshotShortcut) and talk over them. Say “wrap up” to get the report."
                show(.saved, "", hideAfter: 6)
                Log.info("Session started: \(kind.rawValue)")
            case "end_session":
                guard var session else { show(.cancelled, "No session is running", hideAfter: 2); return }
                // What came with "wrap up" goes into the session before it ends, not away: screenshots, clips, and
                // any observation beyond the command itself.
                let entry = [Rules.isOnlyEndCommand(text) ? "" : text, quotes].filter { !$0.isEmpty }.joined(separator: "\n\n")
                if !attachments.isEmpty || !entry.isEmpty {
                    session = try library.store.append(text: entry, files: attachments, context: context, to: session)
                }
                let ended = try library.store.endSession(session)
                if carries { draft = nil }
                await finishSession(ended)
            default:
                let body = [decision.title, decision.body].filter { !$0.isEmpty }.joined(separator: "\n")
                if let session, model.manualDestination == nil {
                    // When the rules only split what you said into a title and a body, the entry keeps your words as said.
                    let said = body.isEmpty || body.split(whereSeparator: \.isWhitespace) == text.split(whereSeparator: \.isWhitespace) ? text : body
                    let entry = [text.isEmpty ? "" : said, quotes].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    let updated = try library.store.append(text: entry, files: attachments, context: context, to: session)
                    if carries { draft = nil }
                    lastAction = .entry(session)
                    library.reload()
                    model.session = updated
                    model.savedTitle = "Added to \(session.title)"
                    model.savedDetail = "\(updated.entries.count) captures · \(updated.screenshotCount) screenshots"
                } else {
                    let note = ItemDraft(
                        project: decision.project.isEmpty ? nil : decision.project,
                        kind: NoteKind(rawValue: decision.kind) ?? .note,
                        priority: Priority(rawValue: decision.priority) ?? .normal,
                        tags: decision.tags,
                        title: decision.title.isEmpty ? String(text.prefix(90)) : decision.title,
                        body: [decision.body, quotes].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                        context: context,
                        attachments: attachments
                    )
                    let item = try library.store.create(note)
                    if carries { draft = nil }
                    lastAction = .item(item)
                    lastItem = item
                    model.lastItem = item
                    library.reload()
                    model.savedTitle = item.title
                    model.savedDetail = "\(item.project ?? "Inbox") · \(item.kind.label.lowercased())" + (item.attachments.isEmpty ? "" : " · \(item.attachments.count) screenshot\(item.attachments.count == 1 ? "" : "s")")
                    Log.info("Saved \(item.kind.rawValue) to \(item.project == nil ? "the inbox" : "a project")")
                }
                play("Pop")
                show(.saved, "", hideAfter: 4)
            }
        } catch {
            // Nothing is lost: it comes back as the draft next time you open Broski.
            keep(unsaved, owner: carries)
            show(.error, "Couldn't save: \(error.localizedDescription) · kept as a draft", hideAfter: 6)
        }
    }

    private func addMore(to target: Item, text: String) {
        guard let current = resolve(target) else {
            // Deleted since: writing it back would bring it back. Keep everything here; ⌘Return makes a new note.
            model.onPickAppendTarget(nil)
            model.phase = .typing
            model.detail = "“\(target.title)” was deleted. ⌘⏎ saves this as a new note."
            setActivity(.typing)
            propose()
            return
        }
        let files = model.attachments
        let clips = model.clips
        let carries = capture?.carriesDraft == true
        endCapture()
        do {
            let addition = [text, Clip.markdown(clips)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let updated = try library.store.addMore(to: current, text: addition, files: files)
            if carries { draft = nil }
            lastAction = .edit(current)
            lastItem = updated
            model.lastItem = updated
            library.reload()
            model.savedTitle = "Added to “\(updated.title)”"
            model.savedDetail = "\(updated.project ?? "Inbox")" + (files.isEmpty ? "" : " · \(files.count) screenshot\(files.count == 1 ? "" : "s")")
            Log.info("Added more to a note")
            play("Pop")
            show(.saved, "", hideAfter: 4)
        } catch {
            // Kept unquoted, with its clips, so trying again doesn't quote them twice.
            keep(Draft(text: text, attachments: files, clips: clips, appendTarget: current), owner: carries)
            show(.error, "Couldn't add to the note: \(error.localizedDescription) · kept as a draft", hideAfter: 6)
        }
    }

    /// "Wrap up" in the session bar: what's in the panel goes into the session (or the note you picked) first,
    /// then the session ends and the report is written. Your text is never replaced.
    private func endActiveSession() {
        guard let id = capture?.id, capture?.committing == false else { return }
        if capture?.listening == true { stopListening() }
        // Like ⌘Return: a hold now would record into a capture that's about to close.
        capture?.committing = true
        Task {
            defer { if capture?.id == id { capture?.committing = false } }
            // The last phrase still being written out belongs in the last entry.
            await chunkChain?.value
            guard let c = capture, c.id == id, !c.closing else { return }
            guard var session = library.activeSession else {
                model.session = nil
                model.detail = "That session already ended."
                return
            }
            if hasContent, model.appendTarget != nil || model.manualDestination != nil {
                // Meant for a note, not the session: save it there the usual way first.
                await process(spoken: spokenCapture)
                guard capture == nil, model.phase == .saved else { return }
                if let fresh = library.activeSession, fresh.id == session.id { session = fresh }
            } else {
                if hasContent {
                    let entry = [model.text.trimmingCharacters(in: .whitespacesAndNewlines), Clip.markdown(model.clips)]
                        .filter { !$0.isEmpty }.joined(separator: "\n\n")
                    do {
                        session = try library.store.append(text: entry, files: model.attachments, context: model.context, to: session)
                    } catch {
                        // The panel stays open with everything in it.
                        model.detail = "Couldn't add it to the session: \(error.localizedDescription)"
                        return
                    }
                }
                if capture?.carriesDraft == true { draft = nil }
                endCapture()
            }
            do {
                let ended = try library.store.endSession(session)
                await finishSession(ended)
            } catch {
                library.reload()
                show(.error, "Couldn't end the session: \(error.localizedDescription)", hideAfter: 6)
            }
        }
    }

    /// A session just ended: shows progress while the report is written, then opens it,
    /// unless you've started another note meanwhile (the dashboard banner says it's ready then).
    private func finishSession(_ ended: Session) async {
        library.reload()
        model.session = nil
        model.savedTitle = "Writing the report…"
        model.savedDetail = "\(ended.entries.count) captures from \(ended.title)"
        show(.saving, "", hideAfter: 120)
        let generation = captureGeneration
        await library.writeReport(for: ended)
        guard capture == nil, captureGeneration == generation else { return }
        model.savedTitle = "Report ready"
        model.savedDetail = library.banner ?? ""
        show(.saved, "", hideAfter: 6)
        onOpenDashboard?(ended.project)
    }

    private func endCapture() {
        guard let c = capture else { return }
        // Apple's last words for this capture have nowhere to go now; the waiting chunk is released.
        if let pending = awaitingFinal { finishLive(pending.token) }
        capture = nil
        pressedAt = nil
        holdTask?.cancel()
        proposalTask?.cancel()
        proposalFor = nil
        spokenCapture = false
        voiceAnchor = nil
        ticker?.invalidate()
        ticker = nil
        engine.reportLevels = false
        // Only the note's own recording: Ask or Riff may be dictating while the panel is open.
        if c.listening {
            _ = engine.takeRecording()
            engine.resumeIdle()
        } else if engine.mode == .wake {
            // A fresh wake task drops what was heard while the panel was open, so an earlier
            // "broski" can't open a new capture later.
            engine.startWake()
        }
        changed()
    }

    private func cancel(showing message: String?) {
        Log.info("Capture cancelled: \(message ?? "by you")")
        endCapture()
        if let message { show(.cancelled, message, hideAfter: 1.5) } else { hidePanel() }
    }

    /// ⌘Return or Save: the first press while talking just stops the mic so you can review; the next one saves.
    private func saveRequested() {
        guard let c = capture else { return hidePanel() }
        if c.listening { stopListening() } else { commitTyped() }
    }

    /// Esc or ✕: closes the panel but keeps what you had as a draft for next time.
    private func cancelRequested() {
        guard capture != nil else { return hidePanel() }
        let token = UUID()
        capture?.closing = true
        capture?.closeID = token
        if capture?.listening == true { stopListening() }
        panel.dismiss()
        Task {
            await chunkChain?.value
            // Reopened meanwhile (or Esc'd again): this close is off, the latest one decides.
            guard let c = capture, c.closeID == token, !c.listening else { return }
            keepDraft()
            cancel(showing: nil)
        }
    }

    /// Reopening while an Esc close still waits on Whisper: the capture stays and the close is called off.
    private func abortClose() {
        guard capture?.closing == true else { return }
        capture?.closing = false
        capture?.closeID = nil
        // You Esc'd to not save: a phrase still landing from before the close mustn't auto-save under you.
        capture?.typedOver = true
        // The last phrase already landed while closing; settle back into typing instead of "Writing it down…".
        if pendingChunks == 0, capture?.listening == false, model.phase == .transcribing {
            model.phase = .typing
            setActivity(.typing)
            propose()
        }
    }

    private func keepDraft() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let empty = text.isEmpty && model.attachments.isEmpty && model.clips.isEmpty
        keep(empty ? nil : Draft(text: text, attachments: model.attachments, clips: model.clips, appendTarget: model.appendTarget),
             owner: capture?.carriesDraft == true)
    }

    /// Keeps unsaved content for next time. Only the capture that opened with the draft may replace or clear it;
    /// any other capture (wake word, clip, "Add more") adds to it, so an earlier draft is never lost.
    private func keep(_ new: Draft?, owner: Bool) {
        guard var kept = draft, !owner else {
            draft = new
            if new != nil { Log.info("Kept a draft") }
            return
        }
        guard let new else { return }
        if !new.text.isEmpty, !kept.text.contains(new.text) {
            kept.text = [kept.text, new.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let files = new.attachments.filter { !kept.attachments.contains($0) }
        let clips = new.clips.filter { clip in !kept.clips.contains { $0.text == clip.text } }
        kept.attachments += files
        kept.clips += clips
        draft = kept
        Log.info("Added to the kept draft")
    }

    private func discardDraft() {
        capture?.carriesDraft = false
        model.text = ""
        model.attachments = []
        model.clips = []
        model.appendTarget = nil
        draft = nil
        model.restoredDraft = false
        model.thinkingProposal = false
        // Clears the plan and the "Looks like…/Related" row along with the text.
        propose()
        layoutPanel()
        model.focusTick += 1
    }

    /// Before Broski quits or restarts: what's open becomes the draft (on disk), with the last phrase written out.
    func keepDraftForQuit() async {
        guard capture != nil else { return }
        // Closing, so the last phrase can't trigger an auto-save on its way in.
        capture?.closing = true
        capture?.closeID = nil
        if capture?.listening == true { stopListening() }
        await chunkChain?.value
        guard capture != nil else { return }
        keepDraft()
        endCapture()
    }

    /// "Restart Broski" in the panel (for Screen Recording) keeps the open note instead of dropping it.
    private func restartKeepingDraft() {
        Task {
            await keepDraftForQuit()
            Screenshot.relaunchBroski()
        }
    }

    // MARK: Draft on disk

    private var draftFile: URL { library.store.root.appendingPathComponent(".broski/draft.json") }
    private var draftFolder: URL { library.store.root.appendingPathComponent(".broski/draft-files", isDirectory: true) }

    private func inDraftFolder(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL.path == draftFolder.standardizedFileURL.path
    }

    /// Writes the draft to `.broski/draft.json`, copying screenshots out of the temp folder so they survive too.
    /// Returns the draft pointing at those copies; files that are gone are left out, since they could never be saved.
    private func persist(_ draft: Draft?) -> Draft? {
        let fm = FileManager.default
        // The notes folder was just moved away; don't recreate it at the old path.
        guard fm.fileExists(atPath: library.store.root.path) else { return draft }
        var draft = draft
        do {
            if var kept = draft {
                try fm.createDirectory(at: draftFolder, withIntermediateDirectories: true)
                kept.attachments = kept.attachments.compactMap { url -> URL? in
                    guard fm.fileExists(atPath: url.path) else { return nil }
                    if inDraftFolder(url) { return url }
                    let copy = draftFolder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
                    do {
                        try fm.copyItem(at: url, to: copy)
                        return copy
                    } catch {
                        return url
                    }
                }
                let stored = StoredDraft(
                    text: kept.text,
                    attachments: kept.attachments.map { inDraftFolder($0) ? $0.lastPathComponent : $0.path },
                    clips: kept.clips.map { StoredDraft.StoredClip(text: $0.text, app: $0.source.app, window: $0.source.window, url: $0.source.url) },
                    appendID: kept.appendTarget?.id,
                    appendProject: kept.appendTarget?.project
                )
                try JSONEncoder().encode(stored).write(to: draftFile, options: .atomic)
                draft = kept
            } else if fm.fileExists(atPath: draftFile.path) {
                try fm.removeItem(at: draftFile)
            }
            // Copies nothing points at any more; the panel may still be showing some (a note just saved from the draft).
            let used = Set(((draft?.attachments ?? []) + model.attachments).filter { inDraftFolder($0) }.map(\.lastPathComponent))
            let files = (try? fm.contentsOfDirectory(at: draftFolder, includingPropertiesForKeys: nil)) ?? []
            for file in files where !used.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        } catch {
            Log.info("Couldn't keep the draft on disk: \(error.localizedDescription)")
        }
        return draft
    }

    private func loadDraft() -> Draft? {
        guard let data = try? Data(contentsOf: draftFile),
              let stored = try? JSONDecoder().decode(StoredDraft.self, from: data) else { return nil }
        let files = stored.attachments
            .map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : draftFolder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let clips = stored.clips.map { Clip(text: $0.text, source: ItemContext(app: $0.app, window: $0.window, url: $0.url)) }
        guard !stored.text.isEmpty || !files.isEmpty || !clips.isEmpty else { return nil }
        return Draft(text: stored.text, attachments: files, clips: clips,
                     appendTarget: stored.appendID.flatMap { resolve(id: $0, project: stored.appendProject) })
    }

    private func undoLast() {
        guard let action = lastAction else { return }
        lastAction = nil
        do {
            switch action {
            case .item(let item):
                try library.store.delete(item)
                if lastItem?.id == item.id { lastItem = nil }
            case .edit(let before):
                lastItem = try library.store.save(before)
            case .entry(let session):
                if let current = library.store.sessions(in: session.project).first(where: { $0.id == session.id }) {
                    var trimmed = current
                    if !trimmed.entries.isEmpty { trimmed.entries.removeLast() }
                    try library.store.write(trimmed)
                }
            }
            library.reload()
            show(.cancelled, "Undone", hideAfter: 1.2)
        } catch {
            show(.error, "Couldn't undo: \(error.localizedDescription)", hideAfter: 3)
        }
    }

    private func openDashboardFromPanel() {
        hidePanel()
        if case .item(let item)? = lastAction { onOpenDashboard?(item.project) } else { onOpenDashboard?(nil) }
    }

    // MARK: Status

    private func speechFailed(_ message: String) {
        Log.info("Speech problem: \(message)")
        speechProblem = message
        changed()
    }

    private func speechWorks() {
        guard speechProblem != nil else { return }
        speechProblem = nil
        changed()
    }

    private func setActivity(_ new: Activity) {
        activity = new
        changed()
    }

    private func changed() {
        if capture == nil, activity != .saved, activity != .saving { activity = .idle }
        onStateChange?()
    }

    // MARK: Panel

    private func show(_ phase: PanelModel.Phase, _ detail: String, hideAfter seconds: TimeInterval) {
        model.phase = phase
        model.detail = detail
        if !panel.isVisible { panel.present(focus: false, near: nil) }
        setActivity(phase == .saved ? .saved : phase == .saving ? .saving : .idle)
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.capture == nil else { return }
            self.hidePanel()
        }
    }

    private func hidePanel() {
        hideTask?.cancel()
        panel.dismiss()
        if capture == nil {
            activity = .idle
            onStateChange?()
        }
    }

    private func play(_ sound: String) {
        guard config.playSounds else { return }
        NSSound(named: NSSound.Name(sound))?.play()
    }
}
