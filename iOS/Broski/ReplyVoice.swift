import AVFoundation

/// Reads Broski's replies aloud. Takes the audio session only while speaking, so the mic and other apps get it back.
final class ReplyVoice: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func say(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        let spoken = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        utterance.rate = 0.52
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { release() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { release() }

    /// Gives the audio back, unless the mic has taken the session meanwhile (stopping speech to talk).
    private func release() {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playback else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
