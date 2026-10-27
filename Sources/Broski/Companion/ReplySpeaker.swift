import AVFoundation
import BroskiCore

/// Reads Broski's replies aloud on this Mac, in the voice and at the speed you picked, and says when it's speaking
/// so the window can offer Stop.
final class ReplySpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private static let voiceKey = "BroskiReplyVoice"
    private static let speedKey = "BroskiReplySpeed"
    private let synthesizer = AVSpeechSynthesizer()
    var onSpeaking: (Bool) -> Void = { _ in }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The voice's identifier; nil is the system's voice.
    static var voice: String? {
        get { UserDefaults.standard.string(forKey: voiceKey) }
        set { UserDefaults.standard.set(newValue, forKey: voiceKey) }
    }

    static var speed: ReplySpeed {
        get { ReplySpeed(stored: UserDefaults.standard.string(forKey: speedKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: speedKey) }
    }

    /// English voices on this Mac, best quality first (the novelty ones left out), as (identifier, label).
    static let voices: [(id: String, label: String)] = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard voice.language.hasPrefix("en") else { return false }
            if #available(macOS 14.0, *) { return !voice.voiceTraits.contains(.isNoveltyVoice) }
            return true
        }
        return english.sorted { a, b in
            a.quality.rawValue != b.quality.rawValue ? a.quality.rawValue > b.quality.rawValue : a.name < b.name
        }.prefix(24).map { voice in
            let region = Locale(identifier: voice.language).region.flatMap { Locale.current.localizedString(forRegionCode: $0.identifier) }
            let quality = voice.quality == .premium ? ", premium" : voice.quality == .enhanced ? ", enhanced" : ""
            return (voice.identifier, "\(voice.name) (\(region ?? voice.language)\(quality))")
        }
    }()

    var speaking: Bool { synthesizer.isSpeaking }

    func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: SpokenText.clean(text))
        utterance.rate = Self.speed.rate
        if let id = Self.voice, let voice = AVSpeechSynthesisVoice(identifier: id) { utterance.voice = voice }
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) { report(true) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { report(false) }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { report(false) }

    private func report(_ on: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A new reply starts as the old one is cancelled: still speaking.
            self.onSpeaking(on || self.synthesizer.isSpeaking)
        }
    }
}
