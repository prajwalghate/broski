import Foundation

/// Something the brain can find and cite: a note, or one entry of a session.
public struct NoteRef: Hashable, Identifiable {
    /// A note's file name without ".md", or "<session id>#<entry number>".
    public var id: String
    public var project: String?
    public var kind: NoteKind
    public var title: String
    public var body: String
    public var date: Date
    public var open: Bool
    public var file: URL
    /// The tracker this came from (its source id, "acme"), nil for Broski's own notes.
    public var source: String?
    /// Shown on the rules page, so a change of priority has to change the page's fingerprint.
    public var priority: Priority
    /// The entry's number, for one entry of a session. A note's own name can contain "#" ("Issue #42").
    public var entry: Int?

    public init(id: String, project: String?, kind: NoteKind, title: String, body: String, date: Date, open: Bool, file: URL,
                source: String? = nil, priority: Priority = .normal, entry: Int? = nil) {
        self.id = id
        self.project = project
        self.kind = kind
        self.title = title
        self.body = body
        self.date = date
        self.open = open
        self.file = file
        self.source = source
        self.priority = priority
        self.entry = entry
    }

    public init(_ item: Item) {
        self.init(id: item.id, project: item.project, kind: item.kind, title: item.title, body: item.body,
                  date: item.updated, open: item.status != .done, file: item.file, priority: item.priority)
    }

    /// Each session entry becomes its own reference, so an answer can point at the exact observation.
    public static func entries(of session: Session) -> [NoteRef] {
        session.entries.enumerated().compactMap { index, entry in
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return NoteRef(id: "\(session.id)#\(index + 1)", project: session.project, kind: .note,
                           title: "\(session.title): \(first.prefix(90))", body: text, date: entry.time,
                           open: session.isActive, file: session.file, entry: index + 1)
        }
    }

    public var isSessionEntry: Bool { entry != nil }
    public var isTrackerRecord: Bool { source != nil }
}

public struct SearchHit: Equatable {
    public var ref: NoteRef
    public var score: Double
    public var snippet: String
}

/// A small local search index over every note (BM25 for search, TF-IDF cosine for "related" and duplicates).
/// Fast enough to rebuild on every change for thousands of notes; nothing leaves the device.
public struct NotesIndex {
    public private(set) var refs: [NoteRef] = []
    private var terms: [[String: Int]] = []
    private var lengths: [Int] = []
    private var documentFrequency: [String: Int] = [:]
    private var averageLength: Double = 1

    public init(_ refs: [NoteRef]) {
        self.refs = refs
        for ref in refs {
            let tokens = Self.tokens(ref.title + " " + ref.title + " " + ref.body)
            var counts: [String: Int] = [:]
            for token in tokens { counts[token, default: 0] += 1 }
            terms.append(counts)
            lengths.append(tokens.count)
            for token in counts.keys { documentFrequency[token, default: 0] += 1 }
        }
        averageLength = max(1, Double(lengths.reduce(0, +)) / Double(max(refs.count, 1)))
    }

    public init(items: [Item], sessions: [Session] = []) {
        self.init(items.map(NoteRef.init) + sessions.flatMap(NoteRef.entries))
    }

    public func ref(id: String) -> NoteRef? { refs.first { $0.id == id } }

    /// Best matches for a question or keywords.
    public func search(_ query: String, project: String? = nil, limit: Int = 8) -> [SearchHit] {
        let queryTerms = Array(Set(Self.tokens(query)))
        guard !queryTerms.isEmpty else { return [] }
        let n = Double(refs.count)
        var scored: [(Int, Double)] = []
        for (i, ref) in refs.enumerated() where project == nil || ref.project == project {
            var score = 0.0
            for term in queryTerms {
                guard let tf = terms[i][term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let k1 = 1.4, b = 0.75
                let norm = Double(tf) * (k1 + 1) / (Double(tf) + k1 * (1 - b + b * Double(lengths[i]) / averageLength))
                score += idf * norm
            }
            if score > 0 {
                // Open items and recent notes come first when scores are close.
                if ref.open { score *= 1.08 }
                let days = -ref.date.timeIntervalSinceNow / 86_400
                score *= 1 + 0.15 * exp(-days / 30)
                scored.append((i, score))
            }
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { i, score in
            SearchHit(ref: refs[i], score: score, snippet: Self.snippet(refs[i], for: queryTerms))
        }
    }

    /// Notes about the same thing as `text`, most similar first. `threshold` is cosine similarity (0…1).
    /// `include` filters before `limit`, so a close match that's filtered out doesn't take a slot.
    public func related(to text: String, project: String? = nil, excluding: String? = nil,
                        threshold: Double = 0.18, limit: Int = 3, where include: (NoteRef) -> Bool = { _ in true }) -> [SearchHit] {
        let query = vector(Self.tokens(text))
        guard !query.isEmpty else { return [] }
        var scored: [(Int, Double)] = []
        for (i, ref) in refs.enumerated() where ref.id != excluding && (project == nil || ref.project == project) && include(ref) {
            let similarity = Self.cosine(query, vector(counts: terms[i]))
            if similarity >= threshold { scored.append((i, similarity)) }
        }
        let queryTerms = Array(query.keys)
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { i, score in
            SearchHit(ref: refs[i], score: score, snippet: Self.snippet(refs[i], for: queryTerms))
        }
    }

    /// An open note that says nearly the same thing, if there is one: offered as "add to it instead".
    public func duplicate(of text: String, project: String? = nil) -> SearchHit? {
        guard Self.tokens(text).count >= 3 else { return nil }
        // Only Broski's own open notes: "add to it" can't target a session entry or a tracker record.
        return related(to: text, project: project, threshold: 0.55, limit: 1,
                       where: { !$0.isSessionEntry && !$0.isTrackerRecord && $0.open }).first
    }

    // MARK: Vectors

    private func vector(_ tokens: [String]) -> [String: Double] {
        var counts: [String: Int] = [:]
        for token in tokens { counts[token, default: 0] += 1 }
        return vector(counts: counts)
    }

    private func vector(counts: [String: Int]) -> [String: Double] {
        let n = Double(max(refs.count, 1))
        var out: [String: Double] = [:]
        for (term, tf) in counts {
            let idf = log((n + 1) / (Double(documentFrequency[term] ?? 0) + 1)) + 1
            out[term] = (1 + log(Double(tf))) * idf
        }
        return out
    }

    private static func cosine(_ a: [String: Double], _ b: [String: Double]) -> Double {
        var dot = 0.0
        for (term, weight) in a { if let other = b[term] { dot += weight * other } }
        let na = sqrt(a.values.reduce(0) { $0 + $1 * $1 }), nb = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
        return na > 0 && nb > 0 ? dot / (na * nb) : 0
    }

    // MARK: Text

    static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "are", "was", "but", "not", "you", "your", "have", "has", "had",
        "its", "it's", "can", "will", "would", "should", "could", "from", "into", "they", "them", "then", "than",
        "there", "here", "what", "when", "where", "which", "who", "why", "how", "all", "any", "our", "out", "about",
        "also", "just", "like", "need", "needs", "want", "some", "more", "very", "too", "add", "note", "project",
        "is", "in", "on", "of", "to", "a", "an", "be", "we", "i", "my", "me", "it", "or", "if", "so", "do", "at", "as",
        "by", "up", "no", "yes", "did", "does", "get", "got", "one", "now", "still", "again", "only", "even",
    ]

    /// Lowercased words without stopwords, lightly stemmed so "bugs"/"bug", "crashing"/"crash" and "issue"/"issues" match.
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
            .map(stem)
    }

    /// A light Porter step 1 (plus a final "e"), so every form of a word lands on the same stem:
    /// issue/issues/issued -> "issu", cache/caching -> "cach", ship/shipped -> "ship", query/queries -> "query".
    static func stem(_ word: String) -> String {
        var w = word
        // Plurals.
        if w.hasSuffix("sses") {
            w.removeLast(2)
        } else if w.count > 4, w.hasSuffix("ies") {
            w.removeLast(3)
            w += "y"
        } else if w.count >= 4, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") {
            w.removeLast()
        }
        // Verb endings; "shipp" and "runn" lose the doubled consonant, "fall" and "miss" keep theirs.
        var trimmed = false
        if w.count > 6, w.hasSuffix("ing") {
            w.removeLast(3)
            trimmed = true
        } else if w.count > 5, w.hasSuffix("ed") {
            w.removeLast(2)
            trimmed = true
        }
        if trimmed, let last = w.last, w.dropLast().last == last, !"aeioulsz".contains(last) { w.removeLast() }
        // The base word keeps its "e" while the other forms lost it ("update" vs "updat-ed").
        if w.count > 3, w.hasSuffix("e") { w.removeLast() }
        return w
    }

    private static func snippet(_ ref: NoteRef, for queryTerms: [String]) -> String {
        let body = ref.body.replacingOccurrences(of: "\n", with: " ")
        guard !body.isEmpty else { return "" }
        let words = body.split(separator: " ")
        let hit = words.firstIndex { queryTerms.contains(stem($0.lowercased().trimmingCharacters(in: .punctuationCharacters))) } ?? 0
        let start = max(0, hit - 8)
        let piece = words[start..<min(words.count, start + 26)].joined(separator: " ")
        return (start > 0 ? "…" : "") + piece + (start + 26 < words.count ? "…" : "")
    }
}
