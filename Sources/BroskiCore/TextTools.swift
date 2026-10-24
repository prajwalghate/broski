import Foundation

/// Small string helpers shared by the wake-word matcher, the parser, and the store.
public enum TextTools {
    static let posix = Locale(identifier: "en_US_POSIX")

    /// Lowercase, strip accents, keep only letters and digits: "Hip-3 Observatory!" -> "hip3observatory".
    public static func squash(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: posix)
        var out = String.UnicodeScalarView()
        for u in folded.unicodeScalars where CharacterSet.alphanumerics.contains(u) {
            out.append(u)
        }
        return String(out)
    }

    /// Key used to compare project names. Number words become digits first,
    /// so a spoken "hip three observatory" matches a folder named "hip3-observatory".
    public static func matchKey(_ s: String) -> String {
        squash(numberWordsToDigits(s))
    }

    static let numberWords = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
    ]
    static let numberRegex = try! NSRegularExpression(
        pattern: #"\b(zero|one|two|three|four|five|six|seven|eight|nine|ten)\b"#,
        options: [.caseInsensitive]
    )

    public static func numberWordsToDigits(_ s: String) -> String {
        var result = s
        let matches = numberRegex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        // Walk backwards so earlier ranges stay valid while we replace.
        for m in matches.reversed() {
            guard let r = Range(m.range, in: result) else { continue }
            if let digit = numberWords[result[r].lowercased()] {
                result.replaceSubrange(r, with: digit)
            }
        }
        return result
    }

    /// Filesystem-safe name: "Side Quest!" -> "side-quest".
    public static func slugify(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: posix)
        var out = ""
        var lastWasDash = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !out.isEmpty && !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : String(out.prefix(60))
    }

    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    public struct Token {
        public let text: String
        public let range: Range<String.Index>
    }

    /// Word tokens with their ranges in the original string.
    public static func tokens(in s: String) -> [Token] {
        var out: [Token] = []
        s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, _ in
            if let sub { out.append(Token(text: sub, range: range)) }
        }
        return out
    }

    public static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    static let edgePunctuation = CharacterSet(charactersIn: " \t\n,:;.-–—")

    /// Trims whitespace plus separator punctuation that dictation leaves at the edges.
    public static func trimSeparators(_ s: String) -> String {
        s.trimmingCharacters(in: edgePunctuation)
    }

    /// Like `trimSeparators` but keeps trailing punctuation, so a note keeps its final period.
    public static func trimLeadingSeparators(_ s: String) -> String {
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].unicodeScalars.allSatisfy({ edgePunctuation.contains($0) }) {
            idx = s.index(after: idx)
        }
        return String(s[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
