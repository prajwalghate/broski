import Foundation

public enum ItemStatus: String, Codable, CaseIterable {
    case inbox, todo, doing, done

    public var label: String {
        switch self {
        case .inbox: return "Inbox"
        case .todo: return "To do"
        case .doing: return "Doing"
        case .done: return "Done"
        }
    }
}

public enum Priority: String, Codable, CaseIterable, Comparable {
    case low, normal, high, urgent

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 1 }
    public static func < (a: Priority, b: Priority) -> Bool { a.rank < b.rank }
}

/// What you were looking at when the note was taken.
public struct ItemContext: Equatable {
    public var app: String?
    public var window: String?
    public var url: String?
    public var selection: String?

    public init(app: String? = nil, window: String? = nil, url: String? = nil, selection: String? = nil) {
        self.app = app
        self.window = window
        self.url = url
        self.selection = selection
    }

    public var isEmpty: Bool { [app, window, url, selection].allSatisfy { ($0 ?? "").isEmpty } }

    /// "Safari · Stripe Dashboard"
    public var summary: String {
        [app, window].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One note: a markdown file with a small front-matter header.
///
///     ---
///     kind: todo
///     status: todo
///     priority: high
///     tags: api, launch
///     created: 2026-10-16T15:32:00+05:30
///     app: Safari
///     url: https://dashboard.stripe.com/apikeys
///     attachments: attachments/2026-10-16-153200.png
///     ---
///     # Rotate the API keys before launch
///
///     Anything longer goes here, in markdown.
public struct Item: Identifiable, Equatable {
    /// The file name without ".md"; unique within its folder.
    public var id: String
    public var file: URL
    /// nil means the inbox.
    public var project: String?
    public var kind: NoteKind
    public var status: ItemStatus
    public var priority: Priority
    public var tags: [String]
    public var title: String
    public var body: String
    public var created: Date
    public var updated: Date
    public var context: ItemContext
    /// Paths relative to the item's folder, e.g. "attachments/x.png".
    public var attachments: [String]
    /// Front-matter lines Broski doesn't own (another editor's keys, comments), written back exactly as they were.
    public var extraFrontMatter: [String] = []

    public var folder: URL { file.deletingLastPathComponent() }
    public var attachmentURLs: [URL] { attachments.map { folder.appendingPathComponent($0) } }
    public var isOpenTask: Bool { (kind == .todo || kind == .bug) && status != .done }
    public var isDone: Bool { status == .done }
}

/// A draft for a new item, before it has a file.
public struct ItemDraft: Equatable {
    public var project: String?
    public var kind: NoteKind
    public var status: ItemStatus?
    public var priority: Priority
    public var tags: [String]
    public var title: String
    public var body: String
    public var context: ItemContext
    /// Files anywhere on disk; they're copied into the item's attachments folder.
    public var attachments: [URL]

    public init(project: String? = nil, kind: NoteKind = .note, status: ItemStatus? = nil, priority: Priority = .normal,
                tags: [String] = [], title: String, body: String = "", context: ItemContext = ItemContext(), attachments: [URL] = []) {
        self.project = project
        self.kind = kind
        self.status = status
        self.priority = priority
        self.tags = tags
        self.title = title
        self.body = body
        self.context = context
        self.attachments = attachments
    }

    /// Todos and bugs start on the board; notes and ideas start in the inbox column.
    public var initialStatus: ItemStatus {
        status ?? ((kind == .todo || kind == .bug) ? .todo : .inbox)
    }
}

/// The tiny front-matter dialect Broski reads and writes: `key: value` lines between `---` fences.
/// Values that span lines or start with a quote are JSON strings.
public enum FrontMatter {
    public static func split(_ text: String) -> (fields: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([:], normalized) }
        let rest = normalized.dropFirst(4)
        // Empty front matter: checked first, or a "---" rule further down the body would be taken for the closing fence.
        if rest.hasPrefix("---\n") { return ([:], String(rest.dropFirst(4))) }
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return ([:], normalized)
        }
        var fields: [String: String] = [:]
        for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), let data = value.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
                value = decoded
            }
            fields[key] = value
        }
        return (fields, String(rest[end.upperBound...]))
    }

    /// `extra`: raw lines written after the fields, untouched (see `rawEntries`).
    public static func render(_ fields: [(String, String?)], extra: [String] = [], body: String) -> String {
        var out = "---\n"
        for (key, value) in fields {
            guard let value, !value.isEmpty else { continue }
            out += "\(key): \(encode(value))\n"
        }
        for line in extra { out += line + "\n" }
        out += "---\n"
        return out + body
    }

    /// The header as raw entries, in order: each top-level `key:` line with the indented or `- ` lines under it,
    /// and any other line (a comment) on its own. Nothing is decoded, so entries can be written back byte for byte.
    public static func rawEntries(_ text: String) -> [(key: String?, lines: [String])] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return [] }
        let rest = normalized.dropFirst(4)
        // Empty front matter has no entries; don't read on to a "---" rule in the body.
        if rest.hasPrefix("---\n") { return [] }
        guard let end = rest.range(of: "\n---\n") ?? (rest.hasSuffix("\n---") ? rest.range(of: "\n---", options: .backwards) : nil) else {
            return []
        }
        var out: [(key: String?, lines: [String])] = []
        for line in rest[rest.startIndex..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            let continuation = line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- ") || line == "-"
            if continuation, let last = out.indices.last, out[last].key != nil {
                out[last].lines.append(line)
                continue
            }
            if !continuation, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.contains(" ") {
                    out.append((key, [line]))
                    continue
                }
            }
            out.append((nil, [line]))
        }
        return out
    }

    /// A list value in any of the forms editors write: `a, b`, `[a, "b"]`, or `- a` lines under the key.
    public static func listValue(_ entry: (key: String?, lines: [String])?, fallback: String?) -> [String] {
        func unquote(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.count >= 2, let first = t.first, let last = t.last, (first == "\"" && last == "\"") || (first == "'" && last == "'") else { return t }
            return String(t.dropFirst().dropLast())
        }
        if let entry, let head = entry.lines.first, let colon = head.firstIndex(of: ":") {
            let value = head[head.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                return entry.lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("-") }.map { unquote(String($0.dropFirst())) }.filter { !$0.isEmpty }
            }
            if value.hasPrefix("["), value.hasSuffix("]") {
                return value.dropFirst().dropLast().split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
            }
        }
        return (fallback ?? "").split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
    }

    static func encode(_ value: String) -> String {
        let needsQuotes = value.contains("\n") || value.hasPrefix("\"") || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes, let data = try? JSONEncoder().encode(value) else { return value }
        return String(decoding: data, as: UTF8.self)
    }

    public static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
}
