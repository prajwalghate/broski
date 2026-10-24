import Foundation

/// Something from your notes, decisions or past conversations that bears on what you just said.
public struct RecallHit: Equatable, Sendable {
    public var id: String
    /// How it's shown under Broski's reply: "You said · Oct 20", "Decision · Oct 18", "Todo · Oct 21 · Write the guard".
    public var label: String
    public var text: String

    public init(id: String, label: String, text: String) {
        self.id = id
        self.label = label
        self.text = text
    }
}

/// Brings back what you said before: past conversation turns and decisions become searchable alongside your notes,
/// the best matches go to the model numbered, and the numbers it cites become the reply's sources.
public enum Recall {
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// Your turns and Broski's, as searchable refs ("turn:<id>").
    public static func refs(turns: [Turn], root: URL) -> [NoteRef] {
        turns.filter { $0.speaker == .you || $0.speaker == .broski }.map { turn in
            NoteRef(id: "turn:\(turn.id)", project: turn.project, kind: .note, title: String(turn.text.prefix(80)), body: turn.text,
                    date: turn.at, open: false, file: root.appendingPathComponent("conversations", isDirectory: true),
                    source: turn.speaker == .you ? "you" : "broski")
        }
    }

    /// Decisions, as searchable refs ("decision:<id>").
    public static func refs(decisions: [Decision], root: URL) -> [NoteRef] {
        decisions.map { decision in
            NoteRef(id: "decision:\(decision.id)", project: decision.project, kind: .note, title: decision.text,
                    body: [decision.text, decision.body ?? ""].joined(separator: "\n"), date: decision.at, open: true,
                    file: DecisionLog.folder(root: root, project: decision.project), source: "decision")
        }
    }

    /// The best matches for `query`, leaving out what's already in the conversation and projects that must stay hidden.
    public static func find(_ query: String, index: NotesIndex, excluding: Set<String>, hidden: Set<String>, limit: Int = 5) -> [RecallHit] {
        index.search(query, limit: limit * 3)
            .filter { hit in !excluding.contains(hit.ref.id) && !(hit.ref.project.map(hidden.contains) ?? false) && hit.score > 0 }
            .prefix(limit)
            .map { hit in RecallHit(id: hit.ref.id, label: label(hit.ref), text: String(hit.ref.body.prefix(500))) }
    }

    /// "Oct 20".
    public static func dayString(_ date: Date) -> String { day.string(from: date) }

    static func label(_ ref: NoteRef) -> String {
        let date = day.string(from: ref.date)
        switch ref.source {
        case "you": return "You said · \(date)"
        case "broski": return "Broski said · \(date)"
        case "decision": return "Decision · \(date)"
        case "web": return "Page · \(date) · \(ref.title.prefix(60))"
        default: return "\(ref.kind.rawValue.capitalized) · \(date) · \(ref.title.prefix(60))"
        }
    }

    /// The reply without its [n] markers, and the labels of the hits it cited, in the order first cited.
    public static func cited(in text: String, hits: [RecallHit]) -> (text: String, sources: [String]) {
        guard !hits.isEmpty, let regex = try? NSRegularExpression(pattern: #"\s*\[(\d+)\]"#) else { return (text, []) }
        var out = text
        var order: [Int] = []
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text), let number = Int(text[range]), (1...hits.count).contains(number) else { continue }
            if !order.contains(number) { order.append(number) }
        }
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: out), let number = Int(out[numberRange]),
                  (1...hits.count).contains(number),
                  let whole = Range(match.range, in: out) else { continue }
            out.removeSubrange(whole)
        }
        return (out, order.map { hits[$0 - 1].label })
    }
}

// MARK: Decisions

/// A decision with its date: kept per device per project (`projects/strado/decisions.mac.jsonl`). A newer decision
/// can replace an older one, so Broski never mixes old and new.
public struct Decision: Codable, Equatable, Identifiable, Sendable {
    public var v: Int
    public var id: String
    public var at: Date
    public var device: String
    public var project: String?
    public var text: String
    public var body: String?
    /// The decision this one replaces.
    public var replaces: String?
    /// The conversation turn it came from.
    public var turn: String?

    public init(id: String = UUID().uuidString, at: Date = Date(), device: String, project: String?, text: String,
                body: String? = nil, replaces: String? = nil, turn: String? = nil) {
        self.v = 1
        self.id = id
        self.at = at
        self.device = device
        self.project = project
        self.text = text
        self.body = body
        self.replaces = replaces
        self.turn = turn
    }
}

public enum DecisionLog {
    static func folder(root: URL, project: String?) -> URL {
        project.map { root.appendingPathComponent("projects", isDirectory: true).appendingPathComponent($0, isDirectory: true) }
            ?? root.appendingPathComponent("inbox", isDirectory: true)
    }

    public static func record(_ decision: Decision, root: URL) throws {
        try JSONLines.append(decision, to: folder(root: root, project: decision.project).appendingPathComponent("decisions.\(decision.device).jsonl"))
    }

    /// Every device's decisions for a project, oldest first.
    public static func all(root: URL, project: String?) -> [Decision] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(root: root, project: project), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("decisions.") && $0.pathExtension == "jsonl" }
            .flatMap { JSONLines.read(Decision.self, from: $0) }
            .sorted { $0.at < $1.at }
    }

    /// The decisions still standing: none that a later one replaced.
    public static func current(root: URL, project: String?) -> [Decision] {
        let decisions = all(root: root, project: project)
        let replaced = Set(decisions.compactMap(\.replaces))
        return decisions.filter { !replaced.contains($0.id) }
    }
}
