import Foundation

/// The living page for one project: where it stands, open bugs and todos, ideas, decisions and open
/// questions, each line citing the notes it came from. Kept as `projects/<name>/PROJECT.md` so it's readable
/// anywhere (Finder, Obsidian, GitHub) and by Claude Code through Broski's MCP server.
public struct ProjectPage: Equatable {
    public static let fileName = "PROJECT.md"

    public struct Line: Equatable, Codable {
        public var text: String
        /// Note ids (`NoteRef.id`) this line is based on.
        public var cites: [String]

        public init(text: String, cites: [String] = []) {
            self.text = text
            self.cites = cites
        }
    }

    public struct Section: Equatable {
        public var title: String
        public var lines: [Line]

        public init(title: String, lines: [Line]) {
            self.title = title
            self.lines = lines
        }
    }

    public enum Source: String { case claude, rules }

    public var project: String
    public var summary: String
    public var sections: [Section]
    public var actions: [ProposedAction]
    public var compiled: Date
    public var source: Source
    /// Which notes (and versions) this page was built from; unchanged means no rebuild needed.
    public var fingerprint: String

    public init(project: String, summary: String, sections: [Section], actions: [ProposedAction] = [],
                compiled: Date = Date(), source: Source, fingerprint: String) {
        self.project = project
        self.summary = summary
        self.sections = sections
        self.actions = actions
        self.compiled = compiled
        self.source = source
        self.fingerprint = fingerprint
    }

    public var allCitations: [String] { sections.flatMap { $0.lines.flatMap(\.cites) } }

    // MARK: Fingerprint

    /// Whether Claude should rewrite a page on its own now (the Refresh button always does): a page it never wrote is
    /// due; after that, changed notes wait six hours from the last rewrite, and tracker-only changes (a thread pushing
    /// again) a day. The rules page keeps it current in between, at no cost.
    public static func rewriteDue(compiled: Date?, notesChanged: Bool, now: Date = Date()) -> Bool {
        guard let compiled else { return true }
        return now.timeIntervalSince(compiled) >= (notesChanged ? 6 : 24) * 3600
    }

    public static func fingerprint(_ refs: [NoteRef]) -> String {
        var hash: UInt64 = 1469598103934665603
        for ref in refs.sorted(by: { $0.id < $1.id }) {
            // The content, not just the date: an edit in Obsidian or Finder leaves `updated` alone.
            // File dates aren't used because they churn under iCloud.
            let key = "\(ref.id)|\(Int(ref.date.timeIntervalSince1970))|\(ref.open)|\(ref.kind.rawValue)|\(ref.priority.rawValue)|"
                + "\(ref.source ?? "")|\(ref.title)|\(ref.body)\u{1E}"
            for byte in key.utf8 {
                hash = (hash ^ UInt64(byte)) &* 1099511628211
            }
        }
        // Versioned, so a change of formula reads as a deliberate one-off rebuild of every page.
        return "v2-" + String(hash, radix: 16)
    }

    /// One line of text: a newline inside a bullet or the summary would break the page when it's read back.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Markdown

    /// `- Login stays disabled after paste [[2026-10-16-0452-login]] [[qa-1#3]]`
    public func render() -> String {
        var fields: [(String, String?)] = [
            ("compiled", FrontMatter.isoFormatter.string(from: compiled)),
            ("source", source.rawValue),
            ("fingerprint", fingerprint),
        ]
        if !actions.isEmpty, let data = try? JSONEncoder().encode(actions), let json = String(data: data, encoding: .utf8) {
            fields.append(("actions", json))
        }
        var out = "# \(project)\n\n"
        out += "_Kept up to date by Broski from your notes. Edit the notes, not this page._\n\n"
        let summaryLine = Self.oneLine(summary)
        if !summaryLine.isEmpty { out += summaryLine + "\n\n" }
        for section in sections where !section.lines.isEmpty {
            out += "## \(section.title)\n\n"
            for line in section.lines {
                out += "- " + Self.oneLine(line.text) + line.cites.map { " [[\($0)]]" }.joined() + "\n"
            }
            out += "\n"
        }
        return FrontMatter.render(fields, body: out)
    }

    public static func parse(_ text: String, project: String) -> ProjectPage? {
        let (fields, body) = FrontMatter.split(text)
        guard let compiled = fields["compiled"].flatMap({ FrontMatter.isoFormatter.date(from: $0) }) else { return nil }
        var summary: [String] = []
        var sections: [Section] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") || line.hasPrefix("_Kept up to date") || line.isEmpty { continue }
            if line.hasPrefix("## ") {
                sections.append(Section(title: String(line.dropFirst(3)), lines: []))
            } else if line.hasPrefix("- "), !sections.isEmpty {
                sections[sections.count - 1].lines.append(parseLine(String(line.dropFirst(2))))
            } else if sections.isEmpty {
                summary.append(line)
            }
        }
        var actions: [ProposedAction] = []
        if let json = fields["actions"], let data = json.data(using: .utf8) {
            actions = (try? JSONDecoder().decode([ProposedAction].self, from: data)) ?? []
        }
        return ProjectPage(project: project, summary: summary.joined(separator: "\n"), sections: sections, actions: actions,
                           compiled: compiled, source: Source(rawValue: fields["source"] ?? "") ?? .rules,
                           fingerprint: fields["fingerprint"] ?? "")
    }

    public static func parseLine(_ text: String) -> Line {
        var cites: [String] = []
        var rest = text
        while let open = rest.range(of: " [[", options: .backwards), rest.hasSuffix("]]") {
            // The last " [[" opens the last cite, so an id with brackets of its own ("Meeting [draft]") reads whole.
            let id = String(rest[open.upperBound..<rest.index(rest.endIndex, offsetBy: -2)])
            guard !id.isEmpty, !id.contains("]]") else { break }
            cites.insert(id, at: 0)
            rest = String(rest[..<open.lowerBound])
        }
        return Line(text: rest, cites: cites)
    }

    public static func file(for project: String, in store: ItemStore) -> URL {
        store.folder(for: project).appendingPathComponent(fileName)
    }

    public static func load(_ project: String, from store: ItemStore) -> ProjectPage? {
        guard let text = try? String(contentsOf: file(for: project, in: store), encoding: .utf8) else { return nil }
        return parse(text, project: project)
    }

    public func save(to store: ItemStore) throws {
        let url = Self.file(for: project, in: store)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try render().write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Something the brain suggests doing about the notes, which you approve or dismiss.
public struct ProposedAction: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable, CaseIterable {
        /// File a GitHub or Linear issue for a bug.
        case issue
        /// Mark notes done that look finished.
        case markDone = "mark_done"
        /// Merge notes that say the same thing.
        case merge
        /// Raise the priority of something that keeps coming up.
        case prioritize
        /// Hand a task to Claude Code with the context it needs.
        case claudePrompt = "claude_prompt"
        /// A question worth answering before going further.
        case decide
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var cites: [String]
    public var dismissed: Bool

    public init(id: String = UUID().uuidString, kind: Kind, title: String, detail: String = "", cites: [String] = [], dismissed: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.cites = cites
        self.dismissed = dismissed
    }
}

// MARK: Building pages

public enum ProjectPageBuilder {
    /// The page without AI: grouped straight from the notes. Always available, instantly.
    public static func rules(project: String, refs: [NoteRef], items: [Item], sessions: [Session]) -> ProjectPage {
        let open = items.filter { $0.status != .done }
        func total(_ kind: NoteKind) -> Int { open.filter { $0.kind == kind }.count }
        // A section shows the top 12; past that it says how many more, so it never looks complete when it isn't.
        func lines(_ kind: NoteKind) -> [ProjectPage.Line] {
            let shown = open.filter { $0.kind == kind }
                .sorted { ($0.priority, $0.updated) > ($1.priority, $1.updated) }
                .prefix(12)
                .map { ProjectPage.Line(text: $0.title + ($0.priority >= .high ? " (\($0.priority.rawValue))" : ""), cites: [$0.id]) }
            let more = total(kind) - shown.count
            return Array(shown) + (more > 0 ? [ProjectPage.Line(text: "+\(more) more")] : [])
        }
        let bugs = lines(.bug), todos = lines(.todo), ideas = lines(.idea)
        let recent = items.sorted { $0.updated > $1.updated }.prefix(5).map {
            ProjectPage.Line(text: "\($0.kind.rawValue.capitalized): \($0.title)", cites: [$0.id])
        }
        let sessionLines = sessions.prefix(3).map { session in
            ProjectPage.Line(text: "\(session.kind.label) “\(session.title)”, \(session.entries.count) captures" + (session.isActive ? ", still running" : ""))
        }
        var parts: [String] = []
        // The real totals, not the lines shown.
        let (bugCount, todoCount, ideaCount) = (total(.bug), total(.todo), total(.idea))
        if bugCount > 0 { parts.append("\(bugCount) open bug\(bugCount == 1 ? "" : "s")") }
        if todoCount > 0 { parts.append("\(todoCount) todo\(todoCount == 1 ? "" : "s")") }
        if ideaCount > 0 { parts.append("\(ideaCount) idea\(ideaCount == 1 ? "" : "s")") }
        let summary = parts.isEmpty ? "Nothing open right now." : parts.joined(separator: ", ").capitalizedFirst + "."
        return ProjectPage(project: project, summary: summary, sections: [
            .init(title: "Open bugs", lines: bugs),
            .init(title: "To do", lines: todos),
            .init(title: "Ideas", lines: ideas),
            .init(title: "Sessions", lines: Array(sessionLines)),
            .init(title: "Recently", lines: Array(recent)),
        ], source: .rules, fingerprint: ProjectPage.fingerprint(refs))
    }

    struct Compiled: Decodable {
        struct Line: Decodable { var text: String; var cites: [String] }
        struct Action: Decodable { var kind: String; var title: String; var detail: String; var cites: [String] }
        var summary: String
        var where_it_stands: [Line]
        var open_bugs: [Line]
        var todos: [Line]
        var ideas: [Line]
        var decisions: [Line]
        var open_questions: [Line]
        var actions: [Action]
    }

    static let system = """
    You keep the living page for one of the user's projects in Broski, their capture tool. The notes are things \
    they said, typed, clipped or screenshotted while working: bugs, todos, ideas, decisions, observations from \
    QA sessions. Write the page a busy solo builder reads in 30 seconds to know where the project stands.

    Rules:
    - Only state what the notes support. Every line cites the note ids it comes from (exact ids from the list).
    - Merge notes that say the same thing into one line citing all of them. Drop items marked done unless they \
      explain a decision.
    - Plain, short lines in the user's own terms. No filler, no headings inside lines, no emoji.
    - summary: 1–2 sentences on where the project is right now and what matters most next.
    - where_it_stands: 2–5 lines on current focus and recent progress.
    - decisions: things the user settled ("we'll use X", "not doing Y"). open_questions: things still undecided.
    - actions: up to 4 concrete suggestions the user can approve with one click. kinds: issue (file a bug as an \
      issue), mark_done (a note looks finished), merge (notes repeat each other), prioritize (keeps coming up), \
      claude_prompt (a task to hand to Claude Code; put the ready-to-paste prompt in detail), decide (a question \
      blocking progress). Skip actions rather than invent weak ones.
    """

    static let schema: [String: Any] = {
        let line: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["text", "cites"],
            "properties": ["text": ["type": "string"], "cites": ["type": "array", "items": ["type": "string"]]],
        ]
        let lines: [String: Any] = ["type": "array", "items": line]
        let action: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["kind", "title", "detail", "cites"],
            "properties": [
                "kind": ["type": "string", "enum": ProposedAction.Kind.allCases.map(\.rawValue)],
                "title": ["type": "string"], "detail": ["type": "string"],
                "cites": ["type": "array", "items": ["type": "string"]],
            ],
        ]
        return [
            "type": "object", "additionalProperties": false,
            "required": ["summary", "where_it_stands", "open_bugs", "todos", "ideas", "decisions", "open_questions", "actions"],
            "properties": [
                "summary": ["type": "string"], "where_it_stands": lines, "open_bugs": lines, "todos": lines,
                "ideas": lines, "decisions": lines, "open_questions": lines,
                "actions": ["type": "array", "items": action],
            ],
        ]
    }()

    /// The page compiled by the everyday model from the project's notes. Citations that don't match a real note are dropped.
    public static func compile(project: String, refs: [NoteRef], previous: ProjectPage?, gateway: ModelGateway,
                               effort: String = "medium", localOnly: Bool = false) async throws -> ProjectPage {
        let known = Set(refs.map(\.id))
        let listed = refs.sorted { $0.date > $1.date }.prefix(160)
        var lines = ["Project: \(project)", "Today: \(Date().formatted(date: .abbreviated, time: .omitted))", "", "Notes (newest first):"]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for ref in listed {
            let body = ref.body.replacingOccurrences(of: "\n", with: " ").prefix(500)
            lines.append("[\(ref.id)] \(day.string(from: ref.date)) · \(ref.kind.rawValue) · \(ref.open ? "open" : "done") · \(ref.title)" + (body.isEmpty ? "" : " — \(body)"))
        }
        if let previous, !previous.summary.isEmpty {
            lines += ["", "Previous summary (update it, don't repeat it blindly): \(previous.summary)"]
        }
        let request = ModelRequest(system: system, messages: [ModelMessage(role: .user, text: lines.joined(separator: "\n"))],
                                   maxTokens: 16000, effort: effort, timeout: 180)
        let out = try await gateway.sendJSON(Compiled.self, request, schema: schema, role: .everyday, project: project,
                                             localOnly: localOnly, task: "page").value
        // Known ids only, each once, in order: a cite listed twice would make an action act on one note twice.
        func cites(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { known.contains($0) && seen.insert($0).inserted }
        }
        func clean(_ lines: [Compiled.Line]) -> [ProjectPage.Line] {
            // Same as what render() writes, so the page on screen matches the one read back from disk.
            lines.map { ProjectPage.Line(text: ProjectPage.oneLine($0.text), cites: cites($0.cites)) }
                .filter { !$0.text.isEmpty }
        }
        let kept = previous?.actions ?? []
        let actions = out.actions.compactMap { a -> ProposedAction? in
            guard let kind = ProposedAction.Kind(rawValue: a.kind) else { return nil }
            // A suggestion you already dismissed stays dismissed.
            if let old = kept.first(where: { $0.kind == kind && $0.title.lowercased() == a.title.lowercased() }) { return old }
            return ProposedAction(kind: kind, title: a.title, detail: a.detail, cites: cites(a.cites))
        }
        return ProjectPage(project: project, summary: ProjectPage.oneLine(out.summary), sections: [
            .init(title: "Where it stands", lines: clean(out.where_it_stands)),
            .init(title: "Open bugs", lines: clean(out.open_bugs)),
            .init(title: "To do", lines: clean(out.todos)),
            .init(title: "Ideas", lines: clean(out.ideas)),
            .init(title: "Decisions", lines: clean(out.decisions)),
            .init(title: "Open questions", lines: clean(out.open_questions)),
        ], actions: actions, source: .claude, fingerprint: ProjectPage.fingerprint(refs))
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
