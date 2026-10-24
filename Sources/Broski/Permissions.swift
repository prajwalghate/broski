import AVFoundation
import AppKit
import Speech

/// Microphone and speech-recognition access: checked without prompting, requested only when voice is used.
enum Permissions {
    enum State { case granted, denied, notAsked }

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static var speech: State {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    static var voiceGranted: Bool { microphone == .granted && speech == .granted }
    static var voiceDenied: Bool { microphone == .denied || speech == .denied }

    /// Asks for whatever hasn't been asked yet. True when both are granted.
    static func requestVoice() async -> Bool {
        if speech == .notAsked {
            _ = await withCheckedContinuation { (done: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
            }
        }
        if microphone == .notAsked {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return voiceGranted
    }

    static func openMicrophoneSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
    static func openSpeechSettings() { open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") }
    static func openKeyboardSettings() { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }

    private static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}

/// A five-second "say something" test used in onboarding and settings. Runs its own mic and
/// recognizer so it works before anything else is set up, and explains the usual failures.
@MainActor
final class VoiceCheck: ObservableObject {
    enum State: Equatable {
        case idle, listening
        case heard(String)
        case failed(String, needsDictation: Bool)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var level: Float = 0

    private var audio: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = ""
    private var stopTask: Task<Void, Never>?

    func start(locale: String) {
        guard state != .listening else { return }
        Task { await run(locale: locale) }
    }

    private func run(locale: String) async {
        guard await Permissions.requestVoice() else {
            state = .failed("Microphone or speech access is off for Broski.", needsDictation: false)
            return
        }
        let id = locale == "auto" ? Locale.current.identifier : locale
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) ?? SFSpeechRecognizer() else {
            state = .failed("Speech recognition isn't available for \(id).", needsDictation: false)
            return
        }
        recognizer.queue = .main
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true

        let audio = AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            state = .failed("No microphone is available.", needsDictation: false)
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = AudioRing.level(of: buffer)
            DispatchQueue.main.async { self?.level = level }
        }
        do {
            audio.prepare()
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            state = .failed("Couldn't start the microphone: \(error.localizedDescription)", needsDictation: false)
            return
        }

        self.audio = audio
        self.request = request
        transcript = ""
        state = .listening
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result { self.transcript = result.bestTranscription.formattedString }
            if let error, self.transcript.isEmpty, self.state == .listening {
                let message = SpeechEngine.describe(error)
                self.finish(.failed(message, needsDictation: message.contains("Dictation")))
            } else if result?.isFinal == true {
                self.finish(self.transcript.isEmpty ? .failed("Didn't hear anything. Is the right mic selected in Sound settings?", needsDictation: false) : .heard(self.transcript))
            }
        }
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.state == .listening else { return }
            self.request?.endAudio()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.state == .listening {
                self.finish(self.transcript.isEmpty ? .failed("Didn't hear anything. Is the right mic selected in Sound settings?", needsDictation: false) : .heard(self.transcript))
            }
        }
    }

    private func finish(_ result: State) {
        stopTask?.cancel()
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        audio = nil
        task?.cancel()
        task = nil
        request = nil
        level = 0
        state = result
    }
}
