import Foundation

/// Verifies an onboarding run: every answer's evidence, against the files, git and transcripts. Read-only and cheap.
public enum OnboardingCheck {
    public struct RefResult: Codable, Equatable {
        public var ref: String
        public var ok: Bool
        public var detail: String
        public var quoted: Bool
    }

    public struct AnswerResult: Codable, Equatable {
        public var file: String
        public var q: String
        public var thread: String
        public var status: String
        public var verdict: String  // ok | warn | fail
        public var refs: [RefResult]
        public var notes: [String]
    }

    public struct Report: Codable, Equatable {
        public var run: String
        public var project: String
        public var checked: String
        public var answers: [AnswerResult]
        public var missing: [String]
        public var maps: [String]
        public var shallow: [String]

        public var failures: Int { answers.filter { $0.verdict == "fail" }.count }
        public var warnings: Int { answers.filter { $0.verdict == "warn" }.count }
    }

    /// Records known to exist (from Broski's index of the tracker), for record: refs.
    public static func check(_ run: Onboarding.Run, only thread: String? = nil, knownRecords: Set<String> = [],
                             claudeProjects: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")) -> Report {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: run.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Q-") && $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var results: [AnswerResult] = []
        var mapsOut: [String] = []
        var answered = Set<String>()
        for file in files {
            let answer = Onboarding.parseAnswer(file)
            if let thread, answer.thread != thread { continue }
            answered.insert("\(answer.q).\(answer.thread)")
            var notes = answer.problems
            if !Onboarding.questions.contains(where: { $0.id == answer.q }) { notes.append("unknown question \(answer.q)") }
            if let assigned = run.assign[answer.thread], !assigned.isEmpty, !assigned.contains(answer.q) { notes.append("\(answer.thread) wasn't assigned \(answer.q)") }
            let refs = answer.evidence.map { verify($0, run: run, known: knownRecords, claude: claudeProjects) }
            let strong = zip(answer.evidence, refs).filter { $0.0.strong && $0.1.ok }.count
            let quoted = refs.filter { $0.ok && $0.quoted }.count
            let absent = zip(answer.evidence, refs).filter { $0.0.kind == .absent && $0.1.ok }.count
            var verdict = refs.contains { !$0.ok } ? "fail" : "ok"
            switch answer.status {
            case "answered":
                if strong < 1 || quoted < 1 { verdict = "fail"; notes.append("answered needs at least 1 strong ref and 1 quoted ref that verifies") }
            case "partial":
                if strong < 1 { verdict = "fail"; notes.append("partial needs at least 1 strong ref") }
            case "gap":
                let threadRef = zip(answer.evidence, refs).contains { $0.0.kind == .thread && $0.1.ok }
                if absent < 1 && !threadRef { verdict = "fail"; notes.append("gap needs an absent: that verifies, or a thread: ref") }
            case "not-applicable":
                if answer.body.isEmpty || answer.evidence.isEmpty { verdict = "fail"; notes.append("not-applicable needs a reason and a ref") }
            default:
                verdict = "fail"
                notes.append("status must be answered, partial, gap or not-applicable")
            }
            if verdict == "ok", !notes.isEmpty { verdict = "warn" }
            if verdict == "ok", answer.evidence.allSatisfy({ ["readme.md", "claude.md", "agents.md"].contains(($0.target as NSString).lastPathComponent.lowercased()) }), !answer.evidence.isEmpty {
                verdict = "warn"
                notes.append("cites only README/CLAUDE.md: check the records themselves")
            }
            for map in answer.maps { mapsOut.append(dryRun(map, run: run)) }
            results.append(AnswerResult(file: file.lastPathComponent, q: answer.q, thread: answer.thread, status: answer.status,
                                        verdict: verdict, refs: refs, notes: notes))
        }
        var missing: [String] = []
        for (t, ids) in run.assign where thread == nil || t == thread {
            for id in ids where !answered.contains("\(id).\(t)") { missing.append("\(id).\(t)") }
        }
        // A thread whose answers mostly cite only prose is flagged shallow.
        var shallow: [String] = []
        for t in Set(results.map(\.thread)) {
            let mine = results.filter { $0.thread == t }
            if mine.count >= 4, mine.filter({ $0.notes.contains { $0.contains("cites only README") } }).count * 2 > mine.count { shallow.append(t) }
        }
        return Report(run: run.id, project: run.project, checked: FrontMatter.isoFormatter.string(from: Date()),
                      answers: results, missing: missing.sorted(), maps: mapsOut, shallow: shallow.sorted())
    }

    static func base(_ alias: String?, run: Onboarding.Run) -> URL? {
        let key = alias ?? "tracker"
        guard let path = run.repos[key] ?? (alias == nil ? run.repos.values.first : nil) else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    static func verify(_ e: Onboarding.Evidence, run: Onboarding.Run, known: Set<String>, claude: URL) -> RefResult {
        let label = "\(e.kind.rawValue):\(e.alias.map { "@\($0):" } ?? "")\(e.target)"
        func result(_ ok: Bool, _ detail: String, quoted: Bool = false) -> RefResult { RefResult(ref: label, ok: ok, detail: detail, quoted: quoted) }
        switch e.kind {
        case .pr, .url:
            return result(true, "unverified offline (doesn't count)")
        case .file, .receipt:
            guard let root = base(e.alias, run: run) else { return result(false, "unknown alias @\(e.alias ?? "")") }
            if Forbidden.contains(e.target) || e.target.contains("..") { return result(false, "not allowed: secret-shaped or outside the repo") }
            let url = root.appendingPathComponent(e.target)
            guard let data = try? Data(contentsOf: url) else {
                return result(false, "\(e.target) not found" + (suggestion(for: e.target, in: root).map { " (did you mean \($0)?)" } ?? ""))
            }
            var text = String(decoding: data, as: UTF8.self)
            let lineCount = text.components(separatedBy: "\n").count
            if let lines = e.lines {
                guard lines.upperBound <= lineCount else { return result(false, "lines \(lines.lowerBound)-\(lines.upperBound) past the end (\(lineCount) lines)") }
                let all = text.components(separatedBy: "\n")
                text = all[max(0, lines.lowerBound - 4)..<min(all.count, lines.upperBound + 3)].joined(separator: "\n")
            }
            guard let quote = e.quote, !quote.isEmpty else { return result(true, "exists") }
            if quote.count > 220 { return result(false, "quote longer than 200 characters") }
            let needle = Onboarding.normalize(quote)
            if Onboarding.normalize(text).contains(needle) { return result(true, "quote found", quoted: true) }
            // JSON: also match inside decoded string values.
            if url.pathExtension.lowercased().hasPrefix("json"), let json = try? JSONSerialization.jsonObject(with: data) {
                if strings(json).contains(where: { Onboarding.normalize($0).contains(needle) }) { return result(true, "quote found in a JSON value", quoted: true) }
            }
            return result(false, "quote not found in \(e.target)")
        case .commit:
            #if os(macOS)
            guard let root = base(e.alias, run: run) else { return result(false, "unknown alias @\(e.alias ?? "")") }
            guard GitSnapshotFS.git(root, ["cat-file", "-e", "\(e.target)^{commit}"]) != nil else { return result(false, "commit \(e.target) not in \(root.lastPathComponent)") }
            guard let quote = e.quote, !quote.isEmpty else { return result(true, "commit exists") }
            let message = GitSnapshotFS.git(root, ["log", "-1", "--format=%B", e.target]).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return Onboarding.normalize(message).contains(Onboarding.normalize(quote))
                ? result(true, "quote in the commit message", quoted: true) : result(false, "quote not in the commit message")
            #else
            return result(true, "commit not checkable here")
            #endif
        case .record:
            let id = e.target
            let hit = known.contains(id) || known.contains { $0.hasSuffix(":" + id) || $0.hasSuffix("/" + id) }
            if hit { return result(true, "record exists") }
            // The tracker's id registry, if there is one.
            if let root = base(nil, run: run) {
                for registry in ["tracker/allocated-ids.tsv", "register/allocated-ids.tsv", "ids.tsv"] {
                    if let text = try? String(contentsOf: root.appendingPathComponent(registry), encoding: .utf8),
                       text.components(separatedBy: "\n").contains(where: { $0.hasPrefix(id + "\t") }) { return result(true, "in the id registry") }
                }
            }
            return result(false, "record \(id) not found")
        case .thread:
            let parts = e.target.split(separator: "#", maxSplits: 1).map(String.init)
            let path = parts[0].split(separator: "/").map(String.init)
            guard path.count == 2 else { return result(false, "thread: must be <claude-project-slug>/<session-uuid>") }
            let file = claude.appendingPathComponent(path[0]).appendingPathComponent(path[1] + ".jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { return result(false, "no transcript \(path[1]) in \(path[0])") }
            guard parts.count > 1 || e.quote != nil else { return result(true, "transcript exists") }
            guard let handle = try? FileHandle(forReadingFrom: file) else { return result(false, "can't read the transcript") }
            defer { try? handle.close() }
            // Stream the transcript line by line; never load the whole thing.
            var buffer = Data()
            let messageID = parts.count > 1 ? parts[1] : nil
            let needle = e.quote.map(Onboarding.normalize)
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let messageID, !line.contains(messageID) { continue }
                    if let needle, !Onboarding.normalize(line).contains(needle) { continue }
                    return result(true, "found in the transcript", quoted: needle != nil)
                }
            }
            return result(false, messageID != nil ? "message \(messageID!) not in the transcript" : "quote not in the transcript")
        case .absent:
            guard let root = base(e.alias, run: run) else { return result(false, "unknown alias @\(e.alias ?? "")") }
            let fs = WorkingTreeFS(root: root)
            let matches = fs.files.filter { Glob.matches($0, e.target) }
            let dirMatches = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent((e.target as NSString).deletingLastPathComponent).path)) ?? []
            if matches.isEmpty && (e.target.hasSuffix("/**") ? dirMatches.isEmpty : true) { return result(true, "nothing matches (gap proven)") }
            return result(false, "\(matches.count) files match \(e.target), e.g. \(matches.first ?? "")")
        }
    }

    static func strings(_ json: Any) -> [String] {
        switch json {
        case let s as String: return [s]
        case let a as [Any]: return a.flatMap(strings)
        case let d as [String: Any]: return d.values.flatMap(strings)
        default: return []
        }
    }

    static func suggestion(for path: String, in root: URL) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        return WorkingTreeFS(root: root).files.first { ($0 as NSString).lastPathComponent.lowercased() == name }
    }

    /// "ops.runbook <- @tracker:tracker/data/runbook.json | json-records | value.phases[].actions[]" → how many records it reads.
    static func dryRun(_ map: String, run: Onboarding.Run) -> String {
        guard let source = parseMap(map) else { return "✗ can't read map: \(map)" }
        guard let root = base(source.alias, run: run) else { return "✗ unknown alias in: \(map)" }
        let manifest = TrackerManifest(id: "dry", title: "dry", adapter: "dry", core: [source.section: [source.source]])
        let fs = WorkingTreeFS(root: root)
        let context = Context(manifest: manifest, source: TrackerSource(id: "dry", name: "dry", path: root.path), project: run.project, fs: fs, root: root)
        let paths = source.source.file.map { [$0] } ?? fs.files.filter { Glob.matches($0, source.source.glob ?? "") }
        let records = paths.flatMap { context.read($0, source.source, section: CoreSection(rawValue: source.section) ?? .layer, layer: source.section) }
        return (records.isEmpty ? "✗ " : "✓ ") + "\(source.label): \(records.count) records from \(paths.count) files"
    }

    public struct ParsedMap {
        public var section: String
        public var label: String
        public var alias: String?
        public var source: TrackerManifest.Source
    }

    public static func parseMap(_ map: String) -> ParsedMap? {
        let sides = map.components(separatedBy: "<-")
        guard sides.count == 2 else { return nil }
        let label = sides[0].trimmingCharacters(in: .whitespaces)
        let target = label.split(separator: ".").first.map(String.init) ?? label
        let kind = label.split(separator: ".").dropFirst().first.map(String.init)
        let parts = sides[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2 else { return nil }
        var path = parts[0]
        var alias: String?
        if path.hasPrefix("@"), let sep = path.dropFirst().firstIndex(of: ":") {
            alias = String(path[path.index(after: path.startIndex)..<sep])
            path = String(path[path.index(after: sep)...])
        }
        let isGlob = path.contains("*") || path.contains("{")
        let section = target == "layer" ? "layer" : target
        let source = TrackerManifest.Source(reader: parts[1], glob: isGlob ? path : nil, file: isGlob ? nil : path,
                                            path: parts.count > 2 && !parts[2].contains("=") ? parts[2] : nil, kind: kind)
        return ParsedMap(section: section, label: label, alias: alias, source: source)
    }

    // MARK: Writing the report

    public static func write(_ report: Report, to folder: URL) {
        var text = "# Check · \(report.project) · \(report.run)\n\nChecked \(report.checked). \(report.answers.count) answers · \(report.failures) fail · \(report.warnings) warn · \(report.missing.count) missing\n\n"
        for a in report.answers {
            text += "- \(a.q).\(a.thread)  \(a.status)  \(a.verdict.uppercased())  " + a.refs.map { "\($0.ok ? "✓" : "✗") \($0.ref) (\($0.detail))" }.joined(separator: "; ")
            if !a.notes.isEmpty { text += "  — " + a.notes.joined(separator: "; ") }
            text += "\n"
        }
        if !report.missing.isEmpty { text += "\nMissing: " + report.missing.joined(separator: ", ") + "\n" }
        if !report.maps.isEmpty { text += "\nMaps dry run:\n" + report.maps.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !report.shallow.isEmpty { text += "\nShallow (mostly README citations): " + report.shallow.joined(separator: ", ") + "\n" }
        try? text.write(to: folder.appendingPathComponent("CHECK.md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(report).write(to: folder.appendingPathComponent("check.json"))
    }

    /// The report a run was last checked with (its check.json), if it has one.
    public static func load(from folder: URL) -> Report? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("check.json")) else { return nil }
        return try? JSONDecoder().decode(Report.self, from: data)
    }

    /// Answers that passed (ok or warn) in `before` and fail in `now`: what they cite has moved or changed since.
    public static func stale(before: Report, now: Report) -> [String] {
        let passed = Set(before.answers.filter { $0.verdict != "fail" }.map(\.file))
        return now.answers.filter { passed.contains($0.file) && $0.verdict == "fail" }.map(\.file).sorted()
    }

    // MARK: Assembling the manifest

    /// Verified answers' maps → a draft manifest, starting from `preset` (the project's own manifest, when it has
    /// one), else the preset that fits the tracker. A delta run passes
    /// `base`, the manifest Broski reads now, so the last run's maps stay; its mappings that find nothing are dropped,
    /// since the delta's answers say where those files went.
    public static func assemble(_ run: Onboarding.Run, report: Report, source: TrackerSource, base: TrackerManifest? = nil,
                                preset: TrackerManifest? = nil) -> TrackerManifest {
        var manifest = base ?? preset ?? TrackerPresets.detect(source)
        if base != nil {
            let files = WorkingTreeFS(root: source.url, docsOnly: source.scope == .docs).files
            func live(_ s: TrackerManifest.Source) -> Bool { !TrackerReader.isDead(s, matched: TrackerReader.matches(s, in: files), files: files) }
            manifest.core = manifest.core.mapValues { $0.filter(live) }
            manifest.layers = manifest.layers?.map { layer in
                var kept = layer
                kept.sources = layer.sources.filter(live)
                return kept
            }
        }
        let verified = Set(report.answers.filter { $0.verdict != "fail" }.map(\.file))
        var extra: [String: [TrackerManifest.Source]] = [:]
        var layers: [TrackerManifest.Layer] = manifest.layers ?? []
        for file in verified {
            let answer = Onboarding.parseAnswer(run.folder.appendingPathComponent(file))
            for map in answer.maps {
                guard let parsed = parseMap(map), parsed.alias == nil || parsed.alias == "tracker" else { continue }
                if parsed.label.hasPrefix("layer.") {
                    let name = String(parsed.label.dropFirst(6)).split(separator: ".").first.map(String.init) ?? "layer"
                    if let i = layers.firstIndex(where: { $0.name == name }) { layers[i].sources.append(parsed.source) }
                    else { layers.append(.init(name: name, title: name.capitalized, sources: [parsed.source])) }
                } else {
                    extra[parsed.section, default: []].append(parsed.source)
                }
            }
        }
        for (section, sources) in extra {
            var existing = manifest.core[section] ?? []
            for s in sources where !existing.contains(where: { $0.file == s.file && $0.glob == s.glob && $0.path == s.path }) { existing.append(s) }
            manifest.core[section] = existing
        }
        manifest.layers = layers
        return manifest
    }
}
