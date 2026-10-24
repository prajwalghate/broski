import Foundation

/// Tidies raw speech-to-text for a note: models that can't be primed with your project names (Bark 3.0) or that
/// write short phrases in lowercase get the same result Whisper's prompt gives.
public enum TranscriptPolish {
    /// Sounds that carry no words.
    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "hmm", "mm", "mmm", "ah"]

    /// Drops fillers, snaps near-misses of `vocabulary` (project names, known terms) to their spelling, capitalizes
    /// sentences and "I", and ends with a full stop.
    public static func apply(_ text: String, vocabulary: [String] = []) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        words = words.filter { word in
            !fillers.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters))
        }
        words = snap(words, to: vocabulary)
        var out = words.joined(separator: " ")
        out = out.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\bi(?=\b|'(?:m|ve|ll|d)\b)"#, with: "I", options: .regularExpression)
        out = capitalizeSentences(out)
        if let last = out.last, last.isLetter || last.isNumber { out += "." }
        return out
    }

    /// One to three adjacent words whose letters match a vocabulary term become that term, exactly (number words
    /// count as digits) or one letter off for a long, distinctive term: "strato" → "strado", "chain link" → "Chainlink",
    /// "hip three observatory" → "hip3-observatory".
    static func snap(_ words: [String], to vocabulary: [String]) -> [String] {
        let terms = vocabulary.compactMap { term -> (key: String, spelling: String)? in
            let key = TextTools.matchKey(term)
            return key.count >= 3 ? (key, term) : nil
        }
        guard !terms.isEmpty else { return words }
        func core(_ w: String) -> (lead: String, body: String, trail: String) {
            let body = w.trimmingCharacters(in: .punctuationCharacters)
            guard !body.isEmpty, let range = w.range(of: body) else { return ("", w, "") }
            return (String(w[..<range.lowerBound]), body, String(w[range.upperBound...]))
        }
        func match(_ parts: [String]) -> String? {
            let key = TextTools.matchKey(parts.joined(separator: " "))
            guard key.count >= 3 else { return nil }
            // An everyday word that's also a project's name ("lab", "tamer", "one") stays as it was said.
            if parts.count == 1, ProjectCatalog.wordNames.contains(TextTools.squash(parts[0])) || ProjectCatalog.commonWords.contains(TextTools.squash(parts[0])) {
                return nil
            }
            for term in terms where key == term.key { return term.spelling }
            guard parts.count == 1, key.count >= 6 else { return nil }
            for term in terms where term.key.count >= 6 && key.first == term.key.first && TextTools.levenshtein(key, term.key) <= 1 {
                return term.spelling
            }
            return nil
        }
        var out: [String] = []
        var i = 0
        while i < words.count {
            var replaced = false
            // Longest run first; only words with no punctuation between them join.
            for n in stride(from: min(3, words.count - i), through: 1, by: -1) {
                let run = words[i..<(i + n)].map(core)
                guard run.dropLast().allSatisfy({ $0.trail.isEmpty }), run.dropFirst().allSatisfy({ $0.lead.isEmpty }) else { continue }
                if let term = match(run.map(\.body)) {
                    out.append(run.first!.lead + term + run.last!.trail)
                    i += n
                    replaced = true
                    break
                }
            }
            if !replaced {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    static func capitalizeSentences(_ s: String) -> String {
        var out = ""
        var upNext = true
        for ch in s {
            if upNext, ch.isLetter {
                out += ch.uppercased()
                upNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { upNext = true } else if !ch.isWhitespace && !ch.isPunctuation { upNext = false }
            }
        }
        return out
    }
}
