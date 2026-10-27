import AVFoundation
import BroskiCore

/// Reads Broski's replies aloud. Takes the audio session only while speaking, so the mic and other apps get it back.
final class ReplyVoice: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private static let speedKey = "BroskiReplySpeed"
    private let synthesizer = AVSpeechSynthesizer()
    /// Speaking or not, for the Stop button.
    var onSpeaking: (Bool) -> Void = { _ in }

    static var speed: ReplySpeed {
        get { ReplySpeed(stored: UserDefaults.standard.string(forKey: speedKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: speedKey) }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: SpokenText.clean(text))
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = Self.speed.rate
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { report(true) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { release(); report(false) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { release(); report(false) }

    private func report(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A new reply starts as the old one is cancelled: still speaking.
            self.onSpeaking(on || self.synthesizer.isSpeaking)
        }
    }

    /// Gives the audio back, unless the mic has taken the session meanwhile (stopping speech to talk).
    private func release() {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
