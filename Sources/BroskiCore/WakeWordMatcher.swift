import Foundation

/// Finds the wake word in a speech transcript, tolerating the ways a recognizer
/// mishears a made-up word: "Brosky", "Broskie", "bro ski", "Bruski".
public struct WakeWordMatcher {
    /// Squashed wake phrases, e.g. "broski" or "heybroski".
    public let phrases: [String]

    public init(wakeWords: [String]) {
        phrases = wakeWords.map(TextTools.squash).filter { !$0.isEmpty }
    }

    public struct Match {
        public let range: Range<String.Index>
        public let heard: String
    }

    /// First occurrence of any wake phrase, looking at runs of 1–3 words so that
    /// a phrase split by the recognizer ("bro ski") still counts.
    public func firstMatch(in text: String) -> Match? {
        let tokens = TextTools.tokens(in: text)
        for i in tokens.indices {
            for n in 1...3 where i + n <= tokens.count {
                let window = tokens[i..<(i + n)]
                let candidate = window.map { TextTools.squash($0.text) }.joined()
                for phrase in phrases where Self.isClose(candidate, to: phrase) {
                    let range = window.first!.range.lowerBound..<window.last!.range.upperBound
                    return Match(range: range, heard: String(text[range]))
                }
            }
        }
        return nil
    }

    /// Edit-distance check tuned so "brosky" and "broskee" match "broski" but "brisk" does not.
    static func isClose(_ candidate: String, to target: String) -> Bool {
        if candidate == target { return true }
        guard target.count >= 5, abs(candidate.count - target.count) <= 2 else { return false }
        let distance = TextTools.levenshtein(candidate, target)
        if distance <= 1 { return true }
        // Two edits also reach real words ("Brooks"); a mishearing keeps the ending's sound (Broskee, Bruskie, Brewski).
        return distance == 2
            && target.count >= 6
            && candidate.count >= target.count
            && candidate.prefix(2) == target.prefix(2)
            && isVowel(candidate.last) == isVowel(target.last)
    }

    static func isVowel(_ c: Character?) -> Bool {
        c.map { "aeiouy".contains($0) } ?? false
    }
}
