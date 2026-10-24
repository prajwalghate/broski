import Foundation

/// Reads and writes Broski's notes folder:
///
///     ~/Broski/
///       inbox/                 notes that don't belong to a project
///         2026-10-16-1532-buy-a-better-mic.md
///         attachments/
///       projects/strado/       one folder per project
///         2026-10-16-1530-rotate-the-api-keys.md
///         attachments/
///         sessions/2026-10-16-1540-qa-login-flow/
///           session.md  shots/  report.md
///       .broski/trash/         deleted notes, kept until you empty it
public final class ItemStore {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
    }

    public var inboxDir: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var projectsDir: URL { root.appendingPathComponent("projects", isDirectory: true) }
    public var trashDir: URL { root.appendingPathComponent(".broski/trash", isDirectory: true) }

    public func folder(for project: String?) -> URL {
        guard let project, !project.isEmpty else { return inboxDir }
        return projectsDir.appendingPathComponent(project, isDirectory: true)
    }

    /// Project folders that exist, sorted by name.
    public func projectNames() -> [String] {
        ((try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Items

    public func items(in project: String?) -> [Item] {
        let dir = folder(for: project)
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != ProjectPage.fileName }
        return files.compactMap { Self.read($0, project: project) }.sorted { $0.created > $1.created }
    }

    public func allItems() -> [Item] {
        ([nil] + projectNames().map(Optional.some)).flatMap { items(in: $0) }
    }

    /// The front-matter keys Broski writes. Everything else in a note's header is kept as it was.
    static let ownKeys: Set<String> = ["kind", "status", "priority", "tags", "created", "updated", "app", "window", "url", "selection", "attachments"]

    public static func read(_ file: URL, project: String?) -> Item? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let (f, content) = FrontMatter.split(text)
        let entries = FrontMatter.rawEntries(text)
        func entry(_ key: String) -> (key: String?, lines: [String])? { entries.first { $0.key == key } }
        var main = content
        var attachments = FrontMatter.listValue(entry("attachments"), fallback: f["attachments"])
        var trailer = ""
        // The last marker on a line of its own, so a body that quotes it isn't cut short.
        // render() only writes the block when there are attachments, so with none listed it's quoted text.
        if !attachments.isEmpty,
           let marker = main.range(of: "\n<!-- attachments -->", options: .backwards),
           main[marker.upperBound...].first?.isNewline ?? true {
            // Text or images added below the block in another editor are kept, or the next save would drop them.
            var kept: [String] = []
            for line in main[marker.upperBound...].components(separatedBy: "\n") {
                if let path = imagePath(line) {
                    if !attachments.contains(path) { attachments.append(path) }
                } else {
                    kept.append(line)
                }
            }
            trailer = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            main = String(main[..<marker.lowerBound])
        }
        var lines = main.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        let titleLine = lines.isEmpty ? "" : lines.removeFirst()
        let title = titleLine.hasPrefix("# ") ? String(titleLine.dropFirst(2)) : titleLine
        var body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // render() writes it back above the attachments, so it appears once and stays put after that.
        if !trailer.isEmpty { body += (body.isEmpty ? "" : "\n\n") + trailer }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let created = f["created"].flatMap { FrontMatter.isoFormatter.date(from: $0) } ?? modified
        return Item(
            id: file.deletingPathExtension().lastPathComponent, file: file, project: project,
            kind: NoteKind(rawValue: f["kind"] ?? "") ?? .note,
            status: ItemStatus(rawValue: f["status"] ?? "") ?? .inbox,
            priority: Priority(rawValue: f["priority"] ?? "") ?? .normal,
            tags: FrontMatter.listValue(entry("tags"), fallback: f["tags"]),
            title: title.trimmingCharacters(in: .whitespaces),
            body: body,
            created: created,
            updated: f["updated"].flatMap { FrontMatter.isoFormatter.date(from: $0) } ?? created,
            context: ItemContext(app: f["app"], window: f["window"], url: f["url"], selection: f["selection"]),
            attachments: attachments,
            extraFrontMatter: entries.filter { $0.key.map { !ownKeys.contains($0) } ?? true }.flatMap(\.lines)
        )
    }

    /// The path in a `![](attachments/x.png)` line, when it points at a file in the note's own attachments folder.
    /// Any other image (remote, absolute, `../`, another folder) may belong to something else, and
    /// delete/move would carry it off, so it stays as body text.
    static func imagePath(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let close = trimmed.range(of: "](") else { return nil }
        var path = String(trimmed[close.upperBound..<trimmed.index(before: trimmed.endIndex)]).trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("./") { path.removeFirst(2) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "attachments", !parts[1].isEmpty, parts[1] != ".", parts[1] != "..",
              !path.contains(","), !trimmed[..<close.lowerBound].contains("]") else { return nil }
        return path
    }

    static func render(_ item: Item) -> String {
        let iso = FrontMatter.isoFormatter
        var body = "# \(item.title.replacingOccurrences(of: "\n", with: " "))\n"
        if !item.body.isEmpty { body += "\n\(item.body)\n" }
        if !item.attachments.isEmpty {
            body += "\n<!-- attachments -->\n" + item.attachments.map { "![](\($0))" }.joined(separator: "\n") + "\n"
        }
        return FrontMatter.render([
            ("kind", item.kind.rawValue),
            ("status", item.status.rawValue),
            ("priority", item.priority == .normal ? nil : item.priority.rawValue),
            ("tags", item.tags.joined(separator: ", ")),
            ("created", iso.string(from: item.created)),
            ("updated", iso.string(from: item.updated)),
            ("app", item.context.app),
            ("window", item.context.window),
            ("url", item.context.url),
            ("selection", item.context.selection),
            ("attachments", item.attachments.joined(separator: ", ")),
        ], extra: item.extraFrontMatter, body: body)
    }

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()

    @discardableResult
    public func create(_ draft: ItemDraft, date: Date = Date()) throws -> Item {
        let dir = folder(for: draft.project)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = String(TextTools.slugify(draft.title).prefix(48))
        let file = uniqueURL(in: dir, base: "\(Self.fileStamp.string(from: date))-\(slug)", ext: "md")
        var item = Item(
            id: file.deletingPathExtension().lastPathComponent, file: file, project: draft.project,
            kind: draft.kind, status: draft.initialStatus, priority: draft.priority, tags: draft.tags,
            title: draft.title, body: draft.body, created: date, updated: date,
            context: draft.context, attachments: []
        )
        // A screenshot that's gone (a purged temp file) is skipped, so it can't cost the note itself.
        item.attachments = try draft.attachments.filter { fm.fileExists(atPath: $0.path) }
            .map { try copyAttachment($0, into: dir, subfolder: "attachments", date: date) }
        try Self.render(item).write(to: file, atomically: true, encoding: .utf8)
        return item
    }

    /// Writes an edited item back, bumping its updated time.
    @discardableResult
    public func save(_ item: Item, date: Date = Date()) throws -> Item {
        // A stale copy (an undo, an open inspector, the phone) must not bring back a deleted note or write a moved
        // one at its old path.
        guard fm.fileExists(atPath: item.file.path) else { throw NotesError.gone(item.title) }
        var saved = item
        saved.updated = date
        try Self.render(saved).write(to: item.file, atomically: true, encoding: .utf8)
        return saved
    }

    /// Changes a note as it is on disk now, not as an older copy had it, so the other device's edits survive
    /// (a status change on the phone, "Add more" on the Mac).
    @discardableResult
    public func update(_ item: Item, date: Date = Date(), _ change: (inout Item) -> Void) throws -> Item {
        guard var current = Self.read(item.file, project: item.project) else { throw NotesError.gone(item.title) }
        change(&current)
        return try save(current, date: date)
    }

    /// Adds files to an existing item.
    @discardableResult
    public func attach(_ files: [URL], to item: Item) throws -> Item {
        guard fm.fileExists(atPath: item.file.path) else { throw NotesError.gone(item.title) }
        var updated = item
        for file in files where fm.fileExists(atPath: file.path) {
            updated.attachments.append(try copyAttachment(file, into: item.folder, subfolder: "attachments", date: Date()))
        }
        return try save(updated)
    }

    /// Carries on an existing note: appends what you added, under the time you added it.
    @discardableResult
    public func addMore(to item: Item, text: String, files: [URL], date: Date = Date()) throws -> Item {
        guard fm.fileExists(atPath: item.file.path) else { throw NotesError.gone(item.title) }
        var updated = item
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !addition.isEmpty {
            let stamp = "_Added \(Self.addedStamp.string(from: date))_"
            let body = updated.body.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.body = (body.isEmpty ? "" : body + "\n\n") + stamp + "\n\n" + addition
        }
        for file in files where fm.fileExists(atPath: file.path) {
            updated.attachments.append(try copyAttachment(file, into: item.folder, subfolder: "attachments", date: date))
        }
        return try save(updated, date: date)
    }

    static let addedStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    /// Moves the note (and its attachments) to the trash. Returns where it went, for undo.
    @discardableResult
    public func delete(_ item: Item) throws -> URL {
        let bin = trashDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for url in item.attachmentURLs where fm.fileExists(atPath: url.path) {
            try fm.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
        let trashed = bin.appendingPathComponent(item.file.lastPathComponent)
        try fm.moveItem(at: item.file, to: trashed)
        try item.file.path.write(to: bin.appendingPathComponent(".origin"), atomically: true, encoding: .utf8)
        return trashed
    }

    /// Puts a trashed note back where it came from.
    public func restore(_ trashed: URL) throws {
        let bin = trashed.deletingLastPathComponent()
        let origin = URL(fileURLWithPath: try String(contentsOf: bin.appendingPathComponent(".origin"), encoding: .utf8))
        let folder = origin.deletingLastPathComponent()
        try fm.createDirectory(at: folder.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        var stranded = false
        for url in (try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        where url.lastPathComponent != trashed.lastPathComponent {
            do {
                try fm.moveItem(at: url, to: folder.appendingPathComponent("attachments").appendingPathComponent(url.lastPathComponent))
            } catch {
                stranded = true
            }
        }
        try fm.moveItem(at: trashed, to: origin)
        // A file that couldn't go back (name taken) stays in the bin instead of being deleted with it.
        if !stranded { try? fm.removeItem(at: bin) }
    }

    /// Moves a note and its attachments to another project (nil = inbox).
    @discardableResult
    public func move(_ item: Item, to project: String?) throws -> Item {
        let dir = folder(for: project)
        guard dir.standardizedFileURL != item.folder.standardizedFileURL else { return item }
        try fm.createDirectory(at: dir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        var moved = item
        moved.attachments = try item.attachments.map { relative in
            let source = item.folder.appendingPathComponent(relative)
            guard fm.fileExists(atPath: source.path) else { return relative }
            let target = uniqueURL(in: dir.appendingPathComponent("attachments"), base: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
            try fm.moveItem(at: source, to: target)
            return "attachments/" + target.lastPathComponent
        }
        let file = uniqueURL(in: dir, base: item.id, ext: "md")
        try fm.moveItem(at: item.file, to: file)
        moved.file = file
        moved.id = file.deletingPathExtension().lastPathComponent
        moved.project = project
        return try save(moved)
    }

    /// Creates an empty project folder. Returns its name.
    @discardableResult
    public func createProject(named name: String) throws -> String {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let folderName = clean.isEmpty ? "untitled" : clean
        try fm.createDirectory(at: folder(for: folderName), withIntermediateDirectories: true)
        return folderName
    }

    // MARK: Sessions

    private func sessionsDir(for project: String?) -> URL {
        folder(for: project).appendingPathComponent("sessions", isDirectory: true)
    }

    public func sessions(in project: String?) -> [Session] {
        let dir = sessionsDir(for: project)
        return ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .compactMap { folder -> Session? in
                guard let text = try? String(contentsOf: folder.appendingPathComponent("session.md"), encoding: .utf8) else { return nil }
                var session = Session.parse(text, folder: folder)
                session.project = project
                return session
            }
            .sorted { $0.started > $1.started }
    }

    public func allSessions() -> [Session] {
        ([nil] + projectNames().map(Optional.some)).flatMap { sessions(in: $0) }.sorted { $0.started > $1.started }
    }

    public func activeSession() -> Session? {
        allSessions().first { $0.isActive }
    }

    @discardableResult
    public func startSession(kind: SessionKind, project: String?, title: String, date: Date = Date()) throws -> Session {
        let dir = sessionsDir(for: project)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "\(Self.fileStamp.string(from: date))-\(String(TextTools.slugify(title).prefix(40)))"
        let folder = uniqueURL(in: dir, base: name, ext: "")
        try fm.createDirectory(at: folder.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let session = Session(id: folder.lastPathComponent, folder: folder, project: project, kind: kind,
                              title: title, started: date, ended: nil, entries: [])
        try write(session)
        return session
    }

    /// The session as it is on disk now. The other device (or another window) may have added entries or ended it
    /// since this copy was read, and writing the old copy back would wipe that.
    public func fresh(_ session: Session) -> Session {
        guard let text = try? String(contentsOf: session.file, encoding: .utf8) else { return session }
        var current = Session.parse(text, folder: session.folder)
        current.project = session.project
        return current
    }

    /// Adds an entry; attachment files are copied into the session's shots folder.
    @discardableResult
    public func append(text: String, files: [URL], context: ItemContext, to session: Session, date: Date = Date()) throws -> Session {
        var updated = fresh(session)
        guard updated.isActive else { throw NotesError.sessionEnded(session.title) }
        let shots = try files.filter { fm.fileExists(atPath: $0.path) }.map { try copyAttachment($0, into: session.folder, subfolder: "shots", date: date) }
        updated.entries.append(SessionEntry(time: date, text: text, attachments: shots, context: context))
        try write(updated)
        return updated
    }

    @discardableResult
    public func endSession(_ session: Session, date: Date = Date()) throws -> Session {
        var ended = fresh(session)
        // Already ended elsewhere: keep that end, don't move it.
        guard ended.isActive else { return ended }
        ended.ended = date
        try write(ended)
        return ended
    }

    public func write(_ session: Session) throws {
        try session.render().write(to: session.file, atomically: true, encoding: .utf8)
    }

    public func writeReport(_ markdown: String, for session: Session) throws {
        try markdown.write(to: session.reportFile, atomically: true, encoding: .utf8)
    }

    // MARK: Files

    private func copyAttachment(_ source: URL, into folder: URL, subfolder: String, date: Date) throws -> String {
        let dir = folder.appendingPathComponent(subfolder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let stamp = Session.entryStamp.string(from: date).replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "")
        let target = uniqueURL(in: dir, base: stamp, ext: ext)
        try fm.copyItem(at: source, to: target)
        return subfolder + "/" + target.lastPathComponent
    }

    private func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(name, isDirectory: true) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = make("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    // MARK: Upgrading from 0.2

    /// Converts the old one-line-per-note files (inbox.md, projects/<name>.md) into item files,
    /// then moves the originals to .broski/legacy-0.2/. Returns how many notes were converted.
    @discardableResult
    public func migrateLegacyNotes() throws -> Int {
        let legacyInbox = root.appendingPathComponent("inbox.md")
        let legacyFiles = [legacyInbox]
            + (((try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "md" })
        let existing = legacyFiles.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return 0 }
        let backup = root.appendingPathComponent(".broski/legacy-0.2", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        var count = 0
        for file in existing {
            let project: String? = file == legacyInbox ? nil : file.deletingPathExtension().lastPathComponent
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for entry in NotesFormat.parse(text, file: file) {
                var draft = ItemDraft(project: project, kind: entry.kind, title: entry.body)
                if entry.done { draft.status = .done }
                try create(draft, date: entry.date ?? Date())
                count += 1
            }
            let target = uniqueURL(in: backup, base: (project ?? "inbox"), ext: "md")
            try fm.moveItem(at: file, to: target)
        }
        return count
    }
}
