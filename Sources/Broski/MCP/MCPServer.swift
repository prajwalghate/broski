import BroskiCore
import Foundation

/// `Broski --mcp`: a Model Context Protocol server over stdio, so Claude Code (or Claude Desktop) can read your
/// Broski notes: project pages, search, open bugs and todos, trackers and what changed in them. It reads everything
/// in place; the only writes are tracker_add and tracker_set_status, and only to trackers Broski owns (never a
/// project's own tracker, never a local-only project).
@MainActor
enum MCPServer {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() {
        var store = ItemStore(root: AppModel.notesRoot)
        brain = Brain(store: store)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            guard let message = json as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request: send one JSON-RPC object per line"]])
                continue
            }
            let id = message["id"]
            let method = message["method"] as? String ?? ""
            let params = message["params"] as? [String: Any] ?? [:]
            // Notifications (no id) need no reply.
            guard let id else { continue }
            // Notes moved (to iCloud, another folder) while this server runs: follow them.
            if AppModel.notesRoot.standardizedFileURL != store.root.standardizedFileURL {
                store = ItemStore(root: AppModel.notesRoot)
                brain = Brain(store: store)
            }
            switch method {
            case "initialize":
                let asked = params["protocolVersion"] as? String ?? ""
                reply(id, [
                    "protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "broski", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                    "instructions": """
                    Broski is the user's memory across all their projects. It holds their captured notes (bugs, todos, ideas, \
                    QA observations, riffs, calls) and reads each project's own tracker in place (findings, decisions, \
                    launch steps, runbooks, threads, messages) without copying it; the trackers are the source of truth. \
                    Start with list_projects, then get_project_page or tracker_query for the project you're in; \
                    waiting_on for what needs the user; journal and changes_since for what changed; search_notes and get_record \
                    for detail; tracker_health for whether Broski's map of a tracker still fits. tracker_add and tracker_set_status \
                    write only to trackers Broski keeps; a project's own tracker is changed by its threads, never through Broski. \
                    Note ids look like 2026-10-16-0452-login-bug; tracker record ids are namespaced: one:DEC-70, strado:T-15. \
                    Launch step state is live-only (the tracker's board); never state it from these records.
                    """,
                ])
            case "ping":
                reply(id, [:])
            case "tools/list":
                reply(id, ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                guard tools.contains(where: { $0["name"] as? String == name }) else {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool: \(name)"]])
                    continue
                }
                let args = params["arguments"] as? [String: Any] ?? [:]
                let (text, isError) = call(name, args, store: store)
                reply(id, ["content": [["type": "text", "text": text]], "isError": isError])
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    private static func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: Tools

    static let tools: [[String: Any]] = [
        tool("list_projects", "List every project Broski knows: real name, code folders, trackers, open counts per core section, and the one-line summary.", [:], []),
        tool("tracker_query", "Records from a project's tracker, filtered. Sections: ship, launch, ops, decisions, threads, findings, layer.",
             ["project": ["type": "string"], "section": ["type": "string", "enum": CoreSection.allCases.map(\.rawValue)],
              "kind": ["type": "string", "description": "finding, decision, step, runbook, thread, message, lesson, task, doc…"],
              "status": ["type": "string", "enum": ["open", "all", "closed"]], "owner": ["type": "string"],
              "limit": ["type": "integer", "minimum": 1, "maximum": 200]], ["project"]),
        tool("get_record", "One tracker record or note in full, by id (e.g. one:ONE-X189, strado:DEC-14, or a note id).",
             ["id": ["type": "string"], "include_transcript": ["type": "boolean", "description": "For call notes: include the full transcript"]], ["id"]),
        tool("waiting_on", "What is waiting on the user across projects (decisions they decide, their tasks and notes, their launch steps), plus unread messages between threads. Step readiness is live-only: check the tracker's board.",
             ["project": ["type": "string"]], []),
        tool("journal", "What changed: decisions made, findings opened and closed, messages, notes, and commits (with the thread that made them).",
             ["days": ["type": "integer", "minimum": 1, "maximum": 60], "project": ["type": "string"]], []),
        tool("changes_since", "What changed in the trackers between Broski's reads: records new, closed, reopened, re-statused, decided, attested or removed, each with its record id. Default: the last day.",
             ["project": ["type": "string"], "days": ["type": "integer", "minimum": 1, "maximum": 60],
              "since": ["type": "string", "description": "An ISO date or time (2026-10-20, 2026-10-20T09:00:00Z); overrides days"]], []),
        tool("tracker_health", "Whether Broski's map of a project's tracker still fits: files no source reads, mappings that find nothing, unknown status words, threads no onboarding run has asked, and the latest run.",
             ["project": ["type": "string"]], ["project"]),
        tool("tracker_add", "Add a task, bug, risk, finding, idea or decision to the tracker Broski keeps for a project. Refused for a project's own tracker (ask its thread) and local-only projects. Returns the new id.",
             ["project": ["type": "string"], "kind": ["type": "string", "enum": ["task", "bug", "risk", "finding", "idea", "decision"]],
              "title": ["type": "string", "description": "For a decision: the question to decide"], "body": ["type": "string"],
              "severity": ["type": "string", "enum": ["crit", "high", "med", "low", "info"]]], ["project", "kind", "title"], readOnly: false),
        tool("tracker_set_status", "Change an item's status in the tracker Broski keeps for a project (a decision is closed as decided, with the answer as note). Refused for a project's own tracker and local-only projects.",
             ["project": ["type": "string"], "id": ["type": "string", "description": "e.g. BUG-3 or trader:BUG-3"],
              "status": ["type": "string", "enum": ["open", "doing", "blocked", "done", "wontfix", "decided", "superseded"]],
              "note": ["type": "string", "description": "A resolution, or a decision's answer"]], ["project", "id", "status"], readOnly: false),
        tool("check_onboarding", "Check an onboarding run's answers: every evidence ref and quote verified against the files, git and transcripts. Pass the run folder, or a project to list its runs.",
             ["run": ["type": "string", "description": "The run folder (projects/<p>/onboarding/<run>)"], "project": ["type": "string"],
              "only": ["type": "string", "description": "Only this thread's answers"]], []),
        tool("get_project_page", "The living page for a project: where it stands, open bugs, todos, ideas, decisions, open questions and suggested actions, each line citing note ids, with when it was written.",
             ["project": ["type": "string", "description": "Project name, e.g. strado"]], ["project"]),
        tool("search_notes", "Search all notes, session observations and tracker records. Returns the best matches with ids and snippets.",
             ["query": ["type": "string"], "project": ["type": "string", "description": "Optional: only this project, or \"inbox\""],
              "limit": ["type": "integer", "minimum": 1, "maximum": 30]], ["query"]),
        tool("get_note", "The full markdown of one note (or one session observation, with its screenshots), by id.",
             ["id": ["type": "string"], "include_transcript": ["type": "boolean", "description": "For call notes: include the full transcript"]], ["id"]),
        tool("list_open_items", "Open bugs, todos or ideas, highest priority first.",
             ["project": ["type": "string", "description": "Optional: a project, or \"inbox\""], "kind": ["type": "string", "enum": ["bug", "todo", "idea", "note"]]], []),
        tool("recent_notes", "Notes captured in the last few days, newest first.",
             ["days": ["type": "integer", "minimum": 1, "maximum": 90], "project": ["type": "string", "description": "Optional: a project, or \"inbox\""]], []),
        tool("search_conversations", "Search what the user and Broski said in the home conversation (every device), newest first among the best matches.",
             ["query": ["type": "string"], "project": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 30]], ["query"]),
        tool("decisions", "Decisions the user saved, with dates: the ones standing now, and the ones a later decision replaced.",
             ["project": ["type": "string", "description": "Optional: one project; default all"]], []),
        tool("memory", "What Broski knows about the user: their about-you file and what they asked Broski to remember.", [:], []),
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String],
                             readOnly: Bool = true) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any],
            // The writers only add or change items in a tracker Broski owns: nothing is deleted or overwritten.
            "annotations": (readOnly ? ["readOnlyHint": true, "openWorldHint": false]
                            : ["readOnlyHint": false, "destructiveHint": false, "openWorldHint": false]) as [String: Any],
        ]
    }

    /// Everything the tools read. Trackers are re-read when older than two minutes; the local-only list on every call,
    /// so a project just marked local only is hidden at once.
    @MainActor final class Brain {
        let store: ItemStore
        private var loaded: Date?
        private(set) var registry = ProjectRegistry()
        private(set) var records: [TrackerRecord] = []
        /// Each source's latest read, for its drift.
        private(set) var snapshots: [String: TrackerSnapshot] = [:]
        private(set) var localOnly: Set<String> = []

        init(store: ItemStore) { self.store = store }

        func refresh() {
            readLocalOnly()
            guard loaded.map({ Date().timeIntervalSince($0) > 120 }) ?? true else { return }
            loaded = Date()
            registry = ProjectRegistry.load(from: store.root)
            readLocalOnly()
            let overlays = store.root.appendingPathComponent("trackers")
            let snaps = registry.projects.filter { !localOnly.contains($0.notes) }.flatMap { entry in
                Library.sources(of: entry).map { TrackerReader.snapshot($0, project: entry.notes, overlays: overlays) }
            }
            snapshots = Dictionary(snaps.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
            records = snaps.flatMap(\.records)
        }

        /// After a write: the next call reads the trackers again instead of waiting out the two minutes.
        func invalidate() { loaded = nil }

        /// Read-only: never create or rewrite the config from here. A config.json that's there but won't parse, or
        /// that iCloud hasn't downloaded yet, counts every project as local only, so nothing slips out meanwhile.
        private func readLocalOnly() {
            localOnly = BroskiConfig.localOnly(root: store.root) { store.projectNames() + registry.projects.map(\.notes) }
            if let data = try? Data(contentsOf: store.root.appendingPathComponent("config.json")),
               let config = try? JSONDecoder().decode(BroskiConfig.self, from: data) { WaitingOn.ownerAliases = config.ownerAliases }
        }
    }
    static var brain: Brain!

    /// Which notes a tool looks at: every project, the inbox, or one project.
    enum Scope: Equatable {
        case all, inbox, project(String)

        func contains(_ project: String?) -> Bool {
            switch self {
            case .all: return true
            case .inbox: return project == nil
            case .project(let name): return project == name
            }
        }

        var name: String? { if case .project(let name) = self { return name } else { return nil } }
    }

    /// Long outputs (call notes with their transcript) stay within what Claude Code shows.
    static let outputCap = 40_000

    static func capped(_ text: String) -> String {
        text.count <= outputCap ? text : String(text.prefix(outputCap)) + "\n…truncated, \(text.count - outputCap) more characters."
    }

    /// Call notes keep their transcript in a <details> block: left out unless asked for.
    static func withoutTranscript(_ text: String) -> String {
        text.replacingOccurrences(of: #"<details>[\s\S]*?</details>"#, with: "(Transcript left out; pass include_transcript: true for it.)", options: .regularExpression)
    }

    static func call(_ name: String, _ args: [String: Any], store: ItemStore) -> (String, Bool) {
        // A notes folder macOS won't let this process read must say so, not look empty.
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        } catch {
            return ("Can't read Broski's notes at \(store.root.path): \(error.localizedDescription). Allow the app running Claude Code in System Settings › Privacy & Security › Files and Folders.", true)
        }
        brain.refresh()
        let localOnly = brain.localOnly
        let records = brain.records.filter { !localOnly.contains($0.project) }
        let registry = brain.registry
        let items = store.allItems().filter { !localOnly.contains($0.project ?? "") }
        let sessions = store.allSessions().filter { !localOnly.contains($0.project ?? "") }
        let projects = Array(Set(store.projectNames() + registry.projects.map(\.notes))).filter { !localOnly.contains($0) }.sorted()
        let catalog = ProjectCatalog(projects: projects.map { Project(name: $0) })
        /// nil when a project was named that Broski doesn't know (or that's local only).
        func scope(_ value: Any?) -> Scope? {
            guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return .all }
            if raw.lowercased() == "inbox" { return .inbox }
            let name = registry.entry(named: raw)?.notes ?? catalog.match(raw)?.name
            guard let name, projects.contains(name) else { return nil }
            return .project(name)
        }
        func unknown(_ value: Any?) -> (String, Bool) {
            ("No project called “\(value as? String ?? "")”. Projects: \(projects.joined(separator: ", ")), or inbox.", true)
        }
        func more(_ total: Int, _ shown: Int) -> String { total > shown ? "\n…and \(total - shown) more; narrow by project or kind." : "" }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        func line(_ item: Item) -> String {
            "- [\(item.id)] \(item.kind.rawValue)\(item.priority >= .high ? " (\(item.priority.rawValue))" : "") · \(item.status.rawValue) · \(day.string(from: item.updated)) · \(item.project ?? "Inbox"): \(item.title)"
        }
        let includeTranscript = args["include_transcript"] as? Bool ?? false
        /// The tracker Broski keeps for a project, or why it may not write there. TrackerTemplate.owned is the hard
        /// check: inside Broski's own projects folder, with its TRACKER.md.
        func keptTracker(_ project: String) -> (tracker: TrackerSource?, refusal: String) {
            guard !localOnly.contains(project) else { return (nil, "That project is local-only.") }
            let entry = registry.entry(notes: project)
            if let tracker = entry?.trackers.first(where: { !$0.readOnly && TrackerTemplate.owned($0.url, root: store.root) }) { return (tracker, "") }
            if let entry, !entry.trackers.isEmpty { return (nil, "\(entry.name)'s tracker is the project's own; Broski never writes to it. Ask its thread.") }
            return (nil, "\(entry?.name ?? project) has no tracker Broski keeps. Create one in the dashboard: Tracker › Onboard › Create a Broski tracker.")
        }

        switch name {
        case "list_projects":
            let rows = projects.map { name -> String in
                let entry = registry.entry(notes: name)
                let open = items.filter { $0.project == name && $0.status != .done }
                let count = { (kind: NoteKind) in open.filter { $0.kind == kind }.count }
                let summary = ProjectPage.load(name, from: store)?.summary ?? entry?.about ?? ""
                var row = "- \(entry?.name ?? name) (id \(name)\(entry.map { $0.kind == .personal ? ", personal" : "" } ?? "")): notes \(count(.bug)) bugs, \(count(.todo)) todos, \(count(.idea)) ideas open"
                let mine = records.filter { $0.project == name && !$0.archived && $0.source == entry?.trackers.first?.id }
                if let tracker = entry?.trackers.first, !mine.isEmpty {
                    let sections = CoreSection.allCases.compactMap { section -> String? in
                        let r = mine.filter { $0.section == section }
                        return r.isEmpty ? nil : "\(section.rawValue) \(r.count)" + (r.contains(where: \.open) ? " (\(r.filter(\.open).count) open)" : "")
                    }
                    row += "\n  tracker \(tracker.id) at \(tracker.path) [\(tracker.readOnly ? "read-only" : "kept by Broski")]: " + sections.joined(separator: ", ") + (tracker.board.map { " · board \($0)" } ?? "")
                }
                if let folders = entry?.folders, !folders.isEmpty { row += "\n  folders: " + folders.joined(separator: ", ") }
                return row + (summary.isEmpty ? "" : "\n  \(summary)")
            }
            let inbox = items.filter { $0.project == nil && $0.status != .done }.count
            return ((rows + ["- Inbox: \(inbox) open notes"]).joined(separator: "\n"), false)

        case "get_project_page":
            guard let name = scope(args["project"])?.name else { return unknown(args["project"]) }
            let projectItems = items.filter { $0.project == name }
            let projectSessions = sessions.filter { $0.project == name }
            let page = ProjectPage.load(name, from: store)
                ?? ProjectPageBuilder.rules(project: name, refs: projectItems.map(NoteRef.init), items: projectItems, sessions: projectSessions)
            var out = "Written \(ISO8601DateFormatter().string(from: page.compiled)) by \(page.source == .claude ? "Claude" : "Broski's rules")."
            // A page isn't rebuilt while the Mac app is closed, or with auto-compile off: say how far it lags.
            let changed = projectItems.filter { $0.updated > page.compiled }.count
                + projectSessions.flatMap(\.entries).filter { $0.time > page.compiled }.count
            if changed > 0 { out += " \(changed) notes changed since; use list_open_items for current state." }
            out += "\n\n" + (page.render().components(separatedBy: "\n---\n").last ?? "")
            let actions = page.actions.filter { !$0.dismissed }
            if !actions.isEmpty {
                out += "\n\n## Suggested actions\n" + actions.map { "- \($0.kind.rawValue): \($0.title)" + ($0.detail.isEmpty ? "" : " — \($0.detail)") + ($0.cites.isEmpty ? "" : " " + $0.cites.map { "[[\($0)]]" }.joined(separator: " ")) }.joined(separator: "\n")
            }
            return (capped(out), false)

        case "search_notes":
            guard let query = args["query"] as? String, !query.isEmpty else { return ("Give a query.", true) }
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let limit = min(max(args["limit"] as? Int ?? 10, 1), 30)
            let index = NotesIndex(items.map(NoteRef.init) + sessions.flatMap(NoteRef.entries) + records.filter { !$0.archived }.map(\.noteRef))
            let hits = index.search(query, project: where_.name, limit: where_ == .inbox ? 60 : limit)
                .filter { where_.contains($0.ref.project) }.prefix(limit)
            guard !hits.isEmpty else { return ("Nothing matches “\(query)”.", false) }
            return (hits.map { hit in
                let r = hit.ref
                return "- [\(r.id)] \(r.kind.rawValue) · \(r.open ? "open" : "done") · \(day.string(from: r.date)) · \(r.project ?? "Inbox"): \(r.title)"
                    + (hit.snippet.isEmpty ? "" : "\n  \(hit.snippet)")
            }.joined(separator: "\n"), false)

        case "get_record", "get_note":
            guard let id = args["id"] as? String, !id.isEmpty else { return ("Give an id.", true) }
            if let r = records.first(where: { $0.id == id }) ?? records.first(where: { $0.recordID == id }) {
                var out = "\(r.id) · \(r.kind) · \(r.section.rawValue)\(r.layer.isEmpty ? "" : "/\(r.layer)") · status \(r.status.isEmpty ? "-" : r.status) (\(r.canonical.rawValue))"
                out += "\nTitle: \(r.title)"
                if !r.summary.isEmpty { out += "\nSummary: \(r.summary)" }
                if !r.owner.isEmpty { out += "\nOwner: \(r.owner)" }
                if let thread = r.fields["owner_thread"] { out += "\nOwning thread: \(thread)" }
                if !r.severity.isEmpty { out += "\nSeverity: \(r.severity)" }
                if let date = r.date { out += "\nDated: \(ISO8601DateFormatter().string(from: date))" }
                out += "\nFile: \(r.file.path) (read-only; the tracker is the source of truth)"
                if let link = r.link { out += "\nBoard: \(link)" }
                if r.canonical == .live { out += "\nState: live-only; read it from the tracker's board." }
                if r.archived { out += "\nARCHIVED (history)." }
                if r.lowTrust { out += "\nProse map: may be out of date; don't take counts or state from it." }
                for (key, value) in r.fields.sorted(by: { $0.key < $1.key }) { out += "\n\(key): \(value)" }
                if !r.body.isEmpty { out += "\n\n" + r.body }
                return (capped(out), false)
            }
            if let item = items.first(where: { $0.id == id }), let text = try? String(contentsOf: item.file, encoding: .utf8) {
                let attachments = item.attachmentURLs.map { "Attachment: \($0.path)" }.joined(separator: "\n")
                return (capped((includeTranscript ? text : withoutTranscript(text)) + (attachments.isEmpty ? "" : "\n\n" + attachments)), false)
            }
            // A session observation: "<session id>#<entry number>".
            if let hash = id.lastIndex(of: "#"), let number = Int(id[id.index(after: hash)...]),
               let session = sessions.first(where: { $0.id == String(id[..<hash]) }), number >= 1, number <= session.entries.count {
                let entry = session.entries[number - 1]
                var out = "\(session.kind.label) “\(session.title)” (\(session.project ?? "Inbox")), observation \(number) of \(session.entries.count), \(ISO8601DateFormatter().string(from: entry.time))\n\n\(entry.text)"
                if !entry.context.isEmpty { out += "\n\nContext: \(entry.context.summary)" }
                for path in entry.attachments { out += "\nAttachment: \(session.folder.appendingPathComponent(path).path)" }
                return (capped(out), false)
            }
            return ("No note or record with id \(id).", true)

        case "tracker_query":
            guard let name = scope(args["project"])?.name else { return unknown(args["project"]) }
            var section: CoreSection?
            if let raw = (args["section"] as? String)?.lowercased(), !raw.isEmpty {
                guard let s = CoreSection(rawValue: raw) else { return ("section must be one of \(CoreSection.allCases.map(\.rawValue).joined(separator: ", ")).", true) }
                section = s
            }
            let kind = (args["kind"] as? String).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            let status = args["status"] as? String ?? "open"
            let owner = (args["owner"] as? String)?.lowercased()
            let limit = min(max(args["limit"] as? Int ?? 40, 1), 200)
            let rows = records.filter { r in
                r.project == name && !r.archived && (section == nil || r.section == section)
                    && (kind == nil || r.kind == kind || r.kind + "s" == kind)
                    && (status == "all" || (status == "open" ? r.open : !r.open))
                    && (owner == nil || r.owner.lowercased() == owner || r.fields["owner_thread"]?.lowercased() == owner)
            }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            guard !rows.isEmpty else { return ("No matching records in \(name).", false) }
            return (rows.prefix(limit).map { r in
                "- [\(r.id)] \(r.kind) · \(r.status.isEmpty ? r.canonical.rawValue : r.status)\(r.severity.isEmpty ? "" : " · \(r.severity)") · \(r.fields["owner_thread"] ?? r.owner) · \(r.date.map { TrackerReader.dayFormatter.string(from: $0) } ?? "-"): \(r.title.prefix(140))"
            }.joined(separator: "\n") + (rows.count > limit ? "\n(\(rows.count - limit) more)" : ""), false)

        case "waiting_on":
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let mine = records.filter { where_.contains($0.project) }
            let lines = WaitingOn.lines(records: mine, notes: items.filter { where_.contains($0.project) })
            let unread = WaitingOn.unread(records: mine)
            var out = lines.isEmpty ? "Nothing in the files is waiting on the user."
                : lines.prefix(80).map { "- [\($0.project)] \($0.text) [\($0.cite)]" + ($0.stateFromFiles ? "" : " (state: live, check the board)") }.joined(separator: "\n") + more(lines.count, 80)
            if !unread.isEmpty { out += "\n\nUnread messages between threads:\n" + unread.map { "- \($0.project) \($0.thread): \($0.ids.count)" }.joined(separator: "\n") }
            return (out, false)

        case "journal":
            let days = min(max(args["days"] as? Int ?? 7, 1), 60)
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            var entries = Journal.entries(records: records.filter { where_.contains($0.project) }, notes: items.filter { where_.contains($0.project) }, since: since)
            // Commit subjects too: never from a local-only project's repo.
            for entry in registry.projects where !localOnly.contains(entry.notes) && where_ != .inbox && where_.contains(entry.notes) {
                for source in entry.trackers where source.scope == .tracker {
                    if let ref = TrackerManifest.resolve(for: source, overlays: store.root.appendingPathComponent("trackers")).readFrom {
                        entries += Journal.commits(repo: source.url, ref: ref, since: since, project: entry.notes)
                    }
                }
            }
            entries.sort { $0.at > $1.at }
            guard !entries.isEmpty else { return ("Nothing changed in the last \(days) days.", false) }
            return (entries.prefix(150).map { e in
                "- \(ISO8601DateFormatter().string(from: e.at)) [\(e.project)] \(e.kind)\(e.thread.map { " (\($0))" } ?? ""): \(e.text)" + (e.cite.map { " [\($0)]" } ?? "")
            }.joined(separator: "\n") + more(entries.count, 150), false)

        case "changes_since":
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let days = min(max(args["days"] as? Int ?? 1, 1), 60)
            var since = Date().addingTimeInterval(-Double(days) * 86_400)
            if let raw = (args["since"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                guard let date = TrackerReader.parseDateString(raw) else { return ("since must be an ISO date or time, like 2026-10-20 or 2026-10-20T09:00:00Z.", true) }
                since = date
            }
            let iso = ISO8601DateFormatter()
            // Newest first. Local-only projects' changes are recorded on the Mac but never shown here.
            let events = Array(ChangeStream.read(root: store.root, project: where_.name, since: since)
                .filter { !localOnly.contains($0.project) && where_.contains($0.project) }.reversed())
            guard !events.isEmpty else {
                return ("No tracker changes recorded since \(iso.string(from: since)). Broski records them while its app reads the trackers.", false)
            }
            return (events.prefix(200).map { e in
                "- \(iso.string(from: e.at)) [\(e.project)] \(e.kind) \(e.id): \(e.title)" + (e.from == nil && e.to == nil ? "" : " (\(e.from ?? "–") → \(e.to ?? "–"))")
            }.joined(separator: "\n") + more(events.count, 200), false)

        case "tracker_health":
            guard let project = scope(args["project"])?.name else { return unknown(args["project"]) }
            guard let entry = registry.entry(notes: project), !Library.sources(of: entry).isEmpty else {
                return ("\(project) has no tracker or code folder in projects.json, so there's no map to drift.", false)
            }
            let health = OnboardKit.health(for: entry, root: store.root, records: records.filter { $0.project == project }, snapshots: brain.snapshots)
            var out = OnboardKit.describe(health, name: entry.name)
            if health.drifted { out += "\nTo ask the threads about just this: Broski --start-onboarding \(entry.notes) --delta (or Ask the threads on the project's Tracker tab)." }
            return (out, false)

        case "tracker_add":
            guard let project = scope(args["project"])?.name else { return unknown(args["project"]) }
            let kept = keptTracker(project)
            guard let tracker = kept.tracker else { return (kept.refusal, true) }
            let kind = (args["kind"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            guard ["task", "bug", "risk", "finding", "idea", "decision"].contains(kind) else { return ("kind must be one of task, bug, risk, finding, idea, decision.", true) }
            let title = (args["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return ("Give a title.", true) }
            let severity = (args["severity"] as? String).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            if let severity, !["crit", "high", "med", "low", "info"].contains(severity) { return ("severity must be one of crit, high, med, low, info.", true) }
            do {
                let id = try TrackerTemplate.add(kind: kind, title: title, body: args["body"] as? String ?? "", severity: kind == "decision" ? nil : severity,
                                                 tracker: tracker.url, root: store.root)
                brain.invalidate()
                return ("Added \(tracker.id):\(id) to \(tracker.name).", false)
            } catch {
                return ("Couldn't add it: \(error)", true)
            }

        case "tracker_set_status":
            guard let project = scope(args["project"])?.name else { return unknown(args["project"]) }
            let kept = keptTracker(project)
            guard let tracker = kept.tracker else { return (kept.refusal, true) }
            var id = (args["id"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if id.hasPrefix(tracker.id + ":") { id = String(id.dropFirst(tracker.id.count + 1)) }
            // An item id names a file in the tracker: nothing that could point outside it.
            guard !id.isEmpty, !id.contains("/"), !id.contains("..") else { return ("Give an item id, like BUG-3.", true) }
            let status = (args["status"] as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            let statuses = ["open", "doing", "blocked", "done", "wontfix", "decided", "superseded"]
            guard statuses.contains(status) else { return ("status must be one of \(statuses.joined(separator: ", ")).", true) }
            do {
                try TrackerTemplate.setStatus(id, to: status, note: args["note"] as? String, tracker: tracker.url, root: store.root)
                brain.invalidate()
                return ("\(tracker.id):\(id) is now \(status).", false)
            } catch {
                return ("Couldn't change it: \(error)", true)
            }

        case "check_onboarding":
            if let path = (args["run"] as? String)?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
                let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
                guard folder.path.hasPrefix(store.root.appendingPathComponent("projects").standardizedFileURL.path + "/"),
                      let run = Onboarding.loadRun(folder) else { return ("No onboarding run at \(path).", true) }
                guard !localOnly.contains(run.project) else { return ("That project is local-only.", true) }
                let known = Set(records.filter { $0.project == run.project }.map(\.recordID))
                let report = OnboardingCheck.check(run, only: args["only"] as? String, knownRecords: known)
                return (OnboardKit.summary(report), false)
            }
            guard let name = scope(args["project"])?.name else { return ("Pass run (a run folder) or project.", true) }
            let runs = OnboardKit.runs(for: name, root: store.root)
            guard !runs.isEmpty else { return ("No onboarding runs for \(name). Start one from the dashboard (Tracker › Onboard).", false) }
            return (runs.map { url in
                let run = Onboarding.loadRun(url)
                let answers = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasPrefix("Q-") }.count
                return "- \(url.lastPathComponent): \(answers) answers, threads \(run?.assign.keys.sorted().joined(separator: ", ") ?? "?") — \(url.path)"
            }.joined(separator: "\n"), false)

        case "list_open_items":
            var wanted: NoteKind?
            if let raw = (args["kind"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                guard let kind = NoteKind(rawValue: raw) ?? NoteKind(rawValue: String(raw.dropLast())) else { return ("kind must be one of bug, todo, idea, note.", true) }
                wanted = kind
            }
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let open = items.filter { $0.status != .done && (wanted == nil || $0.kind == wanted) && where_.contains($0.project) }
                .sorted { ($0.priority, $0.updated) > ($1.priority, $1.updated) }
            return (open.isEmpty ? "Nothing open." : open.prefix(60).map(line).joined(separator: "\n") + more(open.count, 60), false)

        case "recent_notes":
            let days = min(max(args["days"] as? Int ?? 7, 1), 90)
            let since = Date().addingTimeInterval(-Double(days) * 86_400)
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let recent = items.filter { $0.created >= since && where_.contains($0.project) }
                .sorted { $0.created > $1.created }
            return (recent.isEmpty ? "Nothing in the last \(days) days." : recent.prefix(60).map(line).joined(separator: "\n") + more(recent.count, 60), false)

        case "search_conversations":
            guard let query = args["query"] as? String, !query.isEmpty else { return ("Give a query.", true) }
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let limit = min(max(args["limit"] as? Int ?? 10, 1), 30)
            // Local-only projects never leave Broski, and neither does what was said about them.
            let turns = ConversationStore(root: store.root, device: "mac").recent(5000)
                .filter { !localOnly.contains($0.project ?? "") && where_.contains($0.project) }
            let hits = NotesIndex(Recall.refs(turns: turns, root: store.root)).search(query, limit: limit)
            guard !hits.isEmpty else { return ("Nothing in the conversation matches “\(query)”.", false) }
            return (hits.map { hit in
                "- [\(hit.ref.id)] \(hit.ref.source == "you" ? "user" : "broski") · \(day.string(from: hit.ref.date)) · \(hit.ref.project ?? "no project"): \(hit.ref.body.prefix(300))"
            }.joined(separator: "\n"), false)

        case "decisions":
            guard let where_ = scope(args["project"]) else { return unknown(args["project"]) }
            let names = ([nil] + projects.map(Optional.some)).filter { !localOnly.contains($0 ?? "") && where_.contains($0) }
            let rows = names.flatMap { project -> [String] in
                let all = DecisionLog.all(root: store.root, project: project)
                let replaced = Dictionary(all.compactMap { d in d.replaces.map { ($0, d) } }, uniquingKeysWith: { first, _ in first })
                return all.map { d in
                    "- [\(d.id)] \(day.string(from: d.at)) · \(project ?? "Inbox"): \(d.text)"
                        + (replaced[d.id].map { " (replaced \(day.string(from: $0.at)) by: \($0.text))" } ?? "")
                }
            }
            return (rows.isEmpty ? "No decisions saved yet." : rows.joined(separator: "\n"), false)

        case "memory":
            return (Memory.aboutYou(root: store.root) ?? "Broski doesn't know anything about the user yet.", false)

        default:
            return ("Unknown tool \(name).", true)
        }
    }
}
