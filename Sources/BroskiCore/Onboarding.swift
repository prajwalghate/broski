import Foundation

/// The onboarding kit: a questionnaire each project's threads answer with evidence, a checker that verifies
/// every citation, and an assembler that turns verified answers into the tracker's manifest. Answers live in
/// Broski's folder (`projects/<p>/onboarding/<run>/`), never in the project's tracker.
public enum Onboarding {
    public struct Question: Codable, Equatable {
        public var id: String
        public var group: String
        public var text: String
        public var evidence: String
        public var feeds: String
    }

    /// core-v1: 24 questions across identity, the five core sections, open items, layers and gaps.
    public static let questions: [Question] = [
        .init(id: "Q-ID-1", group: "Identity and sources", text: "What is this project, in two sentences, and where is its brief?", evidence: "the brief file, with a quote", feeds: "title, summary"),
        .init(id: "Q-ID-2", group: "Identity and sources", text: "Which repositories and folders make up the project? Which one is the tracker? Is any folder a copy or a backup that must not be read?", evidence: "per repo, a file: (CLAUDE.md/README) plus a commit: of its HEAD; absent: where there's no git", feeds: "repos, exclude"),
        .init(id: "Q-ID-3", group: "Identity and sources", text: "What are the rules for writing to the tracker (ids, history, validators, hooks), and what must Broski never read or send to Claude?", evidence: "the rules file and the validator or hook file, each quoted", feeds: "privacy, exclude, ids"),
        .init(id: "Q-ID-4", group: "Identity and sources", text: "Who are the people, and which words name them in records (\"you\", \"founder\", \"the team\")?", evidence: "for each alias, a record that uses it", feeds: "people"),
        .init(id: "Q-SHIP-1", group: "Ship", text: "What is the plan (milestones or phases with exit criteria), and which is current? How do you know it's current?", evidence: "the plan file, plus the record or commit proving the current one", feeds: "core.ship (milestone)"),
        .init(id: "Q-SHIP-2", group: "Ship", text: "What has shipped where (releases, environments, packages), and how is \"what is live\" proven? How does work get from a thread onto main?", evidence: "deployments file or receipt; the CI/sync/hook file", feeds: "core.ship (release)"),
        .init(id: "Q-LAUNCH-1", group: "Launch", text: "Is there a go-live, or a next launch? Where is its checklist, what are the steps, their order and owners?", evidence: "the launch file, with one step quoted", feeds: "core.launch"),
        .init(id: "Q-LAUNCH-2", group: "Launch", text: "What proves a launch step done (evidence kinds), and which steps can only a person do?", evidence: "the definition of evidence kinds, or two real done steps", feeds: "core.launch map"),
        .init(id: "Q-OPS-1", group: "Ops", text: "Which runbooks exist (deploy, restart, rotate, restore, kill switch), and when was each last run?", evidence: "the runbook files; for each, a commit:/receipt:/record: of its last run, or absent:", feeds: "core.ops (runbook)"),
        .init(id: "Q-OPS-2", group: "Ops", text: "Where is the history of actions recorded (commit trailers, receipts, work log, dated update sections)?", evidence: "one ref per source, e.g. a commit with its trailer", feeds: "core.ops (journal)"),
        .init(id: "Q-OPS-3", group: "Ops", text: "Which incidents happened, and where are they written up?", evidence: "at least 2 incident records, or absent:", feeds: "core.ops (incident)"),
        .init(id: "Q-OPS-4", group: "Ops", text: "What runs on its own (watchers, jobs, loops, services), where does it run, how do you know it's alive, and how stale may each reading be?", evidence: "the unit or watcher code; the status file; an incident if one died", feeds: "core.ops (watcher), freshness"),
        .init(id: "Q-DEC-1", group: "Decisions", text: "Where are decisions recorded, what fields does each carry, and how is a changed decision handled?", evidence: "the decisions file, with one decided example quoted", feeds: "core.decisions"),
        .init(id: "Q-DEC-2", group: "Decisions", text: "How does a decision get made and recorded? Who may decide, where does the owner's answer arrive, and how does a new session find decisions made since the last one?", evidence: "the rule in CLAUDE.md/README; one real decision with its thread: or commit:", feeds: "people, decision intake"),
        .init(id: "Q-THR-1", group: "Threads", text: "Which threads work on this project (Claude Code sessions, people, bots), where does each work (repo, checkout, branch), and what does each own?", evidence: "registry or THREADS file; one thread: ref per Claude thread", feeds: "core.threads"),
        .init(id: "Q-THR-2", group: "Threads", text: "How do threads hand off and wait on each other? Give one real handoff.", evidence: "the mechanism file, plus the handoff record or commit", feeds: "waiting_on"),
        .init(id: "Q-THR-3", group: "Threads", text: "How can Broski tell what each thread did last?", evidence: "a commit carrying the trailer; the session path", feeds: "threads activity"),
        .init(id: "Q-ITEM-1", group: "Open items", text: "Where are bugs, findings, tasks, risks and todos kept? Which kinds and id series exist, and where is the id registry?", evidence: "item folder, schema, registry; one item of each kind", feeds: "core.findings, ids"),
        .init(id: "Q-ITEM-2", group: "Open items", text: "What does each native status word mean, which are closed, and what must a closed item carry? Map them to open, doing, blocked, done, wontfix, accepted.", evidence: "the schema/validator/README text defining them, quoted; one example per word in use", feeds: "statusMap"),
        .init(id: "Q-LAY-1", group: "Project layer", text: "What does this project track that doesn't fit ship, launch, ops, decisions, threads or items? Name each as a layer with its files.", evidence: "at least 1 file per layer, quoted", feeds: "layers"),
        .init(id: "Q-LAY-2", group: "Project layer", text: "For each layer: what is one record, its fields, and its source of truth (hand-written or generated, and by what)?", evidence: "an example record quoted, plus the generator or schema file", feeds: "layers reader, derived"),
        .init(id: "Q-LAY-3", group: "Project layer", text: "Which numbers must never be typed by hand, where do they come from, and how stale may each be?", evidence: "the generator, watcher or report, plus its status file", feeds: "freshness"),
        .init(id: "Q-GAP-1", group: "Gaps", text: "Which docs are known to be stale or wrong? Cite the doc and the file proving otherwise.", evidence: "the pair of refs", feeds: "lowTrust"),
        .init(id: "Q-GAP-2", group: "Gaps", text: "Name one question about this project that was needed recently and the tracker could not answer directly. Where was the answer actually found?", evidence: "the thread: ref where it was asked, plus where the answer was", feeds: "golden questions"),
    ]

    /// The questions a brand-new project answers in a short setup chat.
    /// The checker the threads run (the installed app's binary).
    public static var checker = "/Applications/Broski.app/Contents/MacOS/Broski"

    public static let newProjectQuestions = ["Q-ID-1", "Q-ID-2", "Q-ID-4", "Q-SHIP-1", "Q-LAUNCH-1", "Q-OPS-4", "Q-DEC-2", "Q-THR-1", "Q-LAY-1", "Q-LAY-3"]

    // MARK: Runs

    public struct Run: Equatable {
        public var id: String
        public var project: String
        public var mode: String
        public var folder: URL
        /// alias → absolute path.
        public var repos: [String: String]
        /// thread → question ids.
        public var assign: [String: [String]]
        /// thread → the folder its Claude Code sessions run in, when the tracker says (an agents file's `repo`).
        public var homes: [String: String] = [:]
        /// A delta run's list of what changed since the last run: the only things its threads answer about.
        public var note: String? = nil
    }

    /// Creates a run folder with RUN.md, QUESTIONS.md, FORMAT.md and one PROMPT-<thread>.md per thread.
    /// `assign` (thread → question ids) replaces the default split; `note` says what changed since the last run.
    public static func startRun(project: String, title: String, mode: String, repos: [String: String], threads: [String],
                                homes: [String: String] = [:], questionIDs: [String]? = nil, assign explicit: [String: [String]]? = nil,
                                note: String? = nil, root: URL, date: Date = Date()) throws -> Run {
        let day = TrackerReader.dayFormatter.string(from: date)
        let base = root.appendingPathComponent("projects/\(project)/onboarding", isDirectory: true)
        var id = "\(day)-\(mode)"
        var n = 2
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(id).path) { id = "\(day)-\(mode)-\(n)"; n += 1 }
        let folder = base.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ids: [String]
        if let questionIDs { ids = questionIDs }
        else if let explicit { ids = questions.map(\.id).filter { q in explicit.values.contains { $0.contains(q) } } }
        else { ids = mode == "new" ? newProjectQuestions : questions.map(\.id) }
        var assign: [String: [String]] = explicit ?? [:]
        if explicit == nil {
            for (i, thread) in threads.enumerated() {
                // The first thread answers everything; others answer what they know best (threads, items, layers, gaps).
                assign[thread] = i == 0 ? ids : ids.filter { $0.hasPrefix("Q-THR") || $0.hasPrefix("Q-ITEM") || $0.hasPrefix("Q-LAY") || $0.hasPrefix("Q-GAP") || $0 == "Q-ID-2" }
            }
        }
        let changes = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let run = Run(id: id, project: project, mode: mode, folder: folder, repos: repos, assign: assign, homes: homes, note: changes)
        try runFile(run, title: title, created: date).write(to: folder.appendingPathComponent("RUN.md"), atomically: true, encoding: .utf8)
        try questionsFile(ids).write(to: folder.appendingPathComponent("QUESTIONS.md"), atomically: true, encoding: .utf8)
        try formatFile.write(to: folder.appendingPathComponent("FORMAT.md"), atomically: true, encoding: .utf8)
        for thread in assign.keys.sorted() {
            try prompt(run, thread: thread, title: title).write(to: folder.appendingPathComponent("PROMPT-\(thread).md"), atomically: true, encoding: .utf8)
        }
        return run
    }

    /// The heading RUN.md keeps a delta run's note under.
    static let noteHeading = "## What changed since the last run"

    public static func loadRun(_ folder: URL) -> Run? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("RUN.md"), encoding: .utf8) else { return nil }
        let (front, body) = YAMLFrontMatter.split(text)
        var repos: [String: String] = [:]
        for item in front["repos"]?.list ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { repos[parts[0]] = parts[1] }
        }
        var assign: [String: [String]] = [:]
        for item in front["assign"]?.list ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { assign[parts[0]] = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        }
        var homes: [String: String] = [:]
        for item in front["homes"]?.list ?? [] {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { homes[parts[0]] = parts[1] }
        }
        let note = body.range(of: noteHeading).map { String(body[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        return Run(id: front["run"]?.string ?? folder.lastPathComponent, project: front["project"]?.string ?? "",
                   mode: front["mode"]?.string ?? "convert", folder: folder, repos: repos, assign: assign, homes: homes,
                   note: note.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func runFile(_ run: Run, title: String, created: Date) -> String {
        """
        ---
        run: \(run.id)
        project: \(run.project)
        title: "\(title)"
        mode: \(run.mode)
        questionnaire: core-v1
        created: \(FrontMatter.isoFormatter.string(from: created))
        repos:
        \(run.repos.sorted { $0.key < $1.key }.map { "  - \($0.key) = \($0.value)" }.joined(separator: "\n"))
        assign:
        \(run.assign.sorted { $0.key < $1.key }.map { "  - \($0.key) = \($0.value.joined(separator: ", "))" }.joined(separator: "\n"))
        homes:
        \(run.homes.sorted { $0.key < $1.key }.map { "  - \($0.key) = \($0.value)" }.joined(separator: "\n"))
        ---
        # Onboarding \(title): \(run.id)

        Broski reads this project's tracker in place and never writes to it. Each thread answers its questions here,
        one file per question: `<Q-id>.<thread>.md` (see FORMAT.md). Then run the checker:

            \(checker) --check-onboarding "\(run.folder.path)"

        """ + (run.note.map { "\n\(noteHeading)\n\n\($0)\n" } ?? "")
    }

    static func questionsFile(_ ids: [String]) -> String {
        var out = "# Questions (core-v1)\n\nEvery answer needs evidence. \"answered\" needs at least one quoted ref that verifies.\n"
        var group = ""
        for q in questions where ids.contains(q.id) {
            if q.group != group { group = q.group; out += "\n## \(group)\n" }
            out += "\n### \(q.id)\n\(q.text)\n\n- Evidence required: \(q.evidence)\n- Feeds: \(q.feeds)\n"
        }
        return out
    }

    static let formatFile = """
    # Answer format

    One file per question per thread: `<Q-id>.<thread>.md`.

    ```markdown
    ---
    q: Q-OPS-1
    thread: ops
    session: <your Claude Code session id, if known>
    answered: 2026-10-21T11:40:00+05:30
    status: answered            # answered | partial | gap | not-applicable
    evidence:
      - ref: "file:@tracker:tracker/data/runbook.json"
        quote: "The deployment as ACTIONS: what someone does, with which command, approved how"
      - ref: "commit:@tracker:62f04eb"
        quote: "overnight the Mac slept again"
      - ref: "record:ONE-X188"
      - ref: "absent:@tracker:tracker/runbooks/**"
    maps:
      - "ops.runbook <- @tracker:tracker/data/runbook.json | json-records | value.phases[].actions[]"
    ---
    A short answer in plain words.
    ```

    ## Evidence refs

    - `file:[@alias:]path[#Lstart-Lend]` — the file exists (and the line range is valid). With `quote`, the quote is in it.
    - `receipt:[@alias:]path` — same as file:, for a machine-written receipt.
    - `commit:[@alias:]sha` — the commit exists. With `quote`, the quote is in its message.
    - `record:[project:]ID` — the id exists in the tracker (Broski's index or the id registry).
    - `thread:<claude-project-slug>/<session-uuid>[#<message-uuid>]` — the Claude Code transcript exists (and contains the uuid / quote).
    - `absent:[@alias:]glob` — nothing matches (proves a gap).
    - `pr:` and `url:` — allowed, but never count.

    Aliases come from RUN.md (`repos`). Without an alias, a path is relative to the tracker.
    A quote is at most 200 characters, copied verbatim. Whitespace, `*`, `_` and backticks don't matter.

    ## Statuses
    - answered: at least 1 strong ref and at least 1 quoted ref that verifies.
    - partial: at least 1 strong ref.
    - gap: at least 1 absent: that verifies, or a thread: where the owner said it doesn't exist.
    - not-applicable: a reason and at least 1 ref.

    ## maps (optional, feed the manifest)
    `"<section>[.<kind>] <- @alias:glob-or-file | reader | path"` with readers fm-records, json-records, json-doc,
    jsonl-records, md-sections, md-checklist, md-doc. Sections: ship, launch, ops, decisions, threads, findings, layer.<name>.
    """

    /// The fork-and-ask prompt for one thread.
    public static func prompt(_ run: Run, thread: String, title: String) -> String {
        let ids = run.assign[thread] ?? []
        // A delta run asks about what changed and nothing else; the last run's answers stand.
        let changed = run.note.map { note in
            "WHAT CHANGED SINCE THE LAST RUN\n\(note)\nThis run follows up on these changes only: answer just your questions below, "
                + "about these items. Everything else in the last run's answers stands.\n\n"
        } ?? ""
        return """
        You are the \(thread) thread of \(title). Broski, the owner's memory layer, is onboarding this project.
        Broski will read and index this project's tracker in place; it never copies it or writes to it.
        Your job: answer the onboarding questions assigned to you, each backed by real evidence, so Broski can build
        a manifest of where everything lives.

        STRICT RULES
        - Read only. Do not edit, create or delete any file except your answer files in \(run.folder.path).
        - Do not run builds, tests, servers, npm/pnpm, swift, pytest or xcodebuild; this laptop overheats.
          Reading files, listing folders, grep and read-only git (log, show, cat-file) are fine.
        - No network calls. Never send a message anywhere.
        - Never copy a secret into an answer (keys, tokens, seed phrases, .env contents). Addresses and hashes are fine.
        - Do not change the tracker, even where you find it wrong. Report that under Q-GAP-1 instead.
        - Trust the code and the records over old docs: where a doc disagrees with the files, cite the files and list the doc under Q-GAP-1.

        \(changed)HOW TO ANSWER
        - Your questions: \(ids.joined(separator: ", ")). The full text is in \(run.folder.path)/QUESTIONS.md; repository aliases are in RUN.md.
        - One file per question: \(run.folder.path)/<Q-id>.\(thread).md, in the format in FORMAT.md.
        - Every "answered" needs at least one quoted ref: copy up to 200 characters verbatim from the file, commit message or transcript line.
        - If something does not exist, say so: status gap, plus absent: globs for where you looked. Never invent a path, an id or a commit.
        - Where a decision was made in chat, cite the transcript (thread:) rather than restating it from memory.
        - Add maps: lines that say which files feed which section.

        WHEN DONE
        - Run: \(checker) --check-onboarding "\(run.folder.path)" --only \(thread)   (read only, a few seconds). Fix every FAIL and rerun.
        - Reply with one table: question, status, number of refs, one-line answer. Then list anything Broski's core sections cannot represent for this project.
        """
    }

    // MARK: Keeping it current

    /// How well a project's onboarding still fits its trackers.
    public struct Health: Equatable {
        /// What the trackers' reads found the manifest missing.
        public var drift: TrackerDrift
        /// Threads the tracker lists that no run has asked yet.
        public var newThreads: [String]
        public var latestRun: Run?
        /// Who answers the map and status questions: the thread that led the last full run.
        public var lead: String

        public init(drift: TrackerDrift = TrackerDrift(), newThreads: [String] = [], latestRun: Run? = nil, lead: String = "main") {
            self.drift = drift
            self.newThreads = newThreads
            self.latestRun = latestRun
            self.lead = lead
        }

        public var drifted: Bool { !drift.isEmpty || !newThreads.isEmpty }

        public var lines: [String] {
            drift.lines + (newThreads.isEmpty ? [] : ["\(newThreads.count) new thread\(newThreads.count == 1 ? "" : "s"): " + newThreads.joined(separator: ", ")])
        }
    }

    /// A delta run's questions by thread: the map questions for files no source reads and mappings that find nothing,
    /// the status question for unknown words (both to the lead), the thread questions to each new thread only, and a
    /// stale answer's question back to the thread that gave it.
    public static func deltaAssign(_ health: Health, stale: [String] = []) -> [String: [String]] {
        var assign: [String: Set<String>] = [:]
        if health.drift.unmappedCount > 0 || !health.drift.deadSources.isEmpty {
            assign[health.lead, default: []].formUnion(["Q-ITEM-1", "Q-LAY-1", "Q-LAY-2"])
        }
        if !health.drift.unknownStatuses.isEmpty { assign[health.lead, default: []].insert("Q-ITEM-2") }
        for thread in health.newThreads { assign[thread, default: []].formUnion(["Q-THR-1", "Q-THR-2", "Q-THR-3"]) }
        for file in stale {
            if let answer = answerName(file) { assign[answer.thread, default: []].insert(answer.q) }
        }
        let order = questions.map(\.id)
        return assign.mapValues { ids in order.filter { ids.contains($0) } }.filter { !$0.value.isEmpty }
    }

    /// "Q-ITEM-1.ops.md" → (Q-ITEM-1, ops).
    public static func answerName(_ file: String) -> (q: String, thread: String)? {
        let name = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (q: parts[0], thread: parts[1])
    }

    /// What a delta run asks about, item by item, for RUN.md and every prompt.
    public static func deltaNote(_ health: Health, stale: [String] = []) -> String {
        let drift = health.drift
        var lines: [String] = []
        if let run = health.latestRun { lines.append("Last run: \(run.id) (\(run.folder.path)). Its answers stand except where listed here.") }
        if drift.unmappedCount > 0 {
            lines.append("Files no source reads (\(drift.unmappedCount)), for Q-ITEM-1, Q-LAY-1 and Q-LAY-2: map each to a section or a layer, or say why it isn't tracker data:")
            lines += drift.unmapped.prefix(60).map { "- \($0)" }
            if drift.unmappedCount > 60 { lines.append("- …and \(drift.unmappedCount - 60) more") }
        }
        if !drift.deadSources.isEmpty {
            lines.append("Mappings that find nothing (moved, renamed or gone), for Q-ITEM-1, Q-LAY-1 and Q-LAY-2: where does each live now?")
            lines += drift.deadSources.map { "- \($0)" }
        }
        if !drift.unknownStatuses.isEmpty {
            lines.append("Status words Broski doesn't know (records using each), for Q-ITEM-2: what each means and which canonical status it is:")
            lines += drift.statusWords.map { "- \($0)" }
        }
        if !health.newThreads.isEmpty {
            lines.append("New threads, for Q-THR-1, Q-THR-2 and Q-THR-3 (each new thread answers for itself):")
            lines += health.newThreads.map { "- \($0)" }
        }
        if !stale.isEmpty {
            lines.append("Earlier answers whose evidence no longer checks out" + (health.latestRun.map { " in \($0.id)" } ?? "") + ": answer them again with current evidence:")
            lines += stale.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Evidence

    public struct Evidence: Equatable {
        public enum Kind: String { case file, receipt, commit, record, thread, absent, pr, url }
        public var kind: Kind
        public var alias: String?
        public var target: String
        public var lines: ClosedRange<Int>?
        public var quote: String?
        public var note: String?

        public var strong: Bool { kind != .pr && kind != .url }

        /// "file:@tracker:tracker/data/runbook.json#L3-L9"
        public static func parse(_ ref: String, quote: String? = nil, note: String? = nil) -> Evidence? {
            guard let colon = ref.firstIndex(of: ":"), let kind = Kind(rawValue: String(ref[..<colon]).lowercased()) else { return nil }
            var rest = String(ref[ref.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var alias: String?
            if rest.hasPrefix("@"), let sep = rest.dropFirst().firstIndex(of: ":") {
                alias = String(rest[rest.index(after: rest.startIndex)..<sep])
                rest = String(rest[rest.index(after: sep)...])
            }
            var lines: ClosedRange<Int>?
            if kind == .file || kind == .receipt, let hash = rest.range(of: "#L") {
                let spec = rest[hash.upperBound...].replacingOccurrences(of: "L", with: "")
                let parts = spec.split(separator: "-").compactMap { Int($0) }
                if let a = parts.first { lines = a...(parts.count > 1 ? max(a, parts[1]) : a) }
                rest = String(rest[..<hash.lowerBound])
            }
            return Evidence(kind: kind, alias: alias, target: rest, lines: lines, quote: quote, note: note)
        }
    }

    public struct Answer: Equatable {
        public var file: URL
        public var q: String
        public var thread: String
        public var status: String
        public var evidence: [Evidence]
        public var maps: [String]
        public var body: String
        public var problems: [String]
    }

    public static func parseAnswer(_ file: URL) -> Answer {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let (front, body) = YAMLFrontMatter.split(text)
        var problems: [String] = []
        if front.isEmpty { problems.append("no front matter") }
        // evidence is a list of maps: "ref: …", "quote: …", "note: …" lines. Parse them from the raw YAML block.
        var evidence: [Evidence] = []
        let yaml = text.components(separatedBy: "\n---\n").first ?? ""
        var current: [String: String] = [:]
        var inEvidence = false
        func flush() {
            if let ref = current["ref"] {
                if let e = Evidence.parse(ref, quote: current["quote"], note: current["note"]) { evidence.append(e) } else { problems.append("can't read ref \(ref)") }
            }
            current = [:]
        }
        for raw in yaml.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !raw.hasPrefix(" ") && !raw.hasPrefix("-") { if inEvidence { flush() }; inEvidence = line.hasPrefix("evidence:"); continue }
            guard inEvidence else { continue }
            var content = line
            if content.hasPrefix("- ") { flush(); content = String(content.dropFirst(2)) }
            if let c = content.firstIndex(of: ":") {
                let key = String(content[..<c]).trimmingCharacters(in: .whitespaces)
                let value = YAMLFrontMatter.scalar(String(content[content.index(after: c)...]))
                if ["ref", "quote", "note"].contains(key) { current[key] = value }
            }
        }
        if inEvidence { flush() }
        let name = file.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        return Answer(file: file, q: front["q"]?.string ?? parts.first ?? "", thread: front["thread"]?.string ?? (parts.count > 1 ? parts[1] : ""),
                      status: front["status"]?.string ?? "", evidence: evidence, maps: front["maps"]?.list ?? [],
                      body: body.trimmingCharacters(in: .whitespacesAndNewlines), problems: problems)
    }

    /// Whitespace, markdown emphasis and backticks don't matter when matching a quote.
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\\\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased().trimmingCharacters(in: .whitespaces)
    }
}
