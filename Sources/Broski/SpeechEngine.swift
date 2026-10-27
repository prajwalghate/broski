import AVFoundation
import BroskiCore
import CoreAudio
import Speech

enum EngineError: LocalizedError {
    case noMicrophone
    case noRecognizer

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No microphone is available."
        case .noRecognizer: return "Speech recognition isn't set up."
        }
    }
}

/// Owns the microphone and Apple's speech recognizer. One audio tap feeds two modes:
///  - wake: a rolling on-device transcription that only exists to spot the wake word.
///    It is never stored or logged, and it never runs through Apple's servers.
///  - dictation: a fresh transcription for the note, seeded with the last couple of
///    seconds of audio so words said right after the wake word aren't lost.
/// Everything except the audio tap runs on the main thread.
final class SpeechEngine: NSObject {
    enum Mode { case off, wake, dictation }

    var onWakeTranscript: ((String) -> Void)?
    var onDictationTranscript: ((String) -> Void)?
    /// Fires once the dictation transcript is final. Carries the error if recognition failed.
    var onDictationEnded: ((Error?) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onProblem: ((String) -> Void)?

    /// Phrases the recognizer should favour: the wake words and project names.
    var contextualStrings: [String] = []
    /// Whether wake listening should run whenever no note is being dictated.
    var wantsWake = false
    /// Mic level updates are only sent while the panel shows a meter.
    var reportLevels = false

    private(set) var mode: Mode = .off
    private(set) var isOnDevice = false
    private(set) var localeIdentifier = ""
    var hasRecognizer: Bool { recognizer != nil }

    /// Diagnostics feed recorded audio through `simulate(_:)` instead of starting the microphone.
    var simulatedInput = false

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var audioRunning = false
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var taskStarted = Date()
    private var sawResult = false
    private var wakeBackoff: TimeInterval = 0.3
    private var quickFailures = 0
    private var restartWork: DispatchWorkItem?
    private var maintenanceTimer: Timer?

    // Shared with the audio thread, guarded by `lock`.
    private let lock = NSLock()
    private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var liveAppended = 0
    private var recording = false
    private var recorded: [AVAudioPCMBuffer] = []
    private var recordedPeak: Float = 0
    private var latestLevel: Float = 0
    private var ring = AudioRing(maxSeconds: 4)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(audioConfigurationChanged),
            name: .AVAudioEngineConfigurationChange, object: audioEngine
        )
    }

    /// Picks a recognizer, preferring one that runs on-device. Returns a problem to show if voice is limited.
    @discardableResult
    func configure(locale preferred: String) -> String? {
        stop()
        var candidates = [preferred == "auto" || preferred.isEmpty ? Locale.current.identifier : preferred]
        if !candidates.contains("en-US") { candidates.append("en-US") }

        for id in candidates {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.supportsOnDeviceRecognition {
                use(r, onDevice: true)
                return nil
            }
        }
        guard let fallback = SFSpeechRecognizer(locale: Locale(identifier: candidates[0])) ?? SFSpeechRecognizer() else {
            recognizer = nil
            return "Speech recognition isn't available for \(candidates[0])."
        }
        use(fallback, onDevice: false)
        return "On-device speech isn't available, so the wake word is off. The shortcut still works."
    }

    /// Apple's speech service refuses to run while Dictation is off, even on-device.
    static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.localizedCaseInsensitiveContains("dictation") || text.localizedCaseInsensitiveContains("siri") {
            return "Turn on Dictation in System Settings › Keyboard so Broski can hear you"
        }
        return text
    }

    static func code(of error: Error?) -> String {
        guard let error else { return "no error" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    private func refreshRecognizer() {
        guard let fresh = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else { return }
        use(fresh, onDevice: isOnDevice && fresh.supportsOnDeviceRecognition)
    }

    private func use(_ r: SFSpeechRecognizer, onDevice: Bool) {
        r.queue = .main
        r.defaultTaskHint = .dictation
        recognizer = r
        isOnDevice = onDevice
        localeIdentifier = r.locale.identifier
    }

    // MARK: Control (main thread)

    func startWake() {
        guard wantsWake, isOnDevice, mode != .dictation else { return }
        do {
            try ensureAudio()
        } catch {
            onProblem?(error.localizedDescription)
            return
        }
        startTask(.wake, replay: 0)
    }

    func stop() {
        cancelTask()
        mode = .off
        stopAudio()
    }

    /// Starts recording a note. With `live`, Apple's recognizer also streams a preview transcript;
    /// without it (or without speech permission) the audio is only recorded, for Whisper.
    func beginDictation(replay: TimeInterval, live: Bool = true) throws {
        try ensureAudio()
        lock.lock()
        recorded = replay > 0 ? ring.last(seconds: replay) : []
        recordedPeak = 0
        recording = true
        lock.unlock()
        if live, recognizer != nil {
            startTask(.dictation, replay: replay)
        } else {
            cancelTask()
            mode = .dictation
        }
    }

    /// Stops recording and hands over everything recorded since `beginDictation`.
    func takeRecording() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        recording = false
        let taken = recorded
        recorded = []
        return taken
    }

    /// The loudest sample since `beginDictation`: none at all means the mic sent nothing (see MicVerdict).
    var peakSinceDictation: Float {
        lock.lock()
        defer { lock.unlock() }
        return recordedPeak
    }

    /// 0...1 loudness of the latest buffer, for a meter.
    var level: Float {
        lock.lock()
        defer { lock.unlock() }
        return latestLevel
    }

    /// The mic name in use, for "Listening on …".
    private(set) var microphoneName = ""

    /// The mic choice changed: reopen on the new one if the mic is on now, otherwise the next start uses it.
    func reopenMicrophone() {
        recoverFromDeviceChange()
    }

    /// Hands over what's been recorded so far and keeps recording, so Whisper can work phrase by phrase.
    func drainRecording() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let taken = recorded
        recorded = []
        return taken
    }

    /// Stops feeding audio. The recognizer sends a final transcript, then `onDictationEnded` fires.
    func endDictation() {
        guard mode == .dictation else { return }
        lock.lock()
        liveRequest?.endAudio()
        liveRequest = nil
        lock.unlock()
    }

    /// Drops any running transcription, then goes back to wake listening, or turns the mic off.
    func resumeIdle() {
        cancelTask()
        mode = .off
        if wantsWake && isOnDevice { startWake() } else { stopAudio() }
    }

    // MARK: Recognition tasks

    private func cancelTask() {
        if mode == .dictation, task != nil {
            lock.lock()
            let appended = liveAppended
            lock.unlock()
            Log.info(String(format: "Dictation task %d cancelled after %.1fs: %d live buffers, results: %@",
                            generation, Date().timeIntervalSince(taskStarted), appended, sawResult ? "yes" : "no"))
        }
        generation += 1
        restartWork?.cancel()
        lock.lock()
        liveRequest?.endAudio()
        liveRequest = nil
        lock.unlock()
        task?.cancel()
        task = nil
    }

    private func startTask(_ newMode: Mode, replay: TimeInterval) {
        guard let recognizer else {
            onProblem?(EngineError.noRecognizer.localizedDescription)
            return
        }
        cancelTask()
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = isOnDevice
        request.contextualStrings = contextualStrings
        request.taskHint = .dictation
        request.addsPunctuation = newMode == .dictation

        mode = newMode
        taskStarted = Date()
        sawResult = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, gen == self.generation else { return }
            if let result {
                self.deliver(result.bestTranscription.formattedString, mode: newMode)
            }
            if gen == self.generation, error != nil || result?.isFinal == true {
                self.taskFinished(mode: newMode, error: error)
            }
        }

        // Feed the replay once the task exists, as Apple's samples do; live audio follows right after.
        lock.lock()
        let replayed = replay > 0 ? ring.last(seconds: replay) : []
        for buffer in replayed { request.append(buffer) }
        liveRequest = request
        liveAppended = 0
        lock.unlock()
        if newMode == .dictation { Log.info("Dictation task \(gen) started, replaying \(replayed.count) buffers") }
    }

    private func deliver(_ text: String, mode delivered: Mode) {
        if !sawResult {
            sawResult = true
            if delivered == .dictation {
                Log.info(String(format: "Dictation: first transcript after %.1fs", Date().timeIntervalSince(taskStarted)))
            }
        }
        switch delivered {
        case .wake:
            onWakeTranscript?(text)
            // The wake transcript only exists to spot the wake word; keep it short.
            if mode == .wake, text.count > 240 { startTask(.wake, replay: 1.0) }
        case .dictation:
            onDictationTranscript?(text)
        case .off:
            break
        }
    }

    private func taskFinished(mode finished: Mode, error: Error?) {
        generation += 1
        lock.lock()
        liveRequest = nil
        lock.unlock()
        task = nil

        let lived = Date().timeIntervalSince(taskStarted)
        switch finished {
        case .wake:
            if lived < 3 {
                quickFailures += 1
                wakeBackoff = min(wakeBackoff * 2, 15)
                if quickFailures == 1 || quickFailures % 10 == 0 {
                    Log.info("Wake task stopped after \(String(format: "%.1f", lived))s (\(quickFailures)x): \(Self.code(of: error))")
                }
                // A recognizer created while Dictation was off keeps failing; make a fresh one.
                if quickFailures % 3 == 0 { refreshRecognizer() }
                if quickFailures == 4 {
                    onProblem?(error.map(Self.describe) ?? "Speech recognition keeps stopping.")
                }
            } else {
                quickFailures = 0
                wakeBackoff = 0.3
            }
            scheduleWakeRestart(after: wakeBackoff)
        case .dictation:
            Log.info("Dictation task finished after \(String(format: "%.1f", lived))s, results: \(sawResult), \(Self.code(of: error))")
            mode = .off
            onDictationEnded?(error)
        case .off:
            break
        }
    }

    private func scheduleWakeRestart(after delay: TimeInterval) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsWake, self.mode == .wake, self.task == nil else { return }
            // Replay the gap so a wake word said during the restart still counts.
            self.startTask(.wake, replay: min(delay, 1.0) + 0.3)
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Long recognition sessions drift and grow; start a fresh one every minute or so.
    @objc private func maintain() {
        guard mode == .wake, task != nil, Date().timeIntervalSince(taskStarted) > 50 else { return }
        startTask(.wake, replay: 1.0)
    }

    // MARK: Audio

    /// Diagnostics only: treat `buffer` as if the microphone tap delivered it.
    func simulate(_ buffer: AVAudioPCMBuffer) {
        consume(buffer)
    }

    private func ensureAudio() throws {
        guard !audioRunning else { return }
        if simulatedInput {
            audioRunning = true
            return
        }
        // A mic you chose runs plain: voice processing works on the system's devices.
        let chosen = Microphones.chosenDevice
        let processing = voiceIsolation && !voiceProcessingFailed && chosen == nil
        do {
            try startMicrophone(voiceProcessing: processing, device: chosen)
        } catch where processing {
            // Voice processing can't run on some device combinations (for example a Bluetooth
            // speaker with the built-in mic). Remember that and use the plain microphone.
            Log.info("Voice processing couldn't start (\(error.localizedDescription)); using the plain mic")
            voiceProcessingFailed = true
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
            audioEngine.reset()
            try startMicrophone(voiceProcessing: false, device: nil)
        }
        maintenanceTimer?.invalidate()
        maintenanceTimer = Timer.scheduledTimer(
            timeInterval: 5, target: self, selector: #selector(maintain), userInfo: nil, repeats: true
        )
    }

    private func startMicrophone(voiceProcessing: Bool, device: AudioDeviceID?) throws {
        let input = audioEngine.inputNode
        applyVoiceProcessing(to: input, enabled: voiceProcessing)
        // Without voice processing the engine keeps whichever device it last had, so say which: the chosen mic, or the
        // system's (back from a chosen one).
        if !voiceProcessing, let id = device ?? Microphones.systemDefault, let unit = input.audioUnit {
            var value = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &value, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.info("Couldn't switch to the mic \(Microphones.name(of: id) ?? "\(id)") (\(status))") }
        }
        microphoneName = (device ?? Microphones.systemDefault).flatMap(Microphones.name(of:)) ?? "the system's mic"
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineError.noMicrophone }

        lock.lock()
        ring = AudioRing(maxSeconds: 4)
        lock.unlock()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        audioRunning = true
        Log.info("Microphone on: \(microphoneName) (\(Int(format.sampleRate)) Hz, \(format.channelCount) ch, voice processing \(voiceProcessingActive))")
    }

    /// Apple's voice processing: echo cancellation (removes what this Mac is playing, like a video),
    /// noise suppression, and level control. Other apps' audio is ducked as little as possible.
    var voiceIsolation = true
    private(set) var voiceProcessingActive = false

    /// Voice processing failed with this exact mic + speaker pair before, so don't retry it
    /// (each attempt costs about a second before the mic starts, which swallows first words).
    private var voiceProcessingFailed: Bool {
        get { UserDefaults.standard.string(forKey: "BroskiVoiceProcessingFailed") == Self.deviceKey }
        set { UserDefaults.standard.set(newValue ? Self.deviceKey : nil, forKey: "BroskiVoiceProcessingFailed") }
    }

    private static var deviceKey: String {
        func device(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
            return id
        }
        return "\(device(kAudioHardwarePropertyDefaultInputDevice))-\(device(kAudioHardwarePropertyDefaultOutputDevice))"
    }

    private func applyVoiceProcessing(to input: AVAudioInputNode, enabled: Bool) {
        guard input.isVoiceProcessingEnabled != enabled else {
            voiceProcessingActive = enabled
            return
        }
        do {
            try input.setVoiceProcessingEnabled(enabled)
            if enabled {
                if #available(macOS 14.0, *) {
                    input.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                }
                // Voice processing runs input and output as one unit, so the output side must exist.
                _ = audioEngine.mainMixerNode
                audioEngine.mainMixerNode.outputVolume = 0
            }
            voiceProcessingActive = enabled
        } catch {
            voiceProcessingActive = false
            Log.info("Voice processing unavailable: \(error.localizedDescription)")
        }
    }

    /// Diagnostics: records the real microphone for `seconds` and reports what came in.
    func micCheck(seconds: TimeInterval) async -> String {
        do {
            try beginDictation(replay: 0, live: false)
        } catch {
            return "mic failed: \(error.localizedDescription)"
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        let audio = takeRecording()
        let format = audio.first.map { "\($0.format)" } ?? "none"
        let peak = audio.map { AudioRing.level(of: $0) }.max() ?? 0
        stop()
        return "voice processing \(voiceProcessingActive), \(audio.count) buffers, format \(format), peak level \(String(format: "%.2f", peak))"
    }

    private func stopAudio() {
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        guard audioRunning else { return }
        if simulatedInput {
            audioRunning = false
            return
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioRunning = false
        Log.info("Microphone off")
    }

    /// Audio thread.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        // Everything downstream hears one channel: a mic array or a streaming setup sends several.
        let copy = buffer.format.channelCount > 1 ? AudioRing.mono(buffer) : AudioRing.copy(buffer)
        let heard = copy ?? buffer
        let level = AudioRing.level(of: heard)
        let peak = AudioRing.peak(of: heard)
        lock.lock()
        latestLevel = level
        if let copy {
            ring.append(copy)
            if recording {
                recorded.append(copy)
                recordedPeak = max(recordedPeak, peak)
            }
        }
        if let liveRequest {
            liveRequest.append(heard)
            liveAppended += 1
        }
        lock.unlock()
        if reportLevels {
            DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        }
    }

    @objc private func audioConfigurationChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.recoverFromDeviceChange() }
    }

    /// Plugging in headphones or switching inputs stops the engine; restart on the new device.
    private func recoverFromDeviceChange() {
        guard audioRunning else { return }
        Log.info("Audio input changed; restarting the microphone")
        let previous = mode
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioRunning = false
        do {
            try ensureAudio()
        } catch {
            onProblem?("Couldn't restart the microphone: \(error.localizedDescription)")
            return
        }
        switch previous {
        case .wake: startTask(.wake, replay: 0)
        case .dictation: endDictation()  // the new format can't join the old request; finish with what we have
        case .off: break
        }
    }
}

/// The last few seconds of microphone audio, used to replay speech into a new recognition task.
struct AudioRing {
    let maxSeconds: Double
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames = 0

    init(maxSeconds: Double) {
        self.maxSeconds = maxSeconds
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        buffers.append(buffer)
        frames += Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        while let first = buffers.first, Double(frames - Int(first.frameLength)) / rate >= maxSeconds {
            buffers.removeFirst()
            frames -= Int(first.frameLength)
        }
    }

    func last(seconds: Double) -> [AVAudioPCMBuffer] {
        guard let rate = buffers.last?.format.sampleRate else { return [] }
        var picked: [AVAudioPCMBuffer] = []
        var total = 0
        for buffer in buffers.reversed() {
            picked.append(buffer)
            total += Int(buffer.frameLength)
            if Double(total) / rate >= seconds { break }
        }
        return picked.reversed()
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let interleaved = buffer.format.isInterleaved
        let channels = interleaved ? 1 : Int(buffer.format.channelCount)
        let samples = Int(buffer.frameLength) * (interleaved ? Int(buffer.format.channelCount) : 1)
        for ch in 0..<channels {
            dst[ch].update(from: src[ch], count: samples)
        }
        return out
    }

    /// One channel from a mic that sends several (AudioMix.mono: the channels with sound, averaged).
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, !buffer.format.isInterleaved,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let mixed = AudioMix.mono((0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: src[$0], count: frames)) })
        mixed.withUnsafeBufferPointer { if let base = $0.baseAddress { dst[0].update(from: base, count: frames) } }
        out.frameLength = buffer.frameLength
        return out
    }

    static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        return peak
    }

    /// 0...1 loudness for the level meter.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        return max(0, min(1, (db + 55) / 45))
    }
}
