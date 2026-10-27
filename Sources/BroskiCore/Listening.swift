import Foundation

/// What a microphone sends, as one channel Broski can transcribe.
public enum AudioMix {
    /// Below this a channel carries nothing at all (muted, held by another app, or a virtual input with nothing
    /// playing): not even the room noise every real mic picks up.
    public static let deadLevel: Float = 0.0001

    /// One channel from several: the average of the channels that carry sound. A voice on any one of them survives
    /// (macOS's converter turns three discrete channels into silence), and dead channels don't water it down.
    /// All dead gives silence.
    public static func mono(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        if channels.count == 1 { return first }
        let frames = channels.map(\.count).min() ?? 0
        let live = channels.filter { peak($0) >= deadLevel }
        guard !live.isEmpty else { return [Float](repeating: 0, count: frames) }
        var out = [Float](repeating: 0, count: frames)
        for channel in live {
            for i in 0..<frames { out[i] += channel[i] }
        }
        let scale = 1 / Float(live.count)
        for i in 0..<frames { out[i] *= scale }
        return out
    }

    public static func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }
}

/// What came of a recording that turned up no words, so Broski can say why instead of doing nothing.
public enum MicVerdict: Equatable, Sendable {
    case speech
    /// Sound, but no words in it: too quiet, too far, or only noise.
    case noWords
    /// No signal at all.
    case noSound

    public static func of(peak: Float, heardWords: Bool) -> MicVerdict {
        if heardWords { return .speech }
        return peak < AudioMix.deadLevel ? .noSound : .noWords
    }

    /// `canChoose`: this device lets you pick another mic (the Mac); the iPhone says what to close instead.
    public func message(mic: String, canChoose: Bool = true) -> String? {
        let choose = canChoose ? "Choose another mic with the arrow next to the mic button, or in Settings › Voice."
                               : "Stop the other app's recording, then try again."
        switch self {
        case .speech: return nil
        case .noSound:
            return "No sound came from \(mic). It may be muted, or another app (a stream or a call) is holding it. " + choose
        case .noWords:
            return "Didn't catch any words from \(mic). Try a little closer" + (canChoose ? ", or choose another mic with the arrow next to the mic button." : ".")
        }
    }
}

/// A microphone, by the ID that stays the same when it's unplugged and plugged back in.
public struct MicDevice: Equatable, Hashable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Which mic Broski listens to: the one you chose while it's connected, otherwise the system's.
public enum MicChoice {
    /// The chosen mic, or nil for the system's (nothing chosen, or the chosen one isn't connected).
    public static func resolve(saved: String?, devices: [MicDevice]) -> MicDevice? {
        guard let saved else { return nil }
        return devices.first { $0.uid == saved }
    }

    public static func label(saved: String?, devices: [MicDevice], systemDefault: String?) -> String {
        resolve(saved: saved, devices: devices)?.name ?? systemDefault ?? "the system's mic"
    }
}

/// How fast replies are read aloud.
public enum ReplySpeed: String, CaseIterable, Sendable {
    case slower, normal, faster

    public init(stored: String?) {
        self = stored.flatMap(ReplySpeed.init(rawValue:)) ?? .normal
    }

    /// AVSpeechUtterance's rate (0...1, where 0.5 is the system's normal).
    public var rate: Float {
        switch self {
        case .slower: return 0.46
        case .normal: return 0.52
        case .faster: return 0.58
        }
    }

    public var name: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// A reply as it should sound: markdown marks and link addresses aren't read out.
public enum SpokenText {
    public static func clean(_ text: String) -> String {
        var s = text
        // [the docs](https://…) → the docs; a bare address → "the link".
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"https?://\S+"#, with: "the link", options: .regularExpression)
        // Headings and list markers at the start of a line.
        s = s.replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s+|[-*•]\s+)"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Stopping a reply cancels its task; that's what you asked for, not a failure to show.
public enum Cancellation {
    public static func isStop(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
