import AppKit
import BroskiCore


/// Everything the dashboard shows, read from ~/Broski and kept fresh as files change
/// (whether Broski or another editor changed them).
@MainActor
final class Library: ObservableObject {
    struct ProjectInfo: Identifiable, Equatable {
        let id: String
        let name: String
        /// The code folder this project came from, when there is one.
        let folder: URL?
        var items: [Item]
        var sessions: [Session]
        /// The registry entry (real name, code folders, trackers), when there is one.
        var entry: ProjectRegistry.Entry? = nil
        /// Records from the project's trackers and docs, read in place.
        var records: [TrackerRecord] = []
        var isInbox: Bool { id == Library.inboxID }
        var displayName: String { entry?.name ?? name }
        var hasTracker: Bool { !(entry?.trackers.isEmpty ?? true) }
        var openCount: Int { items.filter(\.isOpenTask).count }
        var lastActivity: Date? { (items.map(\.updated) + sessions.map(\.started)).max() }

        /// "owner/repo" from the folder's git remote, when it's on GitHub.
        var githubRepo: String? {
            guard let folder, let config = try? String(contentsOf: folder.appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
            for line in config.components(separatedBy: "\n") where line.contains("github.com") && line.contains("url") {
                guard let range = line.range(of: #"github\.com[:/]([^/\s]+)/([^\s]+?)(?:\.git)?\s*$"#, options: .regularExpression) else { continue }
                let path = String(line[range]).replacingOccurrences(of: "github.com:", with: "").replacingOccurrences(of: "github.com/", with: "")
                return path.hasSuffix(".git") ? String(path.dropLast(4)) : path
            }
            return nil
        }
    }

    nonisolated static let inboxID = "__inbox"

    @Published private(set) var inbox = ProjectInfo(id: Library.inboxID, name: "Inbox", folder: nil, items: [], sessions: [])
    @Published private(set) var projects: [ProjectInfo] = []
    @Published private(set) var activeSession: Session?
    /// Shown at the bottom of the dashboard: errors, confirmations, "Deleted · Undo".
    @Published var banner: String?
    /// What the banner's Undo puts back: notes just trashed, and a merged note's text from before the merge.
    @Published private(set) var lastTrashed: [URL] = []
    private var mergeUndo: (original: Item, merged: Item)?
    var canUndo: Bool { !lastTrashed.isEmpty || mergeUndo != nil }
    /// Set to a project id to make the dashboard select it.
    @Published var focusRequest: String?
    /// Set to a note id to make the dashboard select and show it.
    @Published var selectRequest: String?
    @Published private(set) var writingReport: String?

    // Projects and their trackers
    /// Every project Broski knows (projects.json at the notes root).
    @Published private(set) var registry = ProjectRegistry()
    /// Tracker and doc records per notes project, read straight from each project's files.
    @Published private(set) var trackerRecords: [String: [TrackerRecord]] = [:]
    @Published private(set) var readingTrackers = false
    private var trackerWatchers: [String: FileWatcher] = [:]
    private var trackerReads: [String: Task<Void, Never>] = [:]

    // The brain
    /// Every note and session entry, searchable locally.
    @Published private(set) var index = NotesIndex([])
    /// Each project's living page (PROJECT.md).
    @Published private(set) var pages: [String: ProjectPage] = [:]
    /// Projects whose page Claude is rewriting right now.
    @Published private(set) var compiling: Set<String> = []
    @Published private(set) var pageProblem: String?
    /// Whether to keep pages current with Claude, and which projects never go to Claude.
    var brainSettings: () -> (autoCompile: Bool, localOnly: Set<String>) = { (true, []) }
    private var pendingCompiles: Set<String> = []
    /// Each project's notes (not its tracker digest) when Claude last rewrote its page, this session.
    private var compiledNotes: [String: String] = [:]
    private var compileTask: Task<Void, Never>?
    private var compileRunning = false

    let store: ItemStore
    let brain: Brain
    var projectRoots: () -> [URL] = { [] }
    private var folders: [String: URL] = [:]
    private var watcher: FileWatcher?
    private var bannerTask: Task<Void, Never>?

    init(store: ItemStore, brain: Brain) {
        self.store = store
        self.brain = brain
    }

    func startWatching() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: store.projectsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: store.inboxDir, withIntermediateDirectories: true)
        // Broski's own writes (pages, settings, logs) and Finder's .DS_Store change no note, so they don't reload; nor
        // do the conversation, usage, memory and vault files (the conversation has its own refresh).
        let ignored: Set<String> = ["PROJECT.md", "config.json", ".DS_Store"]
        let notNotes = ["/.broski/", "/conversations/", "/usage/", "/memory/", "/vault/", "/evals/"]
        watcher = FileWatcher(url: store.root) { [weak self] paths in
            let notes = paths.filter { path in !notNotes.contains { path.contains($0) } && !ignored.contains((path as NSString).lastPathComponent) }
            if paths.isEmpty || !notes.isEmpty { self?.scheduleReload() }
            if paths.contains(where: { $0.contains("/conversations/") }) { self?.scheduleConversationRefresh() }
        }
        loadRegistry()
        reload()
        refreshFolders()
    }

    private var reloadTask: Task<Void, Never>?
    private var conversationTask: Task<Void, Never>?
    /// The conversation's files changed (your iPhone said something, through iCloud).
    var onConversationsChanged: (() -> Void)?

    private func scheduleConversationRefresh() {
        conversationTask?.cancel()
        conversationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.onConversationsChanged?()
        }
    }

    /// One reload for a burst of file events (a save, iCloud syncing a folder): a reload re-reads every note.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    // MARK: Trackers

    /// Reads projects.json and every tracker and doc folder it names (read-only), and keeps them fresh:
    /// git-backed trackers when their ref moves (checked every minute), folders a while after they change.
    func loadRegistry() {
        registry = ProjectRegistry.load(from: store.root)
        trackerWatchers = [:]
        for entry in registry.projects {
            readTrackers(of: entry)
            for source in Self.sources(of: entry) where TrackerManifest.resolve(for: source, overlays: overlays).readFrom == nil {
                trackerWatchers[source.path] = FileWatcher(url: source.url) { [weak self] _ in
                    self?.dirtyProjects.insert(entry.notes)
                }
            }
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTrackers() }
        }
        Log.info("Registry: \(registry.projects.count) projects, \(registry.projects.reduce(0) { $0 + $1.trackers.count }) trackers")
    }

    var overlays: URL { store.root.appendingPathComponent("trackers", isDirectory: true) }
    private var dirtyProjects = Set<String>()
    private var refreshTimer: Timer?
    private var lastFolderRead: [String: Date] = [:]
    /// The latest read of each tracker: revision, when, how long, any problems.
    @Published private(set) var snapshots: [String: TrackerSnapshot] = [:]

    private func refreshTrackers() {
        for entry in registry.projects {
            let sources = Self.sources(of: entry)
            var moved = false
            #if os(macOS)
            for source in sources {
                let manifest = TrackerManifest.resolve(for: source, overlays: overlays)
                guard let ref = manifest.readFrom, let known = snapshots[source.id]?.revision else { continue }
                let now = GitRef.revision(of: source.url, ref: ref)
                if now != nil, now != known { moved = true }
            }
            #endif
            let folderDue = dirtyProjects.contains(entry.notes) && Date().timeIntervalSince(lastFolderRead[entry.notes] ?? .distantPast) > 120
            if moved || folderDue {
                dirtyProjects.remove(entry.notes)
                readTrackers(of: entry)
            }
        }
    }

    func saveRegistry(_ new: ProjectRegistry) {
        do {
            try new.save(to: store.root)
            loadRegistry()
            reload()
        } catch {
            show("Couldn't save projects.json: \(error.localizedDescription)")
        }
    }

    /// A project's trackers, plus each code folder's docs (never its code).
    nonisolated static func sources(of entry: ProjectRegistry.Entry) -> [TrackerSource] {
        var sources = entry.trackers
        let trackerPaths = entry.trackers.map { $0.url.standardizedFileURL.path }
        for folder in entry.folders {
            let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
            // The tracker folder itself is already read in full.
            if trackerPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            var docs = TrackerSource(id: "\(entry.notes)/\(name)", name: "\(name) docs", path: path, scope: .docs)
            docs.exclude = trackerPaths.filter { $0.hasPrefix(path + "/") }
            sources.append(docs)
        }
        return sources
    }

    func readTrackers(of entry: ProjectRegistry.Entry) {
        trackerReads[entry.notes]?.cancel()
        let sources = Self.sources(of: entry)
        let project = entry.notes
        let overlays = overlays
        let root = store.root
        readingTrackers = true
        lastFolderRead[project] = Date()
        trackerReads[entry.notes] = Task { [weak self] in
            let snaps = await Task.detached(priority: .utility) {
                sources.map { source -> TrackerSnapshot in
                    let snap = TrackerReader.snapshot(source, project: project, overlays: overlays)
                    // What changed since the last read, into Broski's own folder, here off the main thread. Local-only
                    // projects are recorded too: the stream never leaves the Mac, and Claude is never shown theirs.
                    if source.scope == .tracker { ChangeStream.update(with: snap, project: project, root: root) }
                    return snap
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            for snap in snaps {
                self.snapshots[snap.source] = snap
                if !snap.problems.isEmpty { Log.info("Tracker \(snap.source): \(snap.problems.joined(separator: "; "))") }
            }
            self.trackerRecords[project] = snaps.flatMap(\.records)
            self.trackerReads[project] = nil
            self.readingTrackers = !self.trackerReads.isEmpty
            Log.info(String(format: "Read %@: %d records in %.1fs", project, snaps.reduce(0) { $0 + $1.records.count }, snaps.reduce(0) { $0 + $1.seconds }))
            self.reload()
        }
    }

    var allRecords: [TrackerRecord] { trackerRecords.values.flatMap { $0 } }

    /// What changed in the trackers since a date, from Broski's change stream (every project when nil), oldest first.
    func changes(project: String?, since: Date) -> [ChangeEvent] {
        ChangeStream.read(root: store.root, project: project, since: since)
    }

    func record(id: String) -> TrackerRecord? { allRecords.first { $0.id == id } }

    var allProjects: [ProjectInfo] { [inbox] + projects }
    var allItems: [Item] { allProjects.flatMap(\.items) }
    var allSessions: [Session] { allProjects.flatMap(\.sessions).sorted { $0.started > $1.started } }
    var projectNames: [String] { projects.map(\.name) }

    func project(id: String?) -> ProjectInfo? { allProjects.first { $0.id == id } }
    func project(named name: String?) -> ProjectInfo? {
        guard let name else { return inbox }
        return projects.first { $0.name == name }
    }

    func reload() {
        // This read covers any file event still waiting.
        reloadTask?.cancel()
        inbox.items = store.items(in: nil)
        inbox.sessions = store.sessions(in: nil)
        var names = Set(store.projectNames())
        names.formUnion(folders.keys)
        names.formUnion(registry.projects.map(\.notes))
        projects = names.map { name in
            let entry = registry.entry(notes: name)
            let folder = folders[name] ?? entry?.folders.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return ProjectInfo(id: name, name: name, folder: folder, items: store.items(in: name), sessions: store.sessions(in: name),
                               entry: entry, records: trackerRecords[name] ?? [])
        }
        .sorted { a, b in
            switch (a.lastActivity, b.lastActivity) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        activeSession = allSessions.first { $0.isActive }
        // Archived tracker history stays out of everyday answers.
        index = NotesIndex(allItems.map(NoteRef.init) + allSessions.flatMap(NoteRef.entries) + allRecords.filter { !$0.archived }.map(\.noteRef))
        refreshPages()
    }

    // MARK: Living pages

    /// Keeps every project's page in step with its notes: the rules version at once, Claude's a little later.
    private func refreshPages() {
        let settings = brainSettings()
        var fresh: [String: ProjectPage] = [:]
        for project in projects {
            let refs = pageInputs(project.name)
            guard !refs.isEmpty else { continue }
            let fingerprint = ProjectPage.fingerprint(refs)
            let existing = pages[project.name] ?? ProjectPage.load(project.name, from: store)
            if let existing, existing.fingerprint == fingerprint {
                fresh[project.name] = existing
                continue
            }
            let canCompile = settings.autoCompile && brain.hasModel && !settings.localOnly.contains(project.name)
            // The model's page can't be rewritten (no model, auto-compile off, local only): the rules keep it current instead.
            if existing == nil || existing?.source == .rules || !canCompile {
                let page = ProjectPageBuilder.rules(project: project.name, refs: refs, items: project.items, sessions: project.sessions)
                try? page.save(to: store)
                fresh[project.name] = page
            } else {
                // Keep the model's last page on screen until the new one is ready.
                fresh[project.name] = existing
            }
            // The model rewrites a page at most every 6 hours when its notes change, and once a day when only its tracker
            // moved; the rules page above keeps it current in between, and Refresh rewrites it at once.
            if canCompile {
                let notes = ProjectPage.fingerprint(refs.filter { !$0.isTrackerRecord })
                let notesChanged = compiledNotes[project.name].map { $0 != notes } ?? true
                let lastRewrite = existing?.source == .claude ? existing?.compiled : nil
                if ProjectPage.rewriteDue(compiled: lastRewrite, notesChanged: notesChanged) { pendingCompiles.insert(project.name) }
            }
        }
        pages = fresh
        scheduleCompiles(after: 20)
    }

    /// Rewrites a project's page with the model now (the Refresh button).
    func compilePage(_ project: String) {
        pendingCompiles.insert(project)
        scheduleCompiles(after: 0)
    }

    private func scheduleCompiles(after seconds: Double) {
        // A run in progress picks up new work itself; cancelling it would throw away a reply mid-flight.
        guard !pendingCompiles.isEmpty, brain.hasModel, !compileRunning else { return }
        compileTask?.cancel()
        compileTask = Task { [weak self] in
            // Wait for a pause in note-taking, so a burst of captures compiles once.
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.runCompiles()
        }
    }

    private func runCompiles() async {
        compileRunning = true
        defer { compileRunning = false }
        while let name = pendingCompiles.first {
            pendingCompiles.remove(name)
            guard let gateway = brain.gateway, !brainSettings().localOnly.contains(name) else { continue }
            let refs = pageInputs(name)
            guard !refs.isEmpty else { continue }
            compiling.insert(name)
            do {
                var page = try await ProjectPageBuilder.compile(project: name, refs: refs, previous: pages[name], gateway: gateway)
                // A suggestion dismissed (or acted on) while the model was writing stays dismissed.
                let dismissed = pages[name]?.actions.filter(\.dismissed) ?? []
                for i in page.actions.indices {
                    let action = page.actions[i]
                    if dismissed.contains(where: { $0.id == action.id || ($0.kind == action.kind && $0.title.lowercased() == action.title.lowercased()) }) {
                        page.actions[i].dismissed = true
                    }
                }
                try page.save(to: store)
                pages[name] = page
                compiledNotes[name] = ProjectPage.fingerprint(refs.filter { !$0.isTrackerRecord })
                pageProblem = nil
                Log.info("Living page updated: \(name)")
            } catch {
                pageProblem = error.localizedDescription
                Log.info("Living page for \(name) not updated: \(error.localizedDescription)")
            }
            compiling.remove(name)
        }
    }

    /// Shows a page as it is (used by snapshots and tests).
    func usePage(_ page: ProjectPage) {
        pages[page.project] = page
    }

    /// What a project's living page is written from: its notes, plus a digest of its tracker (open decisions,
    /// open crit/high findings, recent decisions, unread messages, open tasks). Not every tracker record: the
    /// page shouldn't be rewritten each time a thread pushes.
    func pageInputs(_ project: String) -> [NoteRef] {
        let notes = index.refs.filter { $0.project == project && !$0.isTrackerRecord }
        let records = (trackerRecords[project] ?? []).filter { !$0.archived && !$0.lowTrust }
        let fortnight = Date().addingTimeInterval(-14 * 86_400)
        let rank = ["crit": 0, "high": 1]
        var digest: [TrackerRecord] = []
        digest += records.filter { $0.kind == "decision" && $0.open }
        digest += records.filter { ($0.kind == "finding" || $0.kind == "ops") && $0.open && rank[$0.severity] != nil }
            .sorted { (rank[$0.severity] ?? 9, $1.date ?? .distantPast) < (rank[$1.severity] ?? 9, $0.date ?? .distantPast) }.prefix(25)
        digest += records.filter { $0.kind == "decision" && !$0.open && ($0.fields["decidedAt"].flatMap(TrackerReader.parseDateString) ?? .distantPast) >= fortnight }.prefix(15)
        digest += records.filter { $0.kind == "message" && $0.canonical == .unread }.prefix(10)
        digest += records.filter { $0.kind == "task" && $0.open }.prefix(20)
        // The digest's fingerprint ignores re-read dates, so only real changes (status, new items) rewrite the page.
        return notes + digest.map { record in
            var ref = record.noteRef
            ref.date = record.fields["decidedAt"].flatMap(TrackerReader.parseDateString) ?? record.fields["opened"].flatMap(TrackerReader.parseDateString) ?? .distantPast
            return ref
        }
    }

    func dismissAction(_ action: ProposedAction, in project: String) {
        guard var page = pages[project], let i = page.actions.firstIndex(where: { $0.id == action.id }) else { return }
        page.actions[i].dismissed = true
        pages[project] = page
        try? page.save(to: store)
    }

    // MARK: Asking

    func ask(_ question: String) async throws -> Ask.Answer {
        let localOnly = brainSettings().localOnly
        let briefing = await briefing(for: question, localOnly: localOnly)
        return try await Ask.answer(question, index: index, catalog: catalog, pages: Array(pages.values),
                                    gateway: brain.gateway, localOnly: localOnly, briefing: briefing, limit: 18)
    }

    /// What search alone can't find: what's waiting on the user, what changed, and live readings from a tracker's
    /// board (with their time), for the questions that need them.
    func briefing(for question: String, localOnly: Set<String>) async -> String {
        let q = question.lowercased()
        let project = catalog.mentioned(in: question)?.name
        // A local-only project's records, board readings and commits never go to Claude, so don't even gather them.
        if let project, localOnly.contains(project) { return "" }
        let records = allRecords.filter { !localOnly.contains($0.project) && (project == nil || $0.project == project) }
        let notes = allItems.filter { !localOnly.contains($0.project ?? "") && (project == nil || $0.project == project) }
        var parts: [String] = []
        let waitingWords = ["waiting", "on me", "my plate", "left", "next", "need from me", "due", "my turn", "blocked", "todo", "to do", "open", "pending", "forget"]
        let wantsWaiting = waitingWords.contains(where: q.contains)
        // Projects whose board is up: their step readiness comes from the board, not from a list of every step.
        var boardsUp = Set<String>()
        var liveBlocks: [String] = []
        let liveWords = ["waiting", "left", "next", "ready", "done", "live", "price", "fresh", "deployed", "serving", "vetted", "status", "launch", "now", "state", "health"]
        if wantsWaiting || liveWords.contains(where: q.contains) {
            for entry in registry.projects where !localOnly.contains(entry.notes)
                && (project == nil ? entry.trackers.contains(where: { $0.board != nil }) : entry.notes == project) {
                for source in entry.trackers {
                    let manifest = TrackerManifest.resolve(for: source, overlays: overlays)
                    guard let url = manifest.board?.url ?? source.board, let board = TrackerBoard(url) else { continue }
                    let check = await board.handshake(expecting: snapshots[source.id]?.revision)
                    guard check.ok else {
                        liveBlocks.append("\(source.name)'s board: \(check.note). Its live state (which steps are ready or done, readings) is unknown; say so.")
                        continue
                    }
                    boardsUp.insert(entry.notes)
                    var paths = ["/api/now", "/api/next?deployment=launch"]
                    if ["price", "fresh", "health", "reading", "deployed", "serving"].contains(where: q.contains) { paths.append("/api/state") }
                    for path in paths {
                        liveBlocks.append(TrackerBoard.describe(await board.get(path), label: "\(source.name) \(path)"))
                    }
                }
            }
        }
        if wantsWaiting {
            let order = ["decision": 0, "task": 1, "todo": 1, "note": 2, "step": 3]
            let lines = WaitingOn.lines(records: records, notes: notes)
                .filter { !($0.kind == "step" && boardsUp.contains($0.project)) }
                .sorted { (order[$0.kind] ?? 4, $0.project) < (order[$1.kind] ?? 4, $1.project) }
            var perProject: [String: Int] = [:]
            let kept = lines.filter { line in
                perProject[line.project, default: 0] += 1
                return perProject[line.project]! <= (line.kind == "step" ? 12 : 25)
            }
            if !kept.isEmpty {
                parts.append("Waiting on the user, from the files (decisions they decide, tasks and notes that are theirs"
                             + (boardsUp.isEmpty ? "; launch steps listed with state unknown because no board is up" : "; launch step readiness is in the board blocks below") + "):\n"
                             + kept.map { "- [\($0.project)] \($0.text) [[\($0.cite)]]" + ($0.stateFromFiles ? "" : " (state unknown: live)") }.joined(separator: "\n"))
            }
        }
        if ["thread", "remark", "inbox", "quiet", "unread", "who hasn't", "agents", "silent", "idle"].contains(where: q.contains) {
            let unread = WaitingOn.unread(records: records)
            if !unread.isEmpty {
                let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                parts.append("Unread messages between threads (from the tracker's message log; the tracker's own status command is authoritative):\n"
                             + unread.map { group in
                                "- \(group.project) \(group.thread): \(group.ids.count) unread\n" + group.ids.prefix(12).map { id in
                                    let r = byID[id]
                                    return "  - [[\(id)]] \(r?.date.map { ISO8601DateFormatter().string(from: $0) } ?? "") from \(r?.fields["by"] ?? "?"): \(r?.title.prefix(220) ?? "")"
                                }.joined(separator: "\n")
                             }.joined(separator: "\n"))
            }
            #if os(macOS)
            // Each thread's latest commit, from the `Agent:` trailer.
            for entry in registry.projects where !localOnly.contains(entry.notes) && (project == nil || entry.notes == project) {
                for source in entry.trackers where source.scope == .tracker {
                    guard let ref = TrackerManifest.resolve(for: source, overlays: overlays).readFrom else { continue }
                    let commits = Journal.commits(repo: source.url, ref: ref, since: Date().addingTimeInterval(-30 * 86_400), project: entry.notes)
                    let byThread = Dictionary(grouping: commits.filter { $0.thread != nil }, by: { $0.thread! })
                    guard !byThread.isEmpty else { continue }
                    let week = Date().addingTimeInterval(-7 * 86_400)
                    parts.append("\(source.name): each thread's activity from commit trailers (last 30 days):\n" + byThread.map { thread, list in
                        let latest = list.max { $0.at < $1.at }!
                        return "- \(thread): \(list.count) commits in 30 days, \(list.filter { $0.at >= week }.count) in the last 7; latest \(ISO8601DateFormatter().string(from: latest.at)) \(latest.text.prefix(120))"
                    }.sorted().joined(separator: "\n"))
                }
            }
            #endif
        }
        // Questions about findings get the register itself: search alone surfaces a handful, never the whole picture.
        if ["finding", "critical", "crit ", "high", "severity", "audit", "vulnerab", "security", "risk", "issues"].contains(where: q.contains) {
            parts += findingsDigest(records)
        }
        // "What did I note that isn't in the tracker": each open note line beside its closest tracker records,
        // so both sides of a mismatch can be cited.
        if ["note", "my notes", "i wrote", "i said", "captured"].contains(where: q.contains),
           ["tracker", "out of date", "stale", "isn't in", "not in", "missing", "outdated", "drift"].contains(where: q.contains) {
            if let block = notesAgainstTracker(notes: notes, records: records) { parts.append(block) }
        }
        if let since = Journal.range(in: question) {
            var entries = Journal.entries(records: records, notes: notes, since: since)
            #if os(macOS)
            for entry in registry.projects where !localOnly.contains(entry.notes) && (project == nil || entry.notes == project) {
                for source in Self.sources(of: entry) where source.scope == .tracker {
                    if let ref = TrackerManifest.resolve(for: source, overlays: overlays).readFrom {
                        entries += Journal.commits(repo: source.url, ref: ref, since: since, project: entry.notes)
                    }
                }
            }
            #endif
            // Reopenings, status moves and attestations the records' own dates can't show, from the change stream.
            // What the records already date (filed, closed, decided, a remark) isn't listed twice.
            let dated = Set(entries.compactMap { e in e.cite.map { (e.kind == "opened" || e.kind == "remark" ? "new" : e.kind) + " " + $0 } })
            entries += changes(project: project, since: since)
                .filter { !localOnly.contains($0.project) && !dated.contains($0.kind + " " + $0.id) }
                .map(\.journalEntry)
            entries.sort { $0.at > $1.at }
            if !entries.isEmpty {
                parts.append("What changed since \(TrackerReader.dayFormatter.string(from: since)) (dates are UTC unless stated; commits show the thread that made them; "
                             + "status, reopened, attested and removed lines are Broski comparing one read of the tracker with the next):\n"
                             + entries.prefix(120).map { e in
                                "- \(ISO8601DateFormatter().string(from: e.at)) [\(e.project)] \(e.kind)\(e.thread.map { " by \($0)" } ?? ""): \(e.text)" + (e.cite.map { " [[\($0)]]" } ?? "")
                             }.joined(separator: "\n"))
            }
        }
        parts += liveBlocks
        return parts.joined(separator: "\n\n")
    }

    /// Per project: open findings by severity (as filed), then every open crit and high with what it says,
    /// flagging ones fixed on a branch but still open.
    func findingsDigest(_ records: [TrackerRecord]) -> [String] {
        let order = ["crit", "high", "med", "low", "info"]
        let findings = records.filter { $0.section == .findings && !$0.archived && $0.open && !["task", "todo", "decision", "message"].contains($0.kind) }
        return Dictionary(grouping: findings, by: \.project).sorted { $0.value.count > $1.value.count }.map { project, open in
            let counts = order.compactMap { level -> String? in
                let n = open.filter { $0.severity == level }.count
                return n == 0 ? nil : "\(n) \(level)"
            } + [open.filter { !order.contains($0.severity) }.count].filter { $0 > 0 }.map { "\($0) unrated" }
            let read = Set(open.map(\.source)).compactMap { snapshots[$0] }.map { snap in
                "\(snap.source) " + (snap.revision.map { "at \($0.prefix(7))" } ?? "working tree") + ", read \(ISO8601DateFormatter().string(from: snap.readAt))"
            }.joined(separator: "; ")
            let serious = open.filter { ["crit", "high"].contains($0.severity) }
                .sorted { (order.firstIndex(of: $0.severity) ?? 9, $1.date ?? .distantPast) < (order.firstIndex(of: $1.severity) ?? 9, $0.date ?? .distantPast) }
            let lines = serious.prefix(60).map { r -> String in
                var line = "- [[\(r.id)]] \(r.severity) · \(r.status)"
                if let opened = r.fields["opened"] { line += " · opened \(opened)" } else { line += " · no opened date" }
                if let owner = r.fields["owner_thread"] { line += " · \(owner)" }
                if let fixed = r.fields["fixed_on"] { line += " · fixed on \(fixed) but still open" }
                line += ": \(r.title.prefix(140))"
                let gist = (r.summary.isEmpty ? r.body : r.summary).replacingOccurrences(of: "\n", with: " ")
                if !gist.isEmpty { line += " — " + gist.prefix(220) }
                return line
            }
            return "Open findings in \(project)'s register (\(read)): \(open.count) open: \(counts.joined(separator: ", ")). "
                + "Only the tracker's own open status counts; severity is as filed. "
                + (serious.count > 60 ? "Showing 60 of \(serious.count) crit/high. " : "") + "Every open crit and high:\n"
                + lines.joined(separator: "\n")
        }
    }

    /// Each open note's lines with the tracker records that best match them, for spotting notes that are done,
    /// overtaken, or not in the tracker at all.
    func notesAgainstTracker(notes: [Item], records: [TrackerRecord]) -> String? {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for note in notes.filter({ $0.status != .done && $0.project != nil }).sorted(by: { $0.updated > $1.updated }).prefix(12) {
            // The title, then each bullet or line of the body: a note often holds several todos.
            let pieces = ([note.title] + note.body.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*•[]x\t")) }
                .filter { $0.count > 12 }).prefix(8)
            var lines: [String] = []
            for piece in pieces {
                let hits = index.search(piece, project: note.project, limit: 12).filter { $0.ref.isTrackerRecord }.prefix(2)
                let matched = hits.compactMap { hit -> String? in
                    guard let r = byID[hit.ref.id] else { return nil }
                    // Step state is live, but an attestation in the file is evidence of what was done and when.
                    let attested = r.fields["attested"].flatMap { Data($0.utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .map { "attested \($0["at"] as? String ?? "?") by \($0["by"] as? String ?? "?")" }
                    let state = attested ?? (r.canonical == .live ? "state live" : r.status)
                    return "[[\(r.id)]] \(r.kind)\(state.isEmpty ? "" : " (\(state))"): \(r.title.prefix(100))"
                }
                lines.append("  - “\(piece.prefix(140))” → " + (matched.isEmpty ? "no close tracker record" : matched.joined(separator: " | ")))
            }
            out.append("- Note [[\(note.id)]] (\(note.kind.rawValue), \(note.project ?? "inbox"), updated \(TrackerReader.dayFormatter.string(from: note.updated))):\n" + lines.joined(separator: "\n"))
        }
        guard !out.isEmpty else { return nil }
        return "Your open notes beside the closest tracker records (a match is a lead to check, not proof; an attestation is evidence a step was done; cite both sides of any mismatch, and suggest marking a note done rather than doing it):\n" + out.joined(separator: "\n")
    }

    func item(id: String) -> Item? { allItems.first { $0.id == id } }
    func session(forRef id: String) -> Session? {
        // "<session id>#<entry>": the entry number follows the last "#".
        guard let hash = id.lastIndex(of: "#") else { return nil }
        let sessionID = String(id[..<hash])
        return allSessions.first { $0.id == sessionID }
    }

    /// Code folders under the project roots. Scanning can wait on a privacy prompt, so it runs off the main thread.
    func refreshFolders() {
        let roots = projectRoots()
        let notes = store.projectsDir
        Task.detached(priority: .userInitiated) { [weak self] in
            let catalog = ProjectCatalog.discover(roots: roots, notesDir: notes)
            var found: [String: URL] = [:]
            for project in catalog.projects { if let folder = project.folder { found[project.name] = folder } }
            await self?.useFolders(found)
        }
    }

    private func useFolders(_ found: [String: URL]) {
        folders = found
        reload()
    }

    /// Projects for voice routing: code folders and note folders.
    var catalog: ProjectCatalog {
        // Real names and old names both route to the notes project ("SAI" and "ROOK" → rook).
        var all = projects.map { Project(name: $0.name, folder: $0.folder) }
        for entry in registry.projects {
            for alias in [entry.name] + entry.aliases where TextTools.matchKey(alias) != TextTools.matchKey(entry.notes) {
                all.append(Project(name: entry.notes, folder: nil, spoken: alias))
            }
        }
        return ProjectCatalog(projects: all)
    }

    // MARK: Editing

    /// False when the write failed (the banner says why), so an editor knows its text isn't on disk.
    @discardableResult
    func save(_ item: Item) -> Bool {
        var saved = false
        perform { _ = try store.save(item); saved = true }
        return saved
    }

    func setStatus(_ item: Item, _ status: ItemStatus) {
        guard item.status != status else { return }
        update(item) { $0.status = status }
    }

    /// Changes a field (status, type, priority) on the note as it is on disk, not on this cached copy,
    /// so what the other device wrote since it loaded survives.
    func update(_ item: Item, _ change: (inout Item) -> Void) {
        perform { _ = try store.update(item, change) }
    }

    func delete(_ item: Item) {
        flushEditors()
        let item = latest(item)
        perform {
            lastTrashed = [try store.delete(item)]
            mergeUndo = nil
            show("Deleted “\(item.title.prefix(40))”")
        }
    }

    /// Folds `rest` into `keep`, then trashes them. One Undo brings them all back and `keep` as it was.
    func merge(_ rest: [Item], into keep: Item) throws {
        // Fold in and trash what an open inspector shows, typing included, not the copy on disk before it.
        flushEditors()
        let keep = latest(keep), rest = rest.map { latest($0) }
        let text = rest.map { "**\($0.title)**" + ($0.body.isEmpty ? "" : "\n\n\($0.body)") }.joined(separator: "\n\n")
        let merged = try store.addMore(to: keep, text: text, files: rest.flatMap(\.attachmentURLs))
        var trashed: [URL] = []
        var failure: Error?
        for item in rest {
            do { trashed.append(try store.delete(item)) } catch { failure = error; break }
        }
        show(failure.map { "Merged, but couldn't trash every note: \($0.localizedDescription)" }
             ?? "Merged \(rest.count) into “\(keep.title.prefix(40))”")
        lastTrashed = trashed
        mergeUndo = (keep, merged)
        reload()
        // Not thrown: the text is already in `keep`, so a retry would add it twice. The banner reports it.
    }

    func undoDelete() {
        let trashed = lastTrashed, merge = mergeUndo
        guard !trashed.isEmpty || merge != nil else { return }
        lastTrashed = []
        mergeUndo = nil
        banner = nil
        perform {
            for url in trashed { try store.restore(url) }
            // Put the merged note back only if nothing changed it since, so later edits aren't undone too.
            let file = merge?.merged.file.standardizedFileURL
            if let merge, let now = allItems.first(where: { $0.file.standardizedFileURL == file }), now.body == merge.merged.body {
                try store.save(merge.original)
                // The merge copied the other notes' files in; their originals came back with the notes.
                for path in Set(merge.merged.attachments).subtracting(merge.original.attachments) {
                    try? FileManager.default.removeItem(at: merge.original.folder.appendingPathComponent(path))
                }
            }
        }
    }

    func move(_ item: Item, to project: String?) {
        flushEditors()
        let item = latest(item)
        perform {
            try store.move(item, to: project)
            show("Moved to \(project ?? "Inbox")")
        }
    }

    func attach(_ files: [URL], to item: Item) {
        perform { _ = try store.attach(files, to: item) }
    }

    /// A typed note. Without a project, the text decides where it goes, like a spoken note would.
    func add(_ text: String, to project: ProjectInfo?, kind: NoteKind?) {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let rules = Brain.rules(raw, catalog: catalog, activeSession: nil)
        let target = project.map { $0.isInbox ? nil : $0.name } ?? (rules.project.isEmpty ? nil : rules.project)
        let draft = ItemDraft(project: target ?? nil, kind: kind ?? NoteKind(rawValue: rules.kind) ?? .note,
                              title: rules.title.isEmpty ? raw : rules.title, body: rules.body)
        perform { try store.create(draft) }
    }

    @discardableResult
    func createProject(named name: String) -> String? {
        var made: String?
        perform { made = try store.createProject(named: name) }
        return made
    }

    // MARK: Sessions

    func endSession(_ session: Session) {
        perform { _ = try store.endSession(session) }
    }

    /// Writes report.md with the everyday model (screenshots included, when it reads images) or, without one, as a plain list.
    func writeReport(for session: Session) async {
        writingReport = session.id
        defer { writingReport = nil }
        // A local-only project's entries and screenshots never go to a cloud model, report included.
        if let project = session.project, brainSettings().localOnly.union(brain.localOnly()).contains(project) {
            try? store.writeReport(ReportWriter.basic(session), for: session)
            show("Plain report written: \(project) is local only.")
        } else if brain.hasModel {
            do {
                let report = try await brain.report(for: session)
                try store.writeReport(report.reportMarkdown, for: session)
                pendingIssues[session.id] = report.issues
                show(report.issues.isEmpty ? "Report written" : "Report written with \(report.issues.count) issues")
            } catch {
                try? store.writeReport(ReportWriter.basic(session), for: session)
                show("The model couldn't write it (\(error.localizedDescription)), so this is a plain report.")
            }
        } else {
            try? store.writeReport(ReportWriter.basic(session), for: session)
            show("Plain report written. Choose a model in Settings › Models for a full write-up.")
        }
        reload()
    }

    /// Issues found by the last report for each session, ready to add to the board.
    @Published var pendingIssues: [String: [SessionReport.Issue]] = [:]

    func addIssuesToBoard(from session: Session) {
        guard let issues = pendingIssues[session.id], !issues.isEmpty else { return }
        perform {
            for issue in issues {
                let shot = issue.screenshot.isEmpty ? [] : [session.folder.appendingPathComponent(issue.screenshot)]
                let priority: Priority = issue.severity == "critical" ? .urgent : issue.severity == "high" ? .high : issue.severity == "low" ? .low : .normal
                try store.create(ItemDraft(project: session.project, kind: .bug, priority: priority, tags: [session.kind.rawValue],
                                           title: issue.title, body: issue.details + "\n\nFrom \(session.title).",
                                           attachments: shot.filter { FileManager.default.fileExists(atPath: $0.path) }))
            }
            show("Added \(issues.count) bugs to \(session.project ?? "the inbox")")
        }
        pendingIssues[session.id] = nil
    }

    // MARK: Helpers

    /// Open inspectors' save-now closures. A note trashed, moved or merged away under an inspector
    /// would otherwise take the typing still waiting for its debounce with it.
    private var editors: [UUID: () -> Void] = [:]
    func registerEditor(_ id: UUID, flush: @escaping () -> Void) { editors[id] = flush }
    func unregisterEditor(_ id: UUID) { editors[id] = nil }
    private func flushEditors() { editors.values.forEach { $0() } }

    /// The newest copy of a note, matched by file: a flush may have just rewritten it.
    private func latest(_ item: Item) -> Item {
        let file = item.file.standardizedFileURL
        return allItems.first { $0.file.standardizedFileURL == file } ?? item
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            show(error.localizedDescription)
        }
        reload()
    }

    func show(_ message: String) {
        banner = message
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.banner = nil
            self.lastTrashed = []
            self.mergeUndo = nil
        }
    }
}
