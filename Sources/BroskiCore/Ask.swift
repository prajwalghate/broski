import Foundation

/// "Ask Broski": a question answered from your own notes, with every claim pointing at the note it came from.
public enum Ask {
    public struct Answer: Equatable {
        /// Markdown, with citations as [[note-id]].
        public var markdown: String
        /// The notes cited, in the order they first appear.
        public var sources: [NoteRef]
        public var usedAI: Bool

        public init(markdown: String, sources: [NoteRef], usedAI: Bool) {
            self.markdown = markdown
            self.sources = sources
            self.usedAI = usedAI
        }
    }

    struct Reply: Decodable {
        var answer_markdown: String
    }

    static let system = """
    You are Broski, the user's companion across all their projects. Answer from ONLY the material provided: their own \
    captured notes (bugs, todos, ideas, QA observations, riffs, calls), each project's living page, and records read \
    straight from their projects' trackers (findings, decisions, launch steps, runbooks, threads, messages, docs). The \
    trackers are the source of truth; Broski only reads them.

    Rules:
    - Cite every fact right after it with the exact id in double brackets: notes like [[2026-10-16-0452-login-bug]], \
      tracker records like [[one:DEC-70]] or [[strado:DEC-14]]. Use ids exactly as listed; never a bare "DEC-14".
    - Evidence over prose. Say something is done, decided or closed only from a structured field (status, decided, \
      attested, closed). Text inside a step's detail or a doc saying "done" or "still open" is a note, not the state. \
      Records marked PROSE MAP may be out of date: never take a count or a state from them.
    - Live state (whether a launch step is ready or done, prices, what's deployed, health) comes ONLY from a block \
      marked "read live from the tracker's board at <time>": quote it with that time. Without one, say it's unknown \
      and point to the tracker's board. Never present an old recorded reading as current.
    - Give dates with states ("decided 2026-10-20"). Tracker times ending in Z are UTC; say so when giving a time.
    - The same id can exist in two projects (one:DEC-14 vs strado:DEC-14): if the question is ambiguous, cover both \
      or say which you mean.
    - When records disagree (an open decision overtaken by a later one, a doc contradicting a record), say so and \
      cite both. Suggest the fix; don't pretend it's done.
    - ARCHIVED records are history. GENERATED datasets: describe them, don't repeat their numbers.
    - You are read-only. Never offer to run commands, mainnet writes or to send messages. If something needs doing, \
      say who does it (the user, or which thread) and where it's written down.
    - If the material doesn't answer it, say so plainly and say what's missing. Never invent ids, paths or numbers.
    - Lead with the answer. Short sentences, then bullets for lists. Use his words, not jargon.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["answer_markdown"],
        "properties": ["answer_markdown": ["type": "string"]],
    ]

    /// The notes most worth showing Claude for this question (and that a no-AI answer lists).
    public static func context(for question: String, index: NotesIndex, catalog: ProjectCatalog, limit: Int = 14) -> (project: String?, hits: [SearchHit]) {
        let project = catalog.mentioned(in: question)?.name
        var hits = index.search(question, project: project, limit: limit)
        if hits.count < 4, project != nil {
            hits += index.search(question, limit: limit).filter { hit in !hits.contains { $0.ref.id == hit.ref.id } }
        }
        // Ids named in the question ("DEC-14", "ONE-X189") come first, from every project that has one.
        let named = mentionedIDs(question)
        if !named.isEmpty {
            let exact = index.refs.filter { ref in named.contains { ref.id.hasSuffix(":" + $0) || ref.id == $0 || ref.id.hasSuffix("/" + $0) } }
                .map { SearchHit(ref: $0, score: 100, snippet: "") }
            hits = exact + hits.filter { hit in !exact.contains { $0.ref.id == hit.ref.id } }
        }
        return (project, Array(hits.prefix(limit + named.count)))
    }

    /// Record ids written in a question: DEC-14, ACME-X12, SEC-C01, T-15.
    public static func mentionedIDs(_ question: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\b[A-Z]{1,5}-[A-Z]?\d+[A-Z]?\b"#) else { return [] }
        return re.matches(in: question, range: NSRange(question.startIndex..., in: question)).compactMap { Range($0.range, in: question).map { String(question[$0]) } }
    }

    /// `briefing` carries what search can't find: what's waiting on the user, what changed, live board readings.
    public static func answer(_ question: String, index: NotesIndex, catalog: ProjectCatalog,
                              pages: [ProjectPage], gateway: ModelGateway?, localOnly: Set<String> = [],
                              briefing: String = "", limit: Int = 14) async throws -> Answer {
        let (project, found) = context(for: question, index: index, catalog: catalog, limit: limit)
        // A question naming any local-only project stays on the Mac: its own words can carry what's kept local.
        // Every one is checked, since `project` is only the first name found ("is marketroom blocked by strado?").
        let namesLocal = catalog.projects.contains { localOnly.contains($0.name) && ProjectCatalog(projects: [$0]).mentioned(in: question) != nil }
        if namesLocal || project.map({ localOnly.contains($0) }) == true { return listing(question, hits: found) }
        // Projects kept local never reach a model.
        let hits = found.filter { !localOnly.contains($0.ref.project ?? "") }
        guard let gateway, !hits.isEmpty || project != nil || !briefing.isEmpty else {
            return listing(question, hits: found)
        }
        let relevantProjects = Set(([project] + hits.map(\.ref.project)).compactMap { $0 }).subtracting(localOnly)
        var lines = ["Question: \(question)", "Today: \(Date().formatted(date: .complete, time: .shortened))", ""]
        if !briefing.isEmpty { lines += [briefing, ""] }
        for page in pages where relevantProjects.contains(page.project) {
            lines.append("Living page of \(page.project):")
            lines.append(page.render().components(separatedBy: "\n---\n").last ?? "")
        }
        lines.append("Notes:")
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for hit in hits {
            let r = hit.ref
            let origin = r.source.map { "tracker \($0)" } ?? "note"
            lines.append("[\(r.id)] \(origin) · \(r.date == .distantPast ? "undated" : day.string(from: r.date)) · \(r.project ?? "Inbox") · \(r.open ? "open" : "not open") · \(r.title)"
                         + (r.body.isEmpty ? "" : " — \(r.body.replacingOccurrences(of: "\n", with: " ").prefix(r.source == nil ? 700 : 1400))"))
        }
        let request = ModelRequest(system: system, messages: [ModelMessage(role: .user, text: lines.joined(separator: "\n"))],
                                   maxTokens: 8000, effort: "medium")
        let reply = try await gateway.sendJSON(Reply.self, request, schema: schema, role: .everyday, project: project, task: "ask").value
        let known = Dictionary(index.refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let (markdown, sources) = resolve(reply.answer_markdown, known: known)
        return Answer(markdown: markdown, sources: sources, usedAI: true)
    }

    /// Without a model: the best-matching notes, so the question still gets you somewhere.
    static func listing(_ question: String, hits: [SearchHit]) -> Answer {
        guard !hits.isEmpty else {
            return Answer(markdown: "Nothing in your notes matches that yet.", sources: [], usedAI: false)
        }
        let body = hits.prefix(6).map { "- \($0.ref.title) [[\($0.ref.id)]]" }.joined(separator: "\n")
        return Answer(markdown: "Notes that match:\n\n" + body, sources: hits.prefix(6).map(\.ref), usedAI: false)
    }

    /// Keeps citations that point at real notes and drops invented ones.
    /// Code and brackets that aren't note ids (bash `[[ -f x ]]`, numpy `a[[0, 1]]`) pass through untouched.
    public static func resolve(_ markdown: String, known: [String: NoteRef]) -> (String, [NoteRef]) {
        var sources: [NoteRef] = []
        var out = ""
        var rest = Substring(markdown)
        while let next = nextBrackets(in: rest) {
            let (open, close) = next
            out += rest[..<open.lowerBound]
            let raw = String(rest[open.upperBound..<close.lowerBound])
            let id = raw.trimmingCharacters(in: .whitespaces)
            let literal = rest[open.lowerBound..<close.upperBound]
            rest = rest[close.upperBound...]
            if let ref = known[id] {
                if !sources.contains(ref) { sources.append(ref) }
                out += "[[\(id)]]"
            } else if !looksLikeCode(raw) {
                // An invented citation (an id, a padded id, a title): drop it, and the space it leaves before a space or punctuation.
                if out.last == " ", rest.first.map({ " \n.,;:!?)".contains($0) }) ?? true { out.removeLast() }
            } else {
                out += literal
            }
        }
        out += rest
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), sources)
    }

    /// Brackets that read as code rather than a citation, when they turn up outside backticks: a shell test
    /// (`[[ -f x ]]`, `[[ $a == b ]]`) or an index list (`a[[0, 1]]`). Anything else unknown is an invented cite.
    static func looksLikeCode(_ text: String) -> Bool {
        text.range(of: #"(^|\s)--?[A-Za-z]|[$=<>{}\\\[]|&&|\|\||^[\s\d,:.-]*$"#, options: .regularExpression) != nil
    }

    /// The next `[[` … `]]` outside code: fenced blocks and inline code spans are skipped.
    static func nextBrackets(in text: Substring) -> (open: Range<Substring.Index>, close: Range<Substring.Index>)? {
        var from = text.startIndex
        while let open = text[from...].range(of: "[[") {
            if let tick = text[from..<open.lowerBound].firstIndex(of: "`") {
                let fence = text[tick...].hasPrefix("```") ? "```" : "`"
                let after = text.index(tick, offsetBy: fence.count)
                if let end = text[after...].range(of: fence) {
                    from = end.upperBound
                } else if fence == "```" {
                    return nil  // An unclosed fence runs to the end: all code.
                } else {
                    from = after  // A lone backtick is just a character.
                }
                continue
            }
            guard var close = text[open.upperBound...].range(of: "]]") else { return nil }
            // An id with brackets of its own ("Meeting [draft]") closes on the last of "]]]".
            while text[open.upperBound..<close.lowerBound].filter({ $0 == "[" }).count > text[open.upperBound..<close.lowerBound].filter({ $0 == "]" }).count,
                  close.upperBound < text.endIndex, text[close.upperBound] == "]" {
                close = text.index(after: close.lowerBound)..<text.index(after: close.upperBound)
            }
            return (open, close)
        }
        return nil
    }

    /// Splits an answer into text and citation markers, for showing citations as numbered chips.
    public enum Piece: Equatable {
        case text(String)
        case cite(id: String, number: Int)
    }

    public static func pieces(_ markdown: String, sources: [NoteRef]) -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        var rest = Substring(markdown)
        while let next = nextBrackets(in: rest) {
            let (open, close) = next
            text += rest[..<open.lowerBound]
            let id = String(rest[open.upperBound..<close.lowerBound])
            // Only cited notes become chips; other brackets stay part of the text.
            if let index = sources.firstIndex(where: { $0.id == id }) {
                if !text.isEmpty { pieces.append(.text(text)) }
                text = ""
                pieces.append(.cite(id: id, number: index + 1))
            } else {
                text += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        text += rest
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }
}
