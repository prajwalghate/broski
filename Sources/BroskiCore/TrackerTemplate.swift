import Foundation

/// A tracker Broski owns, for projects that have none: plain markdown under `<BroskiRoot>/projects/<p>/tracker/`.
/// Projects' own trackers are never written; this is the only kind Broski edits.
public enum TrackerTemplate {
    public enum Failure: Error, CustomStringConvertible {
        case notBroskiOwned(String)
        case exists(String)
        case unknown(String)

        public var description: String {
            switch self {
            case .notBroskiOwned(let path): return "\(path) isn't a Broski-owned tracker; Broski never writes to a project's own tracker"
            case .exists(let path): return "\(path) already exists"
            case .unknown(let id): return "no item \(id)"
            }
        }
    }

    public static func folder(for project: String, root: URL) -> URL {
        root.appendingPathComponent("projects/\(project)/tracker", isDirectory: true)
    }

    /// Creates the tracker tree. Existing files are left alone, so running it twice is harmless.
    @discardableResult
    public static func create(project: String, title: String, about: String = "", root: URL, date: Date = Date()) throws -> URL {
        let base = folder(for: project, root: root)
        let day = TrackerReader.dayFormatter.string(from: date)
        let files: [(String, String)] = [
            ("TRACKER.md", """
            # \(title) tracker

            \(about.isEmpty ? "What this project is, in two sentences." : about)

            Broski owns this tracker. Items, decisions, plans and runbooks are plain markdown, so threads and people can
            edit them directly; Broski reads them on every change.

            - ship/PLAN.md: milestones, one `## ` section each, with exit criteria. ship/releases/: one file per release.
            - launch/: go-live checklists. One `- [ ] L-1 What — owner` line per step.
            - ops/runbooks/, ops/incidents/: one file each. ops/journal/: one `## YYYY-MM-DD` section per entry.
            - decisions/: one file per decision (DEC-n). items/: bugs, tasks, risks, findings (ids in ids.tsv).
            - threads/THREADS.md: who works on what, one `## ` section per thread.

            """),
            ("VISION.md", "# \(title): vision\n\nWhere this is going and why.\n"),
            ("ids.tsv", "id\tkind\ttitle\tcreated\n"),
            ("ship/PLAN.md", "# Plan\n\n## M1: first milestone\n\nExit criteria: what has to be true.\n\nStatus: current\n"),
            ("ship/releases/README.md", "One file per release: `vX.Y.md` with `version`, `date`, `where` in the front matter.\n"),
            ("launch/GO-LIVE.md", "# Go-live\n\n- [ ] L-1 Write the go-live checklist — you\n"),
            ("ops/runbooks/README.md", "One file per runbook (deploy, restart, rotate, restore), with `last_run` in the front matter.\n"),
            ("ops/incidents/README.md", "One file per incident: what happened, impact, fix, follow-ups.\n"),
            ("ops/journal/\(day.prefix(7)).md", "# Journal \(day.prefix(7))\n\n## \(day)\n\nTracker created.\n"),
            ("decisions/README.md", "One file per decision: `DEC-n.md` with `question`, `status` (open/decided), `decider`, `decidedAt`.\n"),
            ("threads/THREADS.md", "# Threads\n\n## main\n\nWhere it works, what it owns.\n"),
            ("items/README.md", "One file per item: `<ID>.md` with `id`, `kind` (bug/task/risk/finding/idea), `status`, `severity`.\n"),
            ("layers/README.md", "Anything this project tracks that doesn't fit the sections above, one folder per layer.\n"),
        ]
        for (path, text) in files {
            let url = base.appendingPathComponent(path)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return base
    }

    /// Only trackers inside Broski's own `projects/` folder may be written.
    public static func owned(_ tracker: URL, root: URL) -> Bool {
        let path = tracker.standardizedFileURL.resolvingSymlinksInPath().path
        let projects = root.appendingPathComponent("projects").standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(projects + "/") && FileManager.default.fileExists(atPath: tracker.appendingPathComponent("TRACKER.md").path)
    }

    static let prefixes = ["bug": "BUG", "task": "T", "risk": "RISK", "finding": "F", "idea": "IDEA", "decision": "DEC"]

    /// Next free id for a kind, from ids.tsv and the files present.
    static func nextID(kind: String, tracker: URL) -> String {
        let prefix = prefixes[kind] ?? "T"
        let registry = (try? String(contentsOf: tracker.appendingPathComponent("ids.tsv"), encoding: .utf8)) ?? ""
        let folder = kind == "decision" ? "decisions" : "items"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: tracker.appendingPathComponent(folder).path)) ?? []).map { ($0 as NSString).deletingPathExtension }
        let used = (registry.components(separatedBy: "\n").map { $0.components(separatedBy: "\t").first ?? "" } + names)
            .compactMap { id -> Int? in id.hasPrefix(prefix + "-") ? Int(id.dropFirst(prefix.count + 1)) : nil }
        return "\(prefix)-\((used.max() ?? 0) + 1)"
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    /// Adds an item (or a decision) and registers its id. Returns the id.
    @discardableResult
    public static func add(kind: String, title: String, body: String = "", severity: String? = nil, owner: String? = nil,
                           tracker: URL, root: URL, date: Date = Date()) throws -> String {
        guard owned(tracker, root: root) else { throw Failure.notBroskiOwned(tracker.path) }
        let kind = kind.lowercased()
        let id = nextID(kind: kind, tracker: tracker)
        let iso = FrontMatter.isoFormatter.string(from: date)
        var front = ["id: \(id)"]
        if kind == "decision" {
            front += ["question: \(quoted(title))", "status: open", "decider: \(owner ?? "you")", "raisedAt: \(iso)"]
        } else {
            front += ["kind: \(kind)", "title: \(quoted(title))", "status: open", "opened: \(iso)"]
            if let severity { front.append("severity: \(severity)") }
            if let owner { front.append("owner: \(owner)") }
        }
        let url = tracker.appendingPathComponent(kind == "decision" ? "decisions" : "items").appendingPathComponent("\(id).md")
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.exists(url.path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("---\n" + front.joined(separator: "\n") + "\n---\n" + (kind == "decision" ? "# \(title)\n\n" : "") + body + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        let registry = tracker.appendingPathComponent("ids.tsv")
        let row = "\(id)\t\(kind)\t\(title.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))\t\(TrackerReader.dayFormatter.string(from: date))\n"
        if let handle = try? FileHandle(forWritingTo: registry) {
            handle.seekToEndOfFile()
            handle.write(Data(row.utf8))
            try? handle.close()
        } else {
            try ("id\tkind\ttitle\tcreated\n" + row).write(to: registry, atomically: true, encoding: .utf8)
        }
        return id
    }

    /// Changes an item's status (and, for a decision, records the answer). Only Broski-owned trackers.
    public static func setStatus(_ id: String, to status: String, note: String? = nil, tracker: URL, root: URL, date: Date = Date()) throws {
        guard owned(tracker, root: root) else { throw Failure.notBroskiOwned(tracker.path) }
        let candidates = ["items", "decisions"].map { tracker.appendingPathComponent($0).appendingPathComponent("\(id).md") }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw Failure.unknown(id) }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            throw Failure.unknown(id)
        }
        let iso = FrontMatter.isoFormatter.string(from: date)
        var lines = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].components(separatedBy: "\n")
        func set(_ key: String, _ value: String) {
            if let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) { lines[i] = "\(key): \(value)" } else { lines.append("\(key): \(value)") }
        }
        set("status", status)
        set("updated", iso)
        let closed = !CanonicalStatus.from(status).isOpen
        // The same field names the reader and the journal use for every tracker.
        if closed { set(url.deletingLastPathComponent().lastPathComponent == "decisions" ? "decidedAt" : "closed", iso) }
        if let note, !note.isEmpty { set(url.deletingLastPathComponent().lastPathComponent == "decisions" ? "decision" : "resolution", quoted(note)) }
        let rest = String(text[end.upperBound...])
        try ("---\n" + lines.joined(separator: "\n") + "\n---\n" + rest).write(to: url, atomically: true, encoding: .utf8)
    }
}
