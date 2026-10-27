import Foundation
import Testing
@testable import BroskiCore

/// Hearing you: a mic that sends several channels (a mic array, a streaming setup) still reaches transcription, and
/// when nothing comes through Broski says so and names the mic, instead of quietly doing nothing.
@Suite("Listening")
struct ListeningTests {
    private func tone(_ count: Int, amplitude: Float = 0.3) -> [Float] {
        (0..<count).map { amplitude * sin(Float($0) * 2 * .pi * 300 / 44_100) }
    }

    @Test("a voice on any one of three channels survives the mix to mono")
    func voiceOnAnyChannel() {
        let voice = tone(4410)
        let quiet = [Float](repeating: 0, count: 4410)
        for channel in 0..<3 {
            var channels = [quiet, quiet, quiet]
            channels[channel] = voice
            let mono = AudioMix.mono(channels)
            #expect(mono.count == voice.count)
            #expect(AudioMix.peak(mono) > 0.29, "voice on channel \(channel) was lost")
        }
    }

    @Test("channels that carry sound are averaged; dead ones don't water them down")
    func averagesLiveChannels() {
        let a = tone(1000, amplitude: 0.2)
        let b = tone(1000, amplitude: 0.4)
        let dead = [Float](repeating: 0, count: 1000)
        let mono = AudioMix.mono([a, dead, b])
        #expect(abs(AudioMix.peak(mono) - 0.3) < 0.01)
        #expect(AudioMix.mono([a]) == a)
        #expect(AudioMix.peak(AudioMix.mono([dead, dead])) == 0)
        #expect(AudioMix.mono([]).isEmpty)
    }

    @Test("no signal at all, sound without words, and speech each get their own verdict")
    func verdicts() {
        #expect(MicVerdict.of(peak: 0, heardWords: false) == .noSound)
        #expect(MicVerdict.of(peak: 0.00005, heardWords: false) == .noSound)
        #expect(MicVerdict.of(peak: 0.02, heardWords: false) == .noWords)
        #expect(MicVerdict.of(peak: 0.3, heardWords: true) == .speech)
    }

    @Test("when nothing came through, the message names the mic and what to try")
    func messages() throws {
        let none = try #require(MicVerdict.noSound.message(mic: "Studio Mic"))
        #expect(none.contains("Studio Mic") && none.contains("another app"))
        let words = try #require(MicVerdict.noWords.message(mic: "Studio Mic"))
        #expect(words.contains("Studio Mic"))
        #expect(MicVerdict.speech.message(mic: "Studio Mic") == nil)
        // The iPhone has no mic to choose: it says what to close instead.
        let phone = try #require(MicVerdict.noSound.message(mic: "the microphone", canChoose: false))
        #expect(phone.contains("another app") && !phone.contains("Choose another mic"))
    }

    @Test("the chosen mic is used while it's plugged in; otherwise the system's mic")
    func choosingTheMic() {
        let builtIn = MicDevice(uid: "built-in", name: "Built-in Microphone")
        let usb = MicDevice(uid: "usb-1", name: "USB Mic")
        let devices = [builtIn, usb]
        #expect(MicChoice.resolve(saved: "usb-1", devices: devices) == usb)
        #expect(MicChoice.resolve(saved: "gone", devices: devices) == nil)
        #expect(MicChoice.resolve(saved: nil, devices: devices) == nil)
        #expect(MicChoice.label(saved: "usb-1", devices: devices, systemDefault: "Built-in Microphone") == "USB Mic")
        #expect(MicChoice.label(saved: "gone", devices: devices, systemDefault: "Built-in Microphone") == "Built-in Microphone")
        #expect(MicChoice.label(saved: nil, devices: devices, systemDefault: nil) == "the system's mic")
    }

    @Test("replies are read without markdown: no stars, hashes, backticks or link addresses")
    func spokenText() {
        let reply = "## Plan\n**Ship it** today. Run `make`, then see [the docs](https://example.com/docs).\n- first\n- second"
        let spoken = SpokenText.clean(reply)
        #expect(!spoken.contains("*") && !spoken.contains("#") && !spoken.contains("`") && !spoken.contains("https"))
        #expect(spoken.contains("Ship it today.") && spoken.contains("the docs") && spoken.contains("first"))
        #expect(SpokenText.clean("snake_case stays") == "snake_case stays")
    }

    @Test("three reading speeds, normal in the middle; an unknown setting reads as normal")
    func speeds() {
        #expect(ReplySpeed.slower.rate < ReplySpeed.normal.rate && ReplySpeed.normal.rate < ReplySpeed.faster.rate)
        #expect(ReplySpeed(stored: "faster") == .faster)
        #expect(ReplySpeed(stored: nil) == .normal && ReplySpeed(stored: "warp") == .normal)
    }

    @Test("stopping a reply isn't an error to show")
    func stoppingIsNotAProblem() {
        #expect(Cancellation.isStop(CancellationError()))
        #expect(Cancellation.isStop(URLError(.cancelled)))
        #expect(!Cancellation.isStop(URLError(.timedOut)))
        #expect(!Cancellation.isStop(ModelFailure.empty))
    }
}
