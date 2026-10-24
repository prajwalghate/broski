import Foundation

public struct SavedNote: Equatable {
    public let file: URL
    /// Exact text appended, kept so the save can be undone.
    public let appended: String
    public let mirrorFile: URL?
    public let mirrorAppended: String?
}

/// A deleted note, kept so the delete can be undone.
public struct DeletedNote: Equatable {
    public let file: URL
    public let line: Int
    public let raw: String
}

public enum NotesError: LocalizedError {
    case changedOnDisk
    /// The note was deleted or moved since it was read.
    case gone(String)
    /// The session was wrapped up (on another device, or from the menu) since it was read.
    case sessionEnded(String)

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk: return "That note changed in another app. The list has been refreshed; try again."
        case .gone(let title): return "“\(title)” was deleted or moved, so it wasn't written back."
        case .sessionEnded(let title): return "“\(title)” was already wrapped up, so this wasn't added to it."
        }
    }
}

/// Reads and writes notes as plain markdown files:
///   ~/Broski/projects/<project>.md   one file per project
///   ~/Broski/inbox.md                notes that didn't name a project
public final class NoteStore {
    public let root: URL
    /// Also append to IDEAS.md inside the project's own folder, when it has one.
    public var mirrorToProjectFolder: Bool

    public init(root: URL, mirrorToProjectFolder: Bool = false) {
        self.root = root
        self.mirrorToProjectFolder = mirrorToProjectFolder
    }

    public var projectsDir: URL { root.appendingPathComponent("projects", isDirectory: true) }
    public var inboxFile: URL { root.appendingPathComponent("inbox.md") }
    var captureLog: URL { root.appendingPathComponent(".broski/captures.jsonl") }

    public func file(for destination: Destination) -> URL {
        switch destination {
        case .inbox: return inboxFile
        case .project(let p): return projectsDir.appendingPathComponent(p.name + ".md")
        case .newProject(let name): return projectsDir.appendingPathComponent(name + ".md")
        }
    }

    static func header(for destination: Destination) -> String {
        switch destination {
        case .inbox: return "# Inbox\n\nNotes Broski couldn't match to a project.\n\n"
        default: return "# \(destination.displayName)\n\nCaptured with Broski. Newest at the bottom.\n\n"
        }
    }

    /// "- [ ] 2026-10-14 15:32 · Retry failed orders #bug"
    public static func line(for note: ParsedNote, date: Date) -> String {
        NotesFormat.line(kind: note.kind, body: note.body, date: date)
    }

    // MARK: Capturing

    @discardableResult
    public func save(_ note: ParsedNote, raw: String, date: Date = Date()) throws -> SavedNote {
        let line = Self.line(for: note, date: date) + "\n"
        let file = file(for: note.destination)
        let appended = try append(line, to: file, header: Self.header(for: note.destination))

        var mirrorFile: URL?
        var mirrorAppended: String?
        if mirrorToProjectFolder, case .project(let p) = note.destination, let folder = p.folder {
            let ideas = folder.appendingPathComponent("IDEAS.md")
            mirrorAppended = try append(line, to: ideas, header: "# Ideas\n\nCaptured with Broski.\n\n")
            mirrorFile = ideas
        }

        logCapture(raw: raw, note: note, file: file, date: date)
        return SavedNote(file: file, appended: appended, mirrorFile: mirrorFile, mirrorAppended: mirrorAppended)
    }

    /// Removes a saved note again, but only if it's still the last thing in the file.
    @discardableResult
    public func undo(_ saved: SavedNote) throws -> Bool {
        let removed = try removeSuffix(saved.appended, from: saved.file)
        if let mirror = saved.mirrorFile, let text = saved.mirrorAppended {
            _ = try removeSuffix(text, from: mirror)
        }
        return removed
    }

    // MARK: Reading and editing (the dashboard)

    /// inbox.md first, then every projects/*.md.
    public func noteFiles() -> [URL] {
        let fm = FileManager.default
        let projects = ((try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (fm.fileExists(atPath: inboxFile.path) ? [inboxFile] : []) + projects
    }

    public func entries(in file: URL) -> [NoteEntry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return NotesFormat.parse(text, file: file)
    }

    /// Rewrites one note. Fields left nil keep their current value.
    @discardableResult
    public func update(_ entry: NoteEntry, done: Bool? = nil, body: String? = nil, kind: NoteKind? = nil) throws -> NoteEntry {
        var updated = entry
        if let done { updated.done = done }
        if let body { updated.body = body.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let kind {
            updated.kind = kind
            updated.hasCheckbox = kind == .todo || kind == .bug
            if !updated.hasCheckbox { updated.done = false }
        }
        let line = NotesFormat.line(for: updated)
        var index = 0
        try editLines(of: entry.file) { lines in
            index = try Self.locate(entry, in: lines)
            lines[index] = line
        }
        return NotesFormat.entry(from: line, line: index, file: entry.file) ?? updated
    }

    @discardableResult
    public func delete(_ entry: NoteEntry) throws -> DeletedNote {
        var index = 0
        try editLines(of: entry.file) { lines in
            index = try Self.locate(entry, in: lines)
            lines.remove(at: index)
        }
        return DeletedNote(file: entry.file, line: index, raw: entry.raw)
    }

    /// Puts a deleted note back where it was (or as close as the file now allows).
    public func restore(_ deleted: DeletedNote) throws {
        if !FileManager.default.fileExists(atPath: deleted.file.path) {
            try "".write(to: deleted.file, atomically: true, encoding: .utf8)
        }
        try editLines(of: deleted.file) { lines in
            // A trailing "" is the final newline; keep it last.
            let limit = lines.last == "" ? lines.count - 1 : lines.count
            lines.insert(deleted.raw, at: min(deleted.line, max(limit, 0)))
        }
    }

    /// Moves a note to another project, keeping its date, type, and done state.
    /// It's added to the destination before it's removed from the source, so a failure never loses it.
    public func move(_ entry: NoteEntry, to destination: Destination) throws {
        let target = file(for: destination)
        guard target.standardizedFileURL != entry.file.standardizedFileURL else { return }
        _ = try append(NotesFormat.line(for: entry) + "\n", to: target, header: Self.header(for: destination))
        try delete(entry)
    }

    @discardableResult
    public func add(body: String, kind: NoteKind, to destination: Destination, date: Date = Date()) throws -> SavedNote {
        let note = ParsedNote(destination: destination, kind: kind, body: body)
        return try save(note, raw: body, date: date)
    }

    /// Creates an empty notes file for a project so it shows up before its first note.
    public func createProject(named name: String) throws -> URL {
        let slug = TextTools.slugify(name)
        let url = projectsDir.appendingPathComponent(slug + ".md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
            try Self.header(for: .newProject(slug)).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    private func editLines(of file: URL, _ change: (inout [String]) throws -> Void) throws {
        let text = try String(contentsOf: file, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        try change(&lines)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func locate(_ entry: NoteEntry, in lines: [String]) throws -> Int {
        if entry.line < lines.count, lines[entry.line] == entry.raw { return entry.line }
        if let index = lines.firstIndex(of: entry.raw) { return index }
        throw NotesError.changedOnDisk
    }

    // MARK: Files

    /// Returns the exact text written, including a newline added to separate it from earlier content.
    private func append(_ text: String, to url: URL, header: String) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            try header.write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var toWrite = text
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data("\n".utf8) { toWrite = "\n" + text }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: Data(toWrite.utf8))
        return toWrite
    }

    private func removeSuffix(_ text: String, from url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        let suffix = Data(text.utf8)
        guard data.count >= suffix.count, data.suffix(suffix.count) == suffix else { return false }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(data.count - suffix.count))
        return true
    }

    private struct CaptureRecord: Codable {
        let date: String
        let raw: String
        let destination: String
        let kind: String
        let body: String
        let file: String
    }

    /// Raw transcript next to what was parsed, for improving routing later. Only saved notes are logged.
    private func logCapture(raw: String, note: ParsedNote, file: URL, date: Date) {
        let record = CaptureRecord(
            date: ISO8601DateFormatter().string(from: date), raw: raw,
            destination: note.destination.displayName, kind: note.kind.rawValue, body: note.body, file: file.path
        )
        guard let json = try? JSONEncoder().encode(record) else { return }
        _ = try? append(String(decoding: json, as: UTF8.self) + "\n", to: captureLog, header: "")
    }
}
