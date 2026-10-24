import Foundation

public enum SessionKind: String, Codable, CaseIterable {
    case qa, research, meeting, review, general

    public var label: String {
        switch self {
        case .qa: return "QA session"
        case .research: return "Research"
        case .meeting: return "Meeting"
        case .review: return "Review"
        case .general: return "Session"
        }
    }
}

/// One thing captured during a session: what you said or typed, plus any screenshots.
public struct SessionEntry: Equatable, Identifiable {
    public var time: Date
    public var text: String
    /// Paths relative to the session folder, e.g. "shots/153210.png".
    public var attachments: [String]
    public var context: ItemContext

    public var id: String { "\(time.timeIntervalSince1970)-\(text.hashValue)" }

    public init(time: Date, text: String, attachments: [String] = [], context: ItemContext = ItemContext()) {
        self.time = time
        self.text = text
        self.attachments = attachments
        self.context = context
    }
}

/// A run of related captures, like a QA pass over an app, that ends in a report.
/// Stored as a folder: session.md (entries), shots/ (screenshots), report.md (once written).
public struct Session: Identifiable, Equatable {
    public var id: String
    public var folder: URL
    public var project: String?
    public var kind: SessionKind
    public var title: String
    public var started: Date
    public var ended: Date?
    public var entries: [SessionEntry]

    public var file: URL { folder.appendingPathComponent("session.md") }
    public var reportFile: URL { folder.appendingPathComponent("report.md") }
    public var hasReport: Bool { FileManager.default.fileExists(atPath: reportFile.path) }
    public var isActive: Bool { ended == nil }
    public var screenshotCount: Int { entries.reduce(0) { $0 + $1.attachments.count } }

    static let entryStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public func render() -> String {
        var body = "# \(title)\n\n"
        for entry in entries {
            body += "### \(Self.entryStamp.string(from: entry.time))\n"
            if !entry.text.isEmpty { body += entry.text + "\n" }
            for path in entry.attachments { body += "![screenshot](\(path))\n" }
            // One labeled comment per field, so a missing app or a " | " in a title can't shift the others.
            for (label, value) in [("app", entry.context.app), ("window", entry.context.window), ("url", entry.context.url)] {
                let safe = Self.commentSafe(value ?? "")
                if !safe.isEmpty { body += "<!-- \(label): \(safe) -->\n" }
            }
            body += "\n"
        }
        return FrontMatter.render([
            ("kind", kind.rawValue),
            ("project", project),
            ("started", FrontMatter.isoFormatter.string(from: started)),
            ("ended", ended.map { FrontMatter.isoFormatter.string(from: $0) }),
        ], body: body)
    }

    /// One line that can't close the HTML comment early.
    static func commentSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "-->", with: "-- >").trimmingCharacters(in: .whitespaces)
    }

    /// A labeled context comment, `<!-- window: … -->`.
    static func contextField(_ line: String) -> (label: String, value: String)? {
        guard line.hasSuffix("-->") else { return nil }
        for label in ["app", "window", "url"] where line.hasPrefix("<!-- \(label): ") {
            let value = line.dropFirst("<!-- \(label): ".count).dropLast(3).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : (label: label, value: value)
        }
        return nil
    }

    public static func parse(_ text: String, folder: URL) -> Session {
        let (fields, body) = FrontMatter.split(text)
        var title = folder.lastPathComponent
        var entries: [SessionEntry] = []
        var current: SessionEntry?
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("# "), entries.isEmpty, current == nil {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("### "), let time = entryStamp.date(from: String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)) {
                if let current { entries.append(current) }
                current = SessionEntry(time: time, text: "")
            } else if var entry = current {
                if line.hasPrefix("!["), let open = line.firstIndex(of: "("), line.hasSuffix(")") {
                    entry.attachments.append(String(line[line.index(after: open)..<line.index(before: line.endIndex)]))
                } else if let field = Self.contextField(line) {
                    switch field.label {
                    case "app": entry.context.app = field.value
                    case "window": entry.context.window = field.value
                    default: entry.context.url = field.value
                    }
                } else if line.hasPrefix("<!-- context:"), line.hasSuffix("-->") {
                    // Older files: "app | window | url", unlabeled. The url is the last part when there is one.
                    var parts = line.dropFirst(13).dropLast(3).components(separatedBy: " | ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if let last = parts.last, last.hasPrefix("http://") || last.hasPrefix("https://") {
                        entry.context.url = last
                        parts.removeLast()
                    }
                    entry.context.app = parts.first
                    if parts.count > 1 { entry.context.window = parts.dropFirst().joined(separator: " | ") }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    entry.text += (entry.text.isEmpty ? "" : "\n") + line
                }
                current = entry
            }
        }
        if let current { entries.append(current) }
        let started = fields["started"].flatMap { FrontMatter.isoFormatter.date(from: $0) }
            ?? (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return Session(
            id: folder.lastPathComponent, folder: folder,
            project: fields["project"].flatMap { $0.isEmpty ? nil : $0 },
            kind: SessionKind(rawValue: fields["kind"] ?? "") ?? .general,
            title: title, started: started,
            ended: fields["ended"].flatMap { FrontMatter.isoFormatter.date(from: $0) },
            entries: entries
        )
    }
}
