import Foundation

/// One bullet in a notes file. Broski writes "- [ ] 2026-10-14 15:32 · Fix login #bug",
/// and bullets typed by hand in another editor ("- buy milk", "- [x] call Sam") read the same way.
public struct NoteEntry: Equatable, Identifiable {
    public let file: URL
    /// Line number when the file was read; edits use it to find the note again.
    public let line: Int
    /// The line exactly as it was in the file.
    public let raw: String
    public var done: Bool
    public var hasCheckbox: Bool
    public var date: Date?
    public var body: String
    public var kind: NoteKind

    public var id: String { "\(file.path)#\(line)#\(raw)" }
    public var isOpenTask: Bool { hasCheckbox && !done }
}

public enum NotesFormat {
    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let bullet = try! NSRegularExpression(
        pattern: #"^\s*[-*+]\s+(?:\[([ xX])\]\s+)?(?:(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s+·\s+)?(.+?)\s*$"#
    )
    static let tag = try! NSRegularExpression(pattern: #"\s+#(idea|bug|todo|note)\s*$"#, options: [.caseInsensitive])

    public static func parse(_ text: String, file: URL) -> [NoteEntry] {
        text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            entry(from: line, line: index, file: file)
        }
    }

    public static func entry(from line: String, line index: Int, file: URL) -> NoteEntry? {
        let ns = line as NSString
        guard let m = bullet.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
        }
        let box = group(1)
        var body = group(3) ?? ""
        var tagged: NoteKind?
        let bodyNS = body as NSString
        if let t = tag.firstMatch(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
            tagged = NoteKind(rawValue: bodyNS.substring(with: t.range(at: 1)).lowercased())
            body = bodyNS.replacingCharacters(in: t.range, with: "")
        }
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return NoteEntry(
            file: file, line: index, raw: line,
            done: box?.lowercased() == "x", hasCheckbox: box != nil,
            date: group(2).flatMap { timestamp.date(from: $0) },
            body: body,
            kind: tagged ?? (box != nil ? .todo : .note)
        )
    }

    /// The line Broski writes: todos and bugs get a checkbox, ideas and bugs a tag.
    public static func line(kind: NoteKind, body: String, date: Date?, done: Bool = false) -> String {
        let text = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let stamp = date.map { timestamp.string(from: $0) + " · " } ?? ""
        let box = "[\(done ? "x" : " ")] "
        switch kind {
        case .note: return "- \(stamp)\(text)"
        case .idea: return "- \(stamp)\(text) #idea"
        case .todo: return "- \(box)\(stamp)\(text)"
        case .bug: return "- \(box)\(stamp)\(text) #bug"
        }
    }

    public static func line(for entry: NoteEntry) -> String {
        line(kind: entry.kind, body: entry.body, date: entry.date, done: entry.done)
    }
}
