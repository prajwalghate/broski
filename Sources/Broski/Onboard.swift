import BroskiCore
import Foundation

/// The onboarding kit, shared by the command line, the MCP server and the dashboard.
///
///     Broski --start-onboarding <project> [--threads ops,app] [--mode convert|new]
///     Broski --start-onboarding <project> --delta      (asks only about what drifted since the last run)
///     Broski --onboarding-health <project>
///     Broski --check-onboarding <run folder> [--only <thread>]
///     Broski --assemble-onboarding <run folder>
///     Broski --new-tracker <project>
///
/// Everything reads the projects in place. The only writes are the run folder, Broski's own overlay drafts,
/// and trackers Broski owns.
enum OnboardKit {
    static let binary = "/Applications/Broski.app/Contents/MacOS/Broski"

    static func runs(for project: String, root: URL) -> [URL] {
        let base = root.appendingPathComponent("projects/\(project)/onboarding", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("RUN.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// alias → path: the tracker, the manifest's other repos, and the project's folders.
    static func repos(of entry: ProjectRegistry.Entry, root: URL) -> [String: String] {
        var repos: [String: String] = [:]
        let tracker = entry.trackers.first
        if let tracker {
            repos["tracker"] = tracker.url.standardizedFileURL.path
            let manifest = TrackerManifest.resolve(for: tracker, overlays: root.appendingPathComponent("trackers"))
            for (alias, path) in manifest.repos ?? [:] {
                let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : tracker.url.appendingPathComponent(path)
                repos[alias] = url.standardizedFileURL.path
            }
        }
        for folder in entry.folders {
            let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
            guard !repos.values.contains(path) else { continue }
            var alias = URL(fileURLWithPath: path).lastPathComponent.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            while repos[alias] != nil { alias += "-2" }
            repos[alias] = path
        }
        if repos["tracker"] == nil, let first = entry.folders.first {
            repos["tracker"] = URL(fileURLWithPath: (first as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        return repos
    }

    /// The tracker's own threads (its agents file), else one "main" thread.
    static func threads(of entry: ProjectRegistry.Entry, records: [TrackerRecord]) -> [String] {
        let tracker = entry.trackers.first?.id
        // Thread records read from an agents file are "agents/ops"; the thread is "ops".
        let named = records.filter { $0.kind == "thread" && $0.source == tracker }.map { ($0.recordID as NSString).lastPathComponent }
        return named.isEmpty ? ["main"] : Array(Set(named)).sorted()
    }

    static func records(of entry: ProjectRegistry.Entry, root: URL) -> [TrackerRecord] {
        Library.sources(of: entry).flatMap { TrackerReader.read($0, project: entry.notes, overlays: root.appendingPathComponent("trackers")) }
    }

    /// Claude Code's folder for a working directory: every non-alphanumeric character becomes "-".
    static func claudeSlug(_ path: String) -> String {
        path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    }

    /// The newest Claude Code session that worked in a folder, to fork for the questions.
    static func newestSession(in path: String) -> (slug: String, id: String, date: Date)? {
        let slug = claudeSlug(path)
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects/\(slug)")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        let dated = files.compactMap { url -> (URL, Date)? in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (url, date)
        }
        guard let newest = dated.max(by: { $0.1 < $1.1 }) else { return nil }
        return (slug, newest.0.deletingPathExtension().lastPathComponent, newest.1)
    }

    /// Where a thread's sessions may run, most specific first: the folder the tracker names for it, its own repo
    /// alias, then (for the thread that leads, or a project with one thread) the tracker and the project's folders.
    static func folders(of thread: String, run: Onboarding.Run) -> [String] {
        var out = [run.homes[thread], run.repos[thread]].compactMap { $0 }
        let lead = run.assign.count <= 1 || run.assign[thread]?.count == run.assign.values.map(\.count).max()
        if lead || out.isEmpty { out += [run.repos["tracker"]].compactMap { $0 } + run.repos.sorted { $0.key < $1.key }.map(\.value) }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The command that forks the thread's newest session (in whichever of its folders has the newest) and asks it the questions.
    static func forkCommand(thread: String, run: Onboarding.Run) -> String {
        let candidates = folders(of: thread, run: run)
        let prompt = run.folder.appendingPathComponent("PROMPT-\(thread).md").path
        let sessions = candidates.compactMap { folder in newestSession(in: folder).map { (folder, $0) } }
        if let (folder, session) = sessions.max(by: { $0.1.date < $1.1.date }) {
            return "cd \(shell(folder)) && claude --resume \(session.id) --fork-session \"$(cat \(shell(prompt)))\""
        }
        return "cd \(shell(candidates.first ?? NSHomeDirectory())) && claude \"$(cat \(shell(prompt)))\""
    }

    static func shell(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func start(_ entry: ProjectRegistry.Entry, mode: String? = nil, threads: [String]? = nil, root: URL) throws -> Onboarding.Run {
        let records = records(of: entry, root: root)
        let mode = mode ?? (entry.trackers.isEmpty ? "new" : "convert")
        // The threads run the checker from the copy of Broski that started the run.
        Onboarding.checker = Bundle.main.executablePath ?? binary
        let repos = repos(of: entry, root: root)
        let homes = homes(of: entry, records: records)
        // The thread that works in the tracker itself leads and answers everything; the others answer what they own.
        let named = (threads ?? self.threads(of: entry, records: records))
            .sorted { (repos[$0] == nil ? 0 : 1, $0) < (repos[$1] == nil ? 0 : 1, $1) }
        return try Onboarding.startRun(project: entry.notes, title: entry.name, mode: mode, repos: repos,
                                       threads: named, homes: homes, root: root)
    }

    /// thread → the folder its sessions run in, from the tracker's thread records (`repo`, else `worktree`,
    /// relative to the tracker).
    static func homes(of entry: ProjectRegistry.Entry, records: [TrackerRecord]) -> [String: String] {
        guard let tracker = entry.trackers.first else { return [:] }
        var out: [String: String] = [:]
        for record in records where record.kind == "thread" && record.source == tracker.id {
            guard let path = record.fields["repo"] ?? record.fields["worktree"] else { continue }
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : tracker.url.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            out[(record.recordID as NSString).lastPathComponent] = url.standardizedFileURL.path
        }
        return out
    }

    static func check(_ run: Onboarding.Run, only: String? = nil, root: URL) -> OnboardingCheck.Report {
        let registry = ProjectRegistry.load(from: root)
        let known = registry.entry(notes: run.project).map { Set(records(of: $0, root: root).map(\.recordID)) } ?? []
        let report = OnboardingCheck.check(run, only: only, knownRecords: known)
        if only == nil { OnboardingCheck.write(report, to: run.folder) }
        return report
    }

    static func summary(_ report: OnboardingCheck.Report) -> String {
        var lines = ["\(report.project) \(report.run): \(report.answers.count) answers, \(report.failures) fail, \(report.warnings) warn, \(report.missing.count) missing"]
        for a in report.answers where a.verdict != "ok" {
            lines.append("\(a.verdict.uppercased()) \(a.q).\(a.thread) (\(a.status)): " + (a.refs.filter { !$0.ok }.map { "\($0.ref): \($0.detail)" } + a.notes).joined(separator: "; "))
        }
        if !report.missing.isEmpty { lines.append("missing: " + report.missing.joined(separator: ", ")) }
        if !report.maps.isEmpty { lines.append("maps:\n" + report.maps.map { "  \($0)" }.joined(separator: "\n")) }
        if !report.shallow.isEmpty { lines.append("shallow: " + report.shallow.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// The draft manifest, beside (not over) the live one: `trackers/<id>.broski.draft.json`.
    static func assemble(_ run: Onboarding.Run, root: URL) throws -> URL {
        let registry = ProjectRegistry.load(from: root)
        // The tracker, or (for a project without one) its first code folder, read as docs.
        guard let entry = registry.entry(notes: run.project), let source = entry.trackers.first(where: \.readOnly) ?? Library.sources(of: entry).first(where: { $0.scope == .docs }) else {
            throw TrackerTemplate.Failure.unknown(run.project)
        }
        let report = check(run, root: root)
        let folder = root.appendingPathComponent("trackers", isDirectory: true)
        // A delta run adds to the manifest Broski reads now; a full run starts over from it (the project's overlay,
        // when it has one, else the preset that fits).
        let current = TrackerManifest.resolve(for: source, overlays: folder)
        let manifest = OnboardingCheck.assemble(run, report: report, source: source, base: run.mode == "delta" ? current : nil, preset: current)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(TrackerManifest.overlayName(source.id, draft: true))
        if run.mode == "new" { try writeAnswers(run, report: report, entry: entry, root: root) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: .atomic)
        return url
    }

    /// A new project's verified answers become part of its Broski tracker, so they're indexed and cited.
    static func writeAnswers(_ run: Onboarding.Run, report: OnboardingCheck.Report, entry: ProjectRegistry.Entry, root: URL) throws {
        let tracker = try newTracker(for: entry.notes, root: root)
        var text = "# What the threads said (\(run.id))\n\nVerified onboarding answers. Each cites its evidence.\n"
        for result in report.answers where result.verdict != "fail" {
            let answer = Onboarding.parseAnswer(run.folder.appendingPathComponent(result.file))
            let question = Onboarding.questions.first { $0.id == answer.q }?.text ?? answer.q
            text += "\n## \(answer.q) · \(answer.thread): \(question)\n\n\(answer.body)\n\nEvidence: "
                + result.refs.filter(\.ok).map { "`\($0.ref)`" }.joined(separator: ", ") + " · status \(answer.status)\n"
        }
        let url = tracker.appendingPathComponent("layers/onboarding/ANSWERS-\(run.id).md")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Approving a draft makes it the overlay Broski reads. The old overlay is kept beside it.
    static func approveDraft(trackerID: String, root: URL) throws {
        let folder = root.appendingPathComponent("trackers", isDirectory: true)
        let draft = folder.appendingPathComponent(TrackerManifest.overlayName(trackerID, draft: true))
        let live = folder.appendingPathComponent(TrackerManifest.overlayName(trackerID))
        let fm = FileManager.default
        if fm.fileExists(atPath: live.path) {
            let backup = folder.appendingPathComponent(trackerID.replacingOccurrences(of: "/", with: "__") + ".broski.previous.json")
            try? fm.removeItem(at: backup)
            try fm.moveItem(at: live, to: backup)
        }
        try fm.moveItem(at: draft, to: live)
        // A new manifest reads records the old one didn't: the next read is a fresh baseline, not a flood of "new".
        try? fm.removeItem(at: ChangeStream.stateFile(root: root, source: trackerID))
    }

    /// A Broski-owned tracker for a project without one, registered as an editable source.
    @discardableResult
    static func newTracker(for notes: String, root: URL) throws -> URL {
        var registry = ProjectRegistry.load(from: root)
        guard let i = registry.projects.firstIndex(where: { $0.notes == notes }) else { throw TrackerTemplate.Failure.unknown(notes) }
        let entry = registry.projects[i]
        let folder = try TrackerTemplate.create(project: notes, title: entry.name, about: entry.about, root: root)
        if !registry.projects[i].trackers.contains(where: { $0.url.standardizedFileURL.path == folder.standardizedFileURL.path }) {
            registry.projects[i].trackers.append(TrackerSource(id: notes, name: "\(entry.name) tracker", path: folder.path, readOnly: false))
            try registry.save(to: root)
        }
        return folder
    }

    // MARK: Keeping it current

    /// Every source of a project read once, by id (the command line and MCP have no Library to hold them).
    static func snapshots(of entry: ProjectRegistry.Entry, root: URL) -> [String: TrackerSnapshot] {
        let overlays = root.appendingPathComponent("trackers")
        return Dictionary(Library.sources(of: entry).map { ($0.id, TrackerReader.snapshot($0, project: entry.notes, overlays: overlays)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// How well the onboarding still fits. Cheap: the drift comes with each read's snapshot, and the runs are a few small files.
    static func health(for entry: ProjectRegistry.Entry, root: URL, records: [TrackerRecord], snapshots: [String: TrackerSnapshot]) -> Onboarding.Health {
        let drift = TrackerDrift.combined(entry.trackers.filter { $0.scope == .tracker }.compactMap { source in
            snapshots[source.id].map { (source: source.id, drift: $0.drift) }
        })
        let all = runs(for: entry.notes, root: root).compactMap(Onboarding.loadRun)
        // Every thread any run asked: a delta run asks only a few, so the latest alone would make the others look new.
        let asked = Set(all.flatMap(\.assign.keys))
        let tracker = entry.trackers.first?.id
        let named = Set(records.filter { $0.kind == "thread" && $0.source == tracker }.map { ($0.recordID as NSString).lastPathComponent })
        let leadRun = all.first { $0.mode != "delta" } ?? all.first
        let lead = leadRun?.assign.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
            ?? threads(of: entry, records: records).first ?? "main"
        // Before any run, nothing is "new": the whole project is still to onboard.
        return Onboarding.Health(drift: drift, newThreads: all.isEmpty ? [] : named.subtracting(asked).sorted(), latestRun: all.first, lead: lead)
    }

    /// Answers that checked out when the run was checked (ok or warn in its check.json) but fail now. On demand only:
    /// it re-verifies every citation. The run's own report is left as it was.
    static func staleAnswers(_ run: Onboarding.Run, root: URL) -> [String] {
        guard let before = OnboardingCheck.load(from: run.folder), before.answers.contains(where: { $0.verdict != "fail" }) else { return [] }
        let registry = ProjectRegistry.load(from: root)
        let known = registry.entry(notes: run.project).map { Set(records(of: $0, root: root).map(\.recordID)) } ?? []
        return OnboardingCheck.stale(before: before, now: OnboardingCheck.check(run, knownRecords: known))
    }

    struct NothingDrifted: Error, CustomStringConvertible {
        let project: String
        var description: String { "\(project)'s onboarding still fits: no drift, no new threads, no stale answers" }
    }

    /// A follow-up run that asks only about what drifted (see Onboarding.deltaAssign). Throws NothingDrifted when nothing did.
    static func startDelta(_ entry: ProjectRegistry.Entry, _ health: Onboarding.Health, stale: [String] = [], root: URL) throws -> Onboarding.Run {
        let assign = Onboarding.deltaAssign(health, stale: stale)
        guard !assign.isEmpty else { throw NothingDrifted(project: entry.name) }
        Onboarding.checker = Bundle.main.executablePath ?? binary
        let found = records(of: entry, root: root)
        return try Onboarding.startRun(project: entry.notes, title: entry.name, mode: "delta", repos: repos(of: entry, root: root),
                                       threads: assign.keys.sorted(), homes: homes(of: entry, records: found), assign: assign,
                                       note: Onboarding.deltaNote(health, stale: stale), root: root)
    }

    static func describe(_ health: Onboarding.Health, name: String) -> String {
        var lines = health.drifted ? ["\(name): the onboarding has drifted."] + health.lines.map { "- \($0)" }
            : ["\(name): no drift. Every file is mapped, every mapping finds its files, every status word is known."]
        lines.append(health.latestRun.map { "Latest onboarding run: \($0.id) (\($0.mode)), \($0.folder.path)" } ?? "No onboarding run yet.")
        return lines.joined(separator: "\n")
    }

    // MARK: Command line

    static func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Returns the exit code, or nil when the arguments aren't an onboarding command.
    @MainActor static func command(_ args: [String]) -> Int32? {
        let root = AppModel.notesRoot
        do {
            if let name = value(after: "--onboarding-health", in: args) {
                let registry = ProjectRegistry.load(from: root)
                guard let entry = registry.entry(named: name) ?? registry.entry(notes: name) else { out("No project \(name)"); return 2 }
                let snaps = snapshots(of: entry, root: root)
                let now = health(for: entry, root: root, records: snaps.values.flatMap(\.records), snapshots: snaps)
                out(describe(now, name: entry.name))
                if let run = now.latestRun {
                    let stale = staleAnswers(run, root: root)
                    out(stale.isEmpty ? "Every answer that checked out in \(run.id) still does." : "Stale answers in \(run.id): " + stale.joined(separator: ", "))
                }
                return 0
            }
            if let name = value(after: "--start-onboarding", in: args) {
                let registry = ProjectRegistry.load(from: root)
                guard let entry = registry.entry(named: name) ?? registry.entry(notes: name) else { out("No project \(name)"); return 2 }
                let run: Onboarding.Run
                if args.contains("--delta") {
                    let snaps = snapshots(of: entry, root: root)
                    let now = health(for: entry, root: root, records: snaps.values.flatMap(\.records), snapshots: snaps)
                    do {
                        run = try startDelta(entry, now, stale: now.latestRun.map { staleAnswers($0, root: root) } ?? [], root: root)
                    } catch let refusal as NothingDrifted {
                        out("\(refusal). No delta run started.")
                        return 1
                    }
                } else {
                    run = try start(entry, mode: value(after: "--mode", in: args),
                                    threads: value(after: "--threads", in: args).map { $0.split(separator: ",").map(String.init) }, root: root)
                }
                out("Run \(run.id) for \(entry.name): \(run.folder.path)")
                if let note = run.note { out("\n" + note) }
                for thread in run.assign.keys.sorted() {
                    out("\n[\(thread)] \(run.assign[thread]!.count) questions\n  \(forkCommand(thread: thread, run: run))")
                }
                return 0
            }
            if let path = value(after: "--check-onboarding", in: args) {
                guard let run = Onboarding.loadRun(URL(fileURLWithPath: path, isDirectory: true)) else { out("No run at \(path)"); return 2 }
                let report = check(run, only: value(after: "--only", in: args), root: root)
                out(summary(report))
                return report.failures > 0 ? 1 : 0
            }
            if let path = value(after: "--assemble-onboarding", in: args) {
                guard let run = Onboarding.loadRun(URL(fileURLWithPath: path, isDirectory: true)) else { out("No run at \(path)"); return 2 }
                out("Draft manifest: \(try assemble(run, root: root).path)")
                return 0
            }
            if let name = value(after: "--new-tracker", in: args) {
                let registry = ProjectRegistry.load(from: root)
                guard let entry = registry.entry(named: name) ?? registry.entry(notes: name) else { out("No project \(name)"); return 2 }
                out("Tracker: \(try newTracker(for: entry.notes, root: root).path)")
                return 0
            }
        } catch {
            out("Failed: \(error)")
            return 1
        }
        return nil
    }
}
