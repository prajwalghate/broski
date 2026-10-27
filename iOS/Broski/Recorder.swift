import AVFoundation
import BroskiBark
import BroskiCore
import Speech

/// Speech to text on the iPhone. Starts only when you ask and never stops on its own:
/// when the recognizer finishes a stretch (after a pause), a new one picks up where it left off.
/// Apple's recognizer shows the words as you talk; when Bark is on, it writes the final text from the recording.
@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    /// Everything heard since recording started.
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0
    @Published var problem: String?
    /// The mic was taken away mid-recording (a call, Siri, another app, a recognizer that keeps failing):
    /// gets what was heard, so it isn't lost.
    var onInterrupted: ((String) -> Void)?
    /// stop() is waiting for the last words; a second stop meanwhile does nothing.
    private(set) var isStopping = false
    /// The mic is off and Bark is writing out what was said (a moment; longer for a long note).
    @Published private(set) var finishing = false
    /// Names Bark's text is matched against (your projects), so "hip three observatory" lands as hip3-observatory.
    var vocabulary: () -> [String] = { [] }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    /// The stretch being recognized; nil once it has delivered its final words (or failed).
    private var current: SFSpeechAudioBufferRecognitionRequest?
    private var committed = ""
    private var partial = ""
    /// start() waits on permission prompts: a second start meanwhile (a double tap, the Action Button) is ignored.
    private var starting = false
    /// Stretches in a row that failed at once, hearing nothing.
    private var failures = 0
    private var stretchStarted = Date()
    private var restart: Task<Void, Never>?
    /// The audio tap runs on its own thread; it feeds whichever request is current.
    private nonisolated let feed = RequestFeed()
    /// The recording itself, at 16 kHz, for Bark.
    private nonisolated let audio = BarkAudio()
    /// Kept for as long as the Recorder, which lives as long as the app.
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                guard type == .began else { return }
                Task { @MainActor in self?.lostMic("Stopped: another app took the microphone. What you said is kept.") }
            },
            // AirPods connecting or a route change stops the engine; the UI would keep saying "Listening".
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.configurationChanged() }
            },
        ]
    }

    func start() async {
        guard !isRecording, !starting, !finishing else { return }
        starting = true
        defer { starting = false }
        problem = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            problem = "Microphone access is off. Turn it on in Settings › Broski."
            return
        }
        let speech = await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard speech == .authorized else {
            problem = "Speech recognition is off. Turn it on in Settings › Broski."
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            problem = MicVerdict.couldNotStart(mic: "the microphone", canChoose: false)
            return
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // Mid route change (AirPods connecting) the input can report 0 Hz, and a tap on that crashes.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            release()
            problem = "The microphone isn't ready yet. Try again in a moment."
            return
        }
        committed = ""
        partial = ""
        transcript = ""
        failures = 0
        feed.resetPeak()
        startTask()
        audio.reset()
        let keepAudio = PhoneBark.shared.usable

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [feed, audio, weak self] buffer, _ in
            feed.append(buffer)
            if keepAudio { audio.append(buffer) }
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        do {
            try engine.start()
            isRecording = true
        } catch {
            // Give other apps their audio back and drop the recognition task, not just the tap.
            release()
            problem = MicVerdict.couldNotStart(mic: "the microphone", canChoose: false)
        }
    }

    /// Stops and returns everything heard. The recognizer runs a little behind the audio, so this waits
    /// (briefly) for the last words instead of cutting them off; then Bark, when it's on, writes the text.
    func stop() async -> String {
        guard isRecording, !isStopping else { return "" }
        isStopping = true
        restart?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        level = 0
        feed.finish()
        let deadline = Date().addingTimeInterval(1.2)
        while current != nil, isRecording, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let recording = audio.take()
        let heard = stopNow()
        let peak = feed.peak
        guard !recording.isEmpty else { return said(heard, peak: peak) }
        finishing = true
        defer { finishing = false }
        guard let written = await PhoneBark.shared.transcribe(recording, vocabulary: vocabulary()) else { return said(heard, peak: peak) }
        transcript = written
        return said(written, peak: peak)
    }

    /// Nothing heard gets a reason: the mic sent nothing at all (another app holds it), or no words came through.
    private func said(_ text: String, peak: Float) -> String {
        let verdict = MicVerdict.of(peak: peak, heardWords: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if let why = verdict.message(mic: "the microphone", canChoose: false) { problem = why }
        return text
    }

    /// Stops at once (going to the background, the mic taken away) and returns everything heard so far.
    @discardableResult
    func stopNow() -> String {
        guard isRecording else { return "" }
        isRecording = false
        isStopping = false
        release()
        let text = TextTools.joinPhrase(committed, partial)
        transcript = text
        // Stopping at once keeps Apple's text; stop() has taken the recording already.
        audio.reset()
        return text
    }

    /// Lets go of the mic and the recognizer, and gives other apps their audio back.
    private func release() {
        restart?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        feed.finish()
        task?.cancel()
        task = nil
        current = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func lostMic(_ why: String) {
        guard isRecording, !isStopping else { return }
        let heard = stopNow()
        problem = why
        onInterrupted?(heard)
    }

    private func configurationChanged() {
        // The engine stops itself when the input changes; one that kept running needs nothing.
        guard !engine.isRunning else { return }
        lostMic("Stopped: the microphone changed (headphones?). What you said is kept.")
    }

    private func startTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        feed.use(request)
        current = request
        stretchStarted = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in self?.handle(text: text, final: final, failed: error != nil, request: request) }
        }
    }

    private func handle(text: String?, final: Bool, failed: Bool, request: SFSpeechAudioBufferRecognitionRequest) {
        guard isRecording, request === current else { return }
        if let text { partial = text }
        transcript = TextTools.joinPhrase(committed, partial)
        guard final || failed else { return }
        let heard = !partial.isEmpty
        committed = transcript
        partial = ""
        current = nil
        // stop() was waiting for exactly this.
        guard !isStopping else { return }
        guard failed else {
            // A pause ended this stretch; keep what we have and keep listening.
            startTask()
            return
        }
        // An error moments after starting that heard nothing isn't a pause (no network, no on-device model):
        // a third in a row won't get better, so stop instead of spinning.
        failures = heard || Date().timeIntervalSince(stretchStarted) > 2 ? 0 : failures + 1
        guard failures < 3 else {
            let kept = stopNow()
            problem = "Speech recognition keeps failing, so the mic is off. What you said is kept."
            onInterrupted?(kept)
            return
        }
        restart = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, isRecording, !isStopping else { return }
            startTask()
        }
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(count)), 0.000_01))
        return max(0, min(1, (db + 55) / 45))
    }
}

/// Lock-guarded hand-off between the audio thread and the current recognition request.
final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func use(_ new: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        request?.endAudio()
        request = new
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var loudest: Float = 0
        if let samples = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { loudest = max(loudest, abs(samples[i])) }
        }
        lock.lock()
        request?.append(buffer)
        heardPeak = max(heardPeak, loudest)
        lock.unlock()
    }

    /// The loudest sample since `resetPeak`: none at all means the mic sent nothing (another app holds it).
    private var heardPeak: Float = 0
    var peak: Float {
        lock.lock()
        defer { lock.unlock() }
        return heardPeak
    }

    func resetPeak() {
        lock.lock()
        heardPeak = 0
        lock.unlock()
    }

    func finish() {
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
    }
}
