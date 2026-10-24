import Foundation

// MARK: The universal core

/// The sections every project's tracker shares, whatever the project is.
/// Everything else in a tracker belongs to the project's own layer (protocol details, strategies, courses…).
public enum CoreSection: String, Codable, CaseIterable {
    /// Building it: tasks, releases, deployments, the sprint.
    case ship
    /// Getting it out: launch plans, phases, rehearsals, mainnet.
    case launch
    /// Running it: runbooks, journals, incidents, live operations.
    case ops
    /// What was settled, why, and by whom.
    case decisions
    /// Who is working on what right now, and what is waiting on whom.
    case threads
    /// Findings, bugs, risks: what's open and how bad.
    case findings
    /// Not core: part of the project's own layer.
    case layer

    public var label: String {
        switch self {
        case .ship: return "Ship"
        case .launch: return "Launch"
        case .ops: return "Ops"
        case .decisions: return "Decisions"
        case .threads: return "Threads"
        case .findings: return "Findings"
        case .layer: return "Project layer"
        }
    }
}

// MARK: Projects

/// Every project Broski knows, in one file at the notes root (`projects.json`): its real name, where its
/// code lives, and which trackers it has. Trackers are read in place, read-only: the project's own
/// tracker stays the source of truth.
public struct ProjectRegistry: Codable, Equatable {
    public struct Entry: Codable, Equatable, Identifiable {
        /// The name Broski shows ("ROOK", even if the folder is still called SAI).
        public var name: String
        /// The Broski notes project these notes file into (`projects/<notes>/`).
        public var notes: String
        public var kind: Kind
        /// One line on what it is.
        public var about: String
        /// Code folders (a project can span several repos).
        public var folders: [String]
        public var trackers: [TrackerSource]
        /// Earlier names, so "SAI" still finds ROOK.
        public var aliases: [String]

        public enum Kind: String, Codable { case work, personal }

        public var id: String { notes }

        public init(name: String, notes: String, kind: Kind = .work, about: String = "", folders: [String] = [],
                    trackers: [TrackerSource] = [], aliases: [String] = []) {
            self.name = name
            self.notes = notes
            self.kind = kind
            self.about = about
            self.folders = folders
            self.trackers = trackers
            self.aliases = aliases
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? name.lowercased()
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .work
            about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
            folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
            trackers = try c.decodeIfPresent([TrackerSource].self, forKey: .trackers) ?? []
            aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }
    }

    public var projects: [Entry]

    public init(projects: [Entry] = []) {
        self.projects = projects
    }

    public static let fileName = "projects.json"

    public static func load(from root: URL) -> ProjectRegistry {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let registry = try? JSONDecoder().decode(ProjectRegistry.self, from: data) else { return ProjectRegistry() }
        return registry
    }

    public func save(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public func entry(notes: String?) -> Entry? {
        guard let notes else { return nil }
        return projects.first { $0.notes == notes }
    }

    /// "Acme Protocol", "acme", an old name → the entry.
    public func entry(named name: String) -> Entry? {
        let key = TextTools.matchKey(name)
        return projects.first { entry in
            ([entry.name, entry.notes] + entry.aliases).contains { TextTools.matchKey($0) == key }
        }
    }
}

/// A tracker Broski reads: a folder with items (markdown + YAML front matter), datasets (JSON) and docs.
public struct TrackerSource: Codable, Equatable, Identifiable {
    /// Short id used in citations: "one" → `[[one:ONE-X168]]`.
    public var id: String
    public var name: String
    public var path: String
    /// Always true for now: Broski never writes into a project's tracker.
    public var readOnly: Bool
    /// The tracker's own board, if it runs one (for live readings Broski must not repeat).
    public var board: String?
    public var scope: Scope
    /// Folders inside `path` not to read (a tracker that has its own source).
    public var exclude: [String] = []

    public enum Scope: String, Codable {
        /// A whole tracker folder: items, datasets, docs.
        case tracker
        /// A code repo: only its docs (top-level markdown, docs/, decisions, runbooks). Never code or configs.
        case docs
    }

    public init(id: String, name: String, path: String, readOnly: Bool = true, board: String? = nil, scope: Scope = .tracker) {
        self.id = id
        self.name = name
        self.path = path
        self.readOnly = readOnly
        self.board = board
        self.scope = scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        path = try c.decode(String.self, forKey: .path)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? true
        board = try c.decodeIfPresent(String.self, forKey: .board)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .tracker
    }

    public var url: URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true) }
}

// MARK: Records

/// One thing in a tracker: a finding, decision, launch step, runbook action, thread, message, lesson, or a doc section.
public struct TrackerRecord: Equatable, Identifiable {
    /// "<tracker id>:<record id>", e.g. "one:ONE-X168" or "one:launch/launch-bootstrap". Stable: it's a citation.
    public var id: String
    public var recordID: String
    public var source: String
    public var project: String
    public var kind: String
    public var title: String
    public var summary: String
    /// The tracker's own status word, untouched.
    public var status: String
    public var canonical: CanonicalStatus
    public var owner: String
    public var severity: String
    public var section: CoreSection
    public var layer: String
    public var date: Date?
    public var refs: [String]
    public var body: String
    public var file: URL
    /// Path inside the tracker ("tracker/findings/ONE-X168.md").
    public var path: String
    /// The board's deep link, when the tracker has a board.
    public var link: String?
    /// The plan this step belongs to ("launch", "rehearsal").
    public var launch: String?
    /// History, kept for "how did we do it last time", left out of default answers.
    public var archived: Bool
    /// Generated by a tool: describe it, never repeat its numbers.
    public var derived: Bool
    /// Prose known to drift (README counts…): never the source of a count or a state.
    public var lowTrust: Bool
    /// Native fields that matter for answers (area, decider, blocks, fixed_on…).
    public var fields: [String: String]

    public var open: Bool { canonical.isOpen }

    public var noteRef: NoteRef {
        let kind: NoteKind
        switch self.kind {
        case "finding", "bug", "risk", "incident", "ops": kind = .bug
        case "task", "todo", "step", "test": kind = .todo
        case "idea": kind = .idea
        default: kind = .note
        }
        var details: [String] = []
        if !status.isEmpty { details.append("status \(status)" + (canonical == .live ? " (state is live: ask the board)" : "")) }
        if !severity.isEmpty { details.append("severity \(severity)") }
        if !owner.isEmpty { details.append("owner \(owner)") }
        if let launch { details.append("plan \(launch)") }
        if archived { details.append("ARCHIVED") }
        if derived { details.append("GENERATED (cite the generator, don't repeat numbers)") }
        if lowTrust { details.append("PROSE MAP (may be out of date; never take counts or state from it)") }
        let extra = fields.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        let head = "\(self.kind.capitalized) \(recordID)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
        let text = [head, summary, extra, String(body.prefix(1600))].filter { !$0.isEmpty }.joined(separator: "\n")
        return NoteRef(id: id, project: project, kind: kind, title: "\(recordID): \(title)", body: text,
                       date: date ?? Date.distantPast, open: open, file: file, source: source)
    }
}

/// What one read of a tracker produced.
public struct TrackerSnapshot: Equatable {
    public var source: String
    public var manifest: String
    public var revision: String?
    public var readAt: Date
    public var records: [TrackerRecord]
    public var problems: [String]
    public var seconds: Double
    /// Where the manifest no longer fits the tracker. Only for whole trackers: a docs folder's globs are guesses.
    public var drift = TrackerDrift()
}

/// Where a tracker has moved away from its manifest since onboarding: the records are read live, but the map of
/// which files feed which section, and the status words it knows, are not.
public struct TrackerDrift: Equatable {
    /// Files read for nothing: no source's file or glob takes them (sorted, at most 200; `unmappedCount` is the total).
    public var unmapped: [String]
    public var unmappedCount: Int
    /// Sources that find nothing any more, as "ops.runbook <- tracker/data/runbook.json".
    public var deadSources: [String]
    /// Native status words neither the manifest nor CanonicalStatus knows, with how many records use each.
    public var unknownStatuses: [String: Int]

    public init(unmapped: [String] = [], unmappedCount: Int? = nil, deadSources: [String] = [], unknownStatuses: [String: Int] = [:]) {
        self.unmapped = unmapped
        self.unmappedCount = unmappedCount ?? unmapped.count
        self.deadSources = deadSources
        self.unknownStatuses = unknownStatuses
    }

    public var isEmpty: Bool { unmappedCount == 0 && deadSources.isEmpty && unknownStatuses.isEmpty }

    /// Status words, most used first: "parked (3)".
    public var statusWords: [String] {
        unknownStatuses.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key) (\($0.value))" }
    }

    /// One line per kind of drift, for the CLI, MCP and the dashboard.
    public var lines: [String] {
        var out: [String] = []
        if unmappedCount > 0 {
            out.append("\(unmappedCount) file\(unmappedCount == 1 ? "" : "s") no source reads: " + unmapped.prefix(20).joined(separator: ", ")
                       + (unmappedCount > 20 ? ", …and \(unmappedCount - 20) more" : ""))
        }
        if !deadSources.isEmpty {
            out.append("\(deadSources.count) mapping\(deadSources.count == 1 ? "" : "s") find\(deadSources.count == 1 ? "s" : "") nothing: " + deadSources.joined(separator: "; "))
        }
        if !unknownStatuses.isEmpty { out.append("unknown status words: " + statusWords.joined(separator: ", ")) }
        return out
    }

    /// Several trackers' drift as one; each path is prefixed with its tracker when there's more than one.
    public static func combined(_ drifts: [(source: String, drift: TrackerDrift)]) -> TrackerDrift {
        guard drifts.count > 1 else { return drifts.first?.drift ?? TrackerDrift() }
        var out = TrackerDrift()
        for (source, drift) in drifts {
            out.unmapped += drift.unmapped.map { "\(source): \($0)" }
            out.unmappedCount += drift.unmappedCount
            out.deadSources += drift.deadSources.map { "\(source): \($0)" }
            out.unknownStatuses.merge(drift.unknownStatuses, uniquingKeysWith: +)
        }
        out.unmapped = Array(out.unmapped.sorted().prefix(200))
        return out
    }
}

// MARK: Reading trackers

public enum TrackerReader {
    /// Reads a tracker in place through its manifest. Never writes, never reads secrets.
    public static func read(_ source: TrackerSource, project: String, overlays: URL? = nil) -> [TrackerRecord] {
        snapshot(source, project: project, overlays: overlays).records
    }

    public static func snapshot(_ source: TrackerSource, project: String, overlays: URL? = nil) -> TrackerSnapshot {
        let started = Date()
        let manifest = TrackerManifest.resolve(for: source, overlays: overlays)
        let root = source.url
        guard FileManager.default.fileExists(atPath: root.path) else {
            return TrackerSnapshot(source: source.id, manifest: manifest.adapter, revision: nil, readAt: Date(), records: [],
                                   problems: ["\(root.path) is missing"], seconds: 0)
        }
        var fs: TrackerFS = WorkingTreeFS(root: root, docsOnly: source.scope == .docs)
        var problems: [String] = []
        #if os(macOS)
        if let ref = manifest.readFrom {
            if let git = GitSnapshotFS(root: root, ref: ref) {
                fs = git
                git.preloadDates()
            } else {
                problems.append("couldn't read git ref \(ref); read the working tree instead")
            }
        }
        #endif
        let excluded = (manifest.exclude ?? []) + source.exclude.compactMap { path in
            let full = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            let base = root.standardizedFileURL.path
            return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) + "/**" : nil
        }
        let files = fs.files.filter { path in !excluded.contains { Glob.matches(path, $0) } }
        let context = Context(manifest: manifest, source: source, project: project, fs: fs, root: root)

        var jobs: [(Source: TrackerManifest.Source, section: CoreSection, layer: String)] = []
        for (name, sources) in manifest.core {
            let section = CoreSection(rawValue: name) ?? .layer
            for s in sources { jobs.append((s, section, section == .layer ? name : "")) }
        }
        for layer in manifest.layers ?? [] {
            for s in layer.sources { jobs.append((s, .layer, layer.name)) }
        }
        // Find every file each source wants, then read them in one go.
        let matched = jobs.map { matches($0.Source, in: files) }
        #if os(macOS)
        (fs as? GitSnapshotFS)?.preload(Array(Set(matched.flatMap { $0 })))
        #endif
        var records: [TrackerRecord] = []
        var seen = Set<String>()
        for (job, paths) in zip(jobs, matched) {
            for path in paths {
                for record in context.read(path, job.Source, section: job.section, layer: job.layer) where !seen.contains(record.id) {
                    seen.insert(record.id)
                    records.append(record)
                }
            }
        }
        context.finish(&records)
        var snapshot = TrackerSnapshot(source: source.id, manifest: manifest.adapter, revision: fs.revision, readAt: Date(),
                                       records: records, problems: problems, seconds: Date().timeIntervalSince(started))
        if source.scope == .tracker {
            snapshot.drift = drift(manifest: manifest, files: files, jobs: jobs.map { ($0.Source, $0.section, $0.layer) },
                                   matched: matched, records: records)
        }
        return snapshot
    }

    /// What the manifest misses, from what this read already holds: the files it saw, what each source matched, the records.
    static func drift(manifest: TrackerManifest, files: [String], jobs: [(TrackerManifest.Source, CoreSection, String)],
                      matched: [[String]], records: [TrackerRecord]) -> TrackerDrift {
        let taken = Set(matched.flatMap { $0 })
        let skipped = Set((manifest.generated ?? []) + (manifest.archived ?? []))
        let toolConfigs: Set<String> = ["package.json", "package-lock.json", "composer.json", "jsconfig.json", "deno.json", "vercel.json",
                                        "turbo.json", "nx.json", "lerna.json", "renovate.json", "components.json"]
        let unmapped = files.filter { path in
            let name = (path as NSString).lastPathComponent
            let lower = name.lowercased()
            guard ["md", "json", "jsonl"].contains((lower as NSString).pathExtension), !taken.contains(path) else { return false }
            // A git snapshot lists what the working tree skips (hidden and tool folders); neither is tracker data.
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") || WorkingTreeFS.skipped.contains($0.lowercased()) }) { return false }
            if toolConfigs.contains(lower) || lower.hasPrefix("tsconfig") { return false }
            // The manifest itself, and a folder's README (it describes the folder; it's never a source).
            if name == TrackerManifest.fileName || (lower == "readme.md" && path.contains("/")) { return false }
            if skipped.contains((name as NSString).deletingPathExtension) { return false }
            // Schemas describe records; they never hold any.
            if path.split(separator: "/").contains(where: { $0.lowercased() == "schema" || $0.lowercased() == "schemas" }) || lower.hasSuffix(".schema.json") { return false }
            return !(manifest.lowTrust ?? []).contains { Glob.matches(path, $0) }
        }.sorted()

        var dead: [String] = []
        for ((source, section, layer), paths) in zip(jobs, matched) where isDead(source, matched: paths, files: files) {
            let label = section == .layer ? "layer.\(layer)" : section.rawValue
            dead.append("\(label)\(source.kind.map { ".\($0)" } ?? "") <- \(source.file ?? source.glob ?? "?")")
        }

        // Words the reader turned into a guess: the manifest's own map and open words count as known.
        let mapped = Set((manifest.statusMap ?? [:]).keys.map { $0.lowercased() } + (manifest.openWhen ?? []).map { $0.lowercased() })
        var unknown: [String: Int] = [:]
        // Only where a status means open or closed (items, decisions, launch steps), and only words shaped like a
        // status: a "status" holding prose or a date ("allocated 2026-10-06") is a note, not a new word to map.
        for r in records where !r.archived && !r.derived && r.canonical != .live && [.findings, .decisions, .launch].contains(r.section) {
            let word = r.status.lowercased().trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !mapped.contains(word), !CanonicalStatus.isKnown(word),
                  word.count <= 24, word.split(separator: " ").count <= 2,
                  word.range(of: #"^[a-z][a-z' _-]*$"#, options: .regularExpression) != nil else { continue }
            unknown[word, default: 0] += 1
        }
        return TrackerDrift(unmapped: Array(unmapped.prefix(200)), unmappedCount: unmapped.count, deadSources: dead.sorted(), unknownStatuses: unknown)
    }

    /// The files a source reads, of those a read sees.
    static func matches(_ source: TrackerManifest.Source, in files: [String]) -> [String] {
        if let file = source.file { return files.contains(file) ? [file] : [] }
        if let glob = source.glob { return files.filter { Glob.matches($0, glob) } }
        return []
    }

    /// A file that's gone is dead; a glob only when nothing is left in the folder it reads, since an empty glob in a
    /// live folder is just "no records yet", and "{A.md,B.md}" lists are guesses by name.
    static func isDead(_ source: TrackerManifest.Source, matched: [String], files: [String]) -> Bool {
        guard matched.isEmpty else { return false }
        if source.file == nil, let glob = source.glob, glob.contains(where: { "*?{[".contains($0) }) {
            let folder = literalFolder(glob)
            return !folder.isEmpty && !files.contains { $0.hasPrefix(folder) }
        }
        return true
    }

    /// "tracker/findings/*.md" → "tracker/findings/"; "layers/*/*.md" → "layers/"; "{A,B}.md" → "" (the root).
    static func literalFolder(_ glob: String) -> String {
        var parts: [Substring] = []
        for part in glob.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
            if part.contains(where: { "*?{[".contains($0) }) { break }
            parts.append(part)
        }
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }

    // MARK: Helpers shared by readers

    public static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func parseDateString(_ text: String) -> Date? { parseDate(text) }

    static func parseDate(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 10 else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        return dayFormatter.date(from: String(s.prefix(10)))
    }

    /// Markdown and HTML down to readable text.
    static func plainText(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&rarr;", "→"), ("&mdash;", "—")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        out = out.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber: return n.stringValue
        case let a as [Any]: let parts = a.compactMap { string($0) }; return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case let d as [String: Any]:
            if let s = d["id"] as? String { return s }
            guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        default: return nil
        }
    }

    static let titleKeys = ["title", "what", "question", "name", "label", "step", "summary", "task", "lesson", "term", "role", "group", "phase", "subject", "text"]
    static let ownerKeys = ["owner", "who", "thread", "to", "agent", "assignee", "decider", "by"]
    static let dateKeys = ["decidedAt", "decided_at", "updated", "updated_at", "closed", "at", "date", "raisedAt", "opened", "created", "when", "compiledAt"]
    static let summaryKeys = ["plain", "decision", "why", "does", "detail", "lesson", "note", "recommendation", "how", "expect"]
    /// Fields worth carrying into answers.
    static let keptFields = ["area", "where", "decider", "decidedBy", "decided_by", "blocks", "after", "fixed_on", "verified_by", "options",
                             "recommendation", "cosign", "approve", "command", "requires", "check", "launch", "evidence", "attested",
                             "links", "refs", "series", "category", "phase", "owns", "branch", "worktree", "repo", "ref", "by", "to",
                             "history", "expect", "how", "required", "did", "took", "blockers", "lessons", "env", "state", "package", "plan",
                             "decidedAt", "raisedAt", "decision", "who", "opened", "closed"]
}

/// One read of one tracker: the manifest, where files come from, and the rules applied after reading.
struct Context {
    let manifest: TrackerManifest
    let source: TrackerSource
    let project: String
    let fs: TrackerFS
    let root: URL
    private let redactions: [NSRegularExpression]
    private let statusMap: [String: CanonicalStatus]

    init(manifest: TrackerManifest, source: TrackerSource, project: String, fs: TrackerFS, root: URL) {
        self.manifest = manifest
        self.source = source
        self.project = project
        self.fs = fs
        self.root = root
        redactions = (manifest.redact ?? []).compactMap { try? NSRegularExpression(pattern: $0) }
        var map: [String: CanonicalStatus] = [:]
        for (native, canonical) in manifest.statusMap ?? [:] { map[native.lowercased()] = CanonicalStatus(rawValue: canonical) ?? .from(canonical) }
        statusMap = map
    }

    func redact(_ text: String) -> String {
        redactions.reduce(text) { out, re in
            re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[redacted]")
        }
    }

    func canonical(_ native: String, kind: String, live: Bool) -> CanonicalStatus {
        if live { return .live }
        let word = native.lowercased()
        if ["finding", "ops", "bug", "risk", "task", "todo", "incident", "item"].contains(kind), let openWhen = manifest.openWhen {
            return openWhen.contains(word) ? .open : (statusMap[word] ?? (word.isEmpty ? .none : CanonicalStatus.from(word) == .open ? .accepted : .from(word)))
        }
        return statusMap[word] ?? .from(word)
    }

    var datasetName: (String) -> String { { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } }

    func read(_ path: String, _ s: TrackerManifest.Source, section: CoreSection, layer: String) -> [TrackerRecord] {
        guard let data = fs.read(path) else { return [] }
        let name = datasetName(path)
        let archived = s.archived ?? (manifest.archived ?? []).contains(name)
        let lowTrust = (manifest.lowTrust ?? []).contains { Glob.matches(path, $0) }
        // Generated datasets: one record saying what they are, never their contents.
        if (manifest.generated ?? []).contains(name) {
            return [make(id: "dataset/\(name)", kind: "dataset", title: "\(name) (generated dataset, \(data.count / 1024) KB)",
                         summary: "Generated by a tool; ask the board or rerun the generator for its numbers.", status: "", owner: "",
                         section: .layer, layer: layer.isEmpty ? "generated" : layer, date: fs.modified(path), refs: [], body: "",
                         path: path, s: s, fields: [:], archived: archived, derived: true, lowTrust: false)]
        }
        switch s.reader {
        case "fm-records": return fmRecord(path, data, s, section, layer, archived, lowTrust)
        case "json-records", "json-doc": return jsonRecords(path, data, s, section, layer, archived)
        case "jsonl-records": return jsonlRecords(path, data, s, section, layer, archived)
        case "md-checklist": return checklist(path, data, s, section, layer, archived, lowTrust)
        case "md-sections", "md-doc": return sections(path, data, s, section, layer, archived, lowTrust, whole: s.reader == "md-doc")
        default: return []
        }
    }

    func make(id: String, kind: String, title: String, summary: String, status: String, owner: String, section: CoreSection,
              layer: String, date: Date?, refs: [String], body: String, path: String, s: TrackerManifest.Source,
              fields: [String: String], archived: Bool, derived: Bool, lowTrust: Bool, severity: String = "") -> TrackerRecord {
        let canonical = self.canonical(status, kind: kind, live: s.live ?? false)
        var link: String?
        if let board = manifest.board, let pattern = board.links?[kind] {
            let localID = id.split(separator: "/").last.map(String.init) ?? id
            link = board.url + pattern.replacingOccurrences(of: "{id}", with: localID).replacingOccurrences(of: "{launch}", with: s.launch ?? "")
        }
        return TrackerRecord(id: "\(manifest.id):\(id)", recordID: id, source: manifest.id, project: project, kind: kind,
                             title: redact(title), summary: redact(summary), status: status, canonical: canonical, owner: owner,
                             severity: severity, section: section, layer: layer, date: date, refs: refs, body: redact(body),
                             file: root.appendingPathComponent(path), path: path, link: link, launch: s.launch, archived: archived,
                             derived: derived, lowTrust: lowTrust, fields: fields.mapValues(redact))
    }

    // MARK: fm-records

    func fmRecord(_ path: String, _ data: Data, _ s: TrackerManifest.Source, _ section: CoreSection, _ layer: String,
                  _ archived: Bool, _ lowTrust: Bool) -> [TrackerRecord] {
        let text = String(decoding: data, as: UTF8.self)
        let (front, body) = YAMLFrontMatter.split(text)
        // A file without front matter (a folder's README) isn't a record.
        if front.isEmpty { return [] }
        func field(_ canonical: String, _ fallbacks: [String]) -> String {
            if let native = s.map?[canonical], let value = front[native]?.string, !value.isEmpty { return value }
            for key in fallbacks { if let value = front[key]?.string, !value.isEmpty { return value } }
            return ""
        }
        if let filter = s.filter, !filter.allSatisfy({ front[$0.key]?.string == $0.value }) { return [] }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let id = field("id", ["id"]).isEmpty ? stem : field("id", ["id"])
        var kind = s.kind ?? "item"
        if let from = s.kindFrom, let value = front[from]?.string, !value.isEmpty { kind = value.lowercased() }
        let rawBody = front["body_format"]?.string == "html" ? TrackerReader.plainText(body) : body
        var fields: [String: String] = [:]
        for key in TrackerReader.keptFields { if let value = front[key]?.string, !value.isEmpty { fields[key] = value } }
        if let thread = front["thread"]?.string { fields["thread"] = thread }
        let date = TrackerReader.dateKeys.compactMap { front[$0]?.string }.compactMap(TrackerReader.parseDate).first ?? fs.modified(path)
        if let opened = front["opened"]?.string { fields["opened"] = opened }
        if let closed = front["closed"]?.string { fields["closed"] = closed }
        // Old decisions filed as findings stay in the register, where the tracker's own board counts them.
        let sectionFor: CoreSection = section
        return [make(id: id, kind: kind, title: field("title", ["title"]).isEmpty ? id : field("title", ["title"]),
                     summary: field("summary", ["plain", "decision", "summary"]), status: field("status", ["status"]),
                     owner: field("owner", ["owner", "thread", "decider"]), section: sectionFor, layer: layer, date: date,
                     refs: (front["links"]?.list ?? []) + (front["refs"]?.list ?? []), body: rawBody, path: path, s: s,
                     fields: fields, archived: archived, derived: false, lowTrust: lowTrust,
                     severity: field("severity", ["severity", "impact"]))]
    }

    // MARK: json-records / json-doc

    func jsonRecords(_ path: String, _ data: Data, _ s: TrackerManifest.Source, _ section: CoreSection, _ layer: String,
                     _ archived: Bool) -> [TrackerRecord] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let name = datasetName(path)
        let modified = fs.modified(path)
        if s.reader == "json-doc" {
            // One record for the whole thing (an HTML runbook, a rules object).
            let value: Any = s.path.flatMap { p in JSONPath.select(json, p).first?.object } ?? (json as? [String: Any])?["value"] ?? json
            let text: String
            if let html = value as? String { text = TrackerReader.plainText(html) }
            else if let html = (json as? [String: Any])?["value"] as? String { text = TrackerReader.plainText(html) }
            else { text = TrackerReader.string(value) ?? "" }
            return [make(id: name, kind: s.kind ?? "doc", title: name.replacingOccurrences(of: "-", with: " ").capitalized,
                         summary: "", status: "", owner: "", section: section, layer: layer, date: modified, refs: [],
                         body: String(text.prefix(12_000)), path: path, s: s, fields: [:], archived: archived, derived: false, lowTrust: false)]
        }
        var out: [TrackerRecord] = []
        for (index, (object, parent)) in JSONPath.select(json, s.path ?? "value[]").prefix(600).enumerated() {
            if let filter = s.filter, !filter.allSatisfy({ TrackerReader.string(object[$0.key]) == $0.value }) { continue }
            func value(_ canonical: String, _ fallbacks: [String]) -> String {
                if let native = s.map?[canonical], let v = TrackerReader.string(object[native]) { return v }
                for key in fallbacks { if let v = TrackerReader.string(object[key]) { return v } }
                return ""
            }
            let native = value("id", ["id", "slug", "key", "name"])
            let id = native.isEmpty ? "\(name)-\(index + 1)" : native
            let localID = s.launch.map { "\($0)/\(id)" } ?? (s.kind == "decision" || id.contains("-") && id.uppercased() == id ? id : "\(name)/\(id)")
            var fields: [String: String] = [:]
            for key in TrackerReader.keptFields { if let v = TrackerReader.string(object[key]) { fields[key] = String(v.prefix(600)) } }
            if let thread = TrackerReader.string(object["thread"]) { fields["thread"] = thread }
            fields["dataset"] = name
            if let phase = TrackerReader.string(parent["id"]) ?? TrackerReader.string(parent["phase"]) { fields["parent"] = phase }
            if let step = TrackerReader.string(object["step"]) { fields["step"] = step }
            let title = value("title", TrackerReader.titleKeys)
            let date = TrackerReader.dateKeys.compactMap { TrackerReader.string(object[$0]) }.compactMap(TrackerReader.parseDate).first ?? modified
            var body = ""
            if let detail = TrackerReader.string(object["detail"]) { body = TrackerReader.plainText(detail) }
            if let history = object["history"] as? [[String: Any]], !history.isEmpty {
                body += (body.isEmpty ? "" : "\n") + "History: " + history.compactMap { h in
                    [TrackerReader.string(h["at"]), TrackerReader.string(h["change"])].compactMap { $0 }.joined(separator: " ")
                }.joined(separator: " | ")
            }
            let refs = ((object["refs"] as? [Any]) ?? []) + ((object["blocks"] as? [Any]) ?? []) + ((object["links"] as? [Any]) ?? [])
            let kind = s.kind ?? (name.hasSuffix("s") ? String(name.dropLast()) : name)
            out.append(make(id: localID, kind: kind, title: title.isEmpty ? id : TrackerReader.plainText(title),
                            summary: TrackerReader.plainText(value("summary", TrackerReader.summaryKeys)),
                            status: value("status", ["status", "state"]), owner: value("owner", TrackerReader.ownerKeys),
                            section: kind == "decision" ? .decisions : section, layer: layer, date: date,
                            refs: refs.compactMap { TrackerReader.string($0) }, body: String(body.prefix(4000)), path: path, s: s,
                            fields: fields, archived: archived, derived: false, lowTrust: false,
                            severity: value("severity", ["severity", "risk", "priority"])))
        }
        return out
    }

    // MARK: jsonl-records

    func jsonlRecords(_ path: String, _ data: Data, _ s: TrackerManifest.Source, _ section: CoreSection, _ layer: String,
                      _ archived: Bool) -> [TrackerRecord] {
        let name = datasetName(path)
        var out: [TrackerRecord] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if let filter = s.filter, !filter.allSatisfy({ TrackerReader.string(object[$0.key]) == $0.value }) { continue }
            guard let id = TrackerReader.string(object["id"]) else { continue }
            func value(_ canonical: String, _ fallbacks: [String]) -> String {
                if let native = s.map?[canonical], let v = TrackerReader.string(object[native]) { return v }
                for key in fallbacks { if let v = TrackerReader.string(object[key]) { return v } }
                return ""
            }
            var fields: [String: String] = [:]
            for key in ["by", "to", "ref", "refKind", "file", "record", "owner", "kept", "dropped", "path", "kind"] {
                if let v = TrackerReader.string(object[key]) { fields[key] = String(v.prefix(300)) }
            }
            let title = value("title", ["text", "subject", "note", "record"])
            out.append(make(id: "\(name)/\(id)", kind: s.kind ?? "message", title: String(title.prefix(200)),
                            summary: "", status: s.kind == "message" ? "unread" : (s.kind == "conflict" ? "open" : ""),
                            owner: value("owner", ["to", "owner"]), section: section, layer: layer,
                            date: TrackerReader.parseDate(value("date", ["at", "date"])), refs: [value("ref", ["ref", "record"])].filter { !$0.isEmpty },
                            body: title, path: path, s: s, fields: fields, archived: archived, derived: false, lowTrust: false))
        }
        // Acknowledgements and resolutions: mark what's been read or settled.
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        var acked: [String: Set<String>] = [:]  // remark id → threads that acked it
        var resolved = Set<String>()
        for object in lines {
            if TrackerReader.string(object["kind"]) == "ack", let by = TrackerReader.string(object["by"]) {
                for id in (object["acks"] as? [String]) ?? [] { acked[id, default: []].insert(by) }
            }
            if TrackerReader.string(object["kind"]) == "resolution", let target = TrackerReader.string(object["resolves"]) { resolved.insert(target) }
        }
        for i in out.indices {
            let native = String(out[i].recordID.split(separator: "/").last ?? "")
            if out[i].kind == "message", let to = out[i].fields["to"], acked[native]?.contains(to) == true {
                out[i].status = "read"
                out[i].canonical = .read
            }
            if out[i].kind == "conflict", resolved.contains(native) {
                out[i].status = "resolved"
                out[i].canonical = .done
            }
        }
        return out
    }

    // MARK: md-checklist

    func checklist(_ path: String, _ data: Data, _ s: TrackerManifest.Source, _ section: CoreSection, _ layer: String,
                   _ archived: Bool, _ lowTrust: Bool) -> [TrackerRecord] {
        let text = String(decoding: data, as: UTF8.self)
        let idRegex = s.idPattern.flatMap { try? NSRegularExpression(pattern: $0) }
        var out: [TrackerRecord] = []
        var heading = ""
        var lines = text.components(separatedBy: "\n")[...]
        var verifiedLane = false
        var paused = false
        let modified = fs.modified(path)
        while let line = lines.popFirst() {
            if line.hasPrefix("#") {
                heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
                let lower = heading.lowercased()
                verifiedLane = lower.contains("verified") || lower.contains("done")
                paused = lower.contains("paused") || lower.contains("later")
                if lower.contains("work log") { verifiedLane = false }
                continue
            }
            guard line.hasPrefix("- [ ]") || line.hasPrefix("- [x]") || line.hasPrefix("- [X]") else { continue }
            let checked = !line.hasPrefix("- [ ]")
            var item = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            // Continuation lines belong to the item.
            while let next = lines.first, next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).hasPrefix("- [") {
                item += " " + next.trimmingCharacters(in: .whitespaces)
                lines.removeFirst()
            }
            let plain = item.replacingOccurrences(of: "**", with: "")
            var id = ""
            if let idRegex, let m = idRegex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                let r = m.numberOfRanges > 1 ? m.range(at: 1) : m.range
                if let range = Range(r, in: plain) { id = String(plain[range]) }
            }
            // The path, not the file name: TODO.md and docs/TODO.md would share "TODO#1" and one would be dropped.
            if id.isEmpty { id = "\(path)#\(out.count + 1)" }
            let title = plain.split(separator: "—").first.map { String($0).replacingOccurrences(of: id, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " :·—-")) } ?? plain
            let status = checked ? (verifiedLane || plain.contains("✅") ? "verified" : "done") : (paused ? "paused" : "open")
            out.append(make(id: id, kind: s.kind ?? "task", title: String(title.prefix(160)), summary: "", status: status,
                            owner: "", section: section, layer: layer, date: modified, refs: [], body: String(plain.prefix(2000)),
                            path: path, s: s, fields: ["lane": heading], archived: archived, derived: false, lowTrust: lowTrust))
        }
        return out
    }

    // MARK: md-sections / md-doc

    func sections(_ path: String, _ data: Data, _ s: TrackerManifest.Source, _ section: CoreSection, _ layer: String,
                  _ archived: Bool, _ lowTrust: Bool, whole: Bool) -> [TrackerRecord] {
        let text = String(decoding: data, as: UTF8.self)
        let (_, body) = YAMLFrontMatter.split(text)
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let level = s.level ?? 2
        let marker = String(repeating: "#", count: level) + " "
        let modified = fs.modified(path)
        var out: [TrackerRecord] = []
        let title = body.components(separatedBy: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? stem
        if whole {
            return [make(id: path, kind: s.kind ?? "doc", title: title, summary: "", status: "", owner: "", section: section, layer: layer,
                         date: modified, refs: [], body: TrackerReader.plainText(body), path: path, s: s, fields: [:],
                         archived: archived, derived: false, lowTrust: lowTrust)]
        }
        var heading = title
        var current: [String] = []
        var slugCounts: [String: Int] = [:]
        func flush() {
            let content = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            current = []
            // A repeated heading (a "## Verify" under each procedure) gets "-2", "-3", or the index would drop it as a
            // duplicate id. Short sections count too, so an id doesn't shift when an earlier section grows past 40.
            let base = String(TextTools.slugify(heading).prefix(48))
            let seen = (slugCounts[base] ?? 0) + 1
            slugCounts[base] = seen
            guard content.count > 40 else { return }
            let slug = seen == 1 ? base : "\(base)-\(seen)"
            // A dated heading ("## 2026-10-16: …", "## UPDATE 2026-10-16") carries its own date.
            let dated = heading.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression).flatMap { TrackerReader.parseDate(String(heading[$0])) }
            out.append(make(id: "\(path)#\(slug)", kind: s.kind ?? "doc", title: "\(stem): \(heading)", summary: "", status: "",
                            owner: "", section: section, layer: layer, date: dated ?? modified, refs: [],
                            body: TrackerReader.plainText(content), path: path, s: s, fields: [:], archived: archived,
                            derived: false, lowTrust: lowTrust))
        }
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix(marker) {
                flush()
                heading = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            } else {
                current.append(line)
            }
        }
        flush()
        return out
    }

    // MARK: After reading

    /// Owners by the tracker's own rules (an agents file: the record's thread, then the area rules, then the default).
    func finish(_ records: inout [TrackerRecord]) {
        guard let agents = records.first(where: { $0.kind == "thread" })?.path,
              let data = fs.read(agents), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? [String: Any] else { return }
        let rules = (value["owners"] as? [[String: Any]]) ?? []
        let fallback = (value["defaultOwner"] as? String) ?? "ops"
        for i in records.indices where ["finding", "ops", "decision", "step", "runbook", "test", "decision"].contains(records[i].kind) {
            if let thread = records[i].fields["thread"], !thread.isEmpty {
                records[i].fields["owner_thread"] = thread
                continue
            }
            let dataset = records[i].fields["dataset"] ?? ""
            let isFinding = records[i].kind == "finding" || records[i].kind == "ops"
            let localID = String(records[i].recordID.split(separator: "/").last ?? "")
            var owner = fallback
            for rule in rules {
                if let d = rule["dataset"] as? String, d != dataset { continue }
                if (rule["findings"] as? Bool) == true, !isFinding { continue }
                if let ids = rule["ids"] as? [String], !ids.contains(localID) { continue }
                if let steps = rule["steps"] as? [String], !steps.contains(records[i].fields["step"] ?? "\u{0}") { continue }
                if let prefix = rule["idPrefix"] as? String, !localID.hasPrefix(prefix) { continue }
                if let area = rule["area"] as? String {
                    guard let re = try? NSRegularExpression(pattern: area, options: .caseInsensitive) else { continue }
                    let text = records[i].fields["area"] ?? ""
                    if re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil { continue }
                }
                owner = (rule["owner"] as? String) ?? fallback
                break
            }
            records[i].fields["owner_thread"] = owner
        }
    }
}
