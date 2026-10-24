import Foundation

public enum NoteKind: String, Codable, CaseIterable {
    case note, idea, todo, bug
}

public enum Destination: Equatable {
    case inbox
    case project(Project)
    /// A project named in speech that has no folder or notes file yet.
    case newProject(String)

    public var displayName: String {
        switch self {
        case .inbox: return "inbox"
        case .project(let p): return p.name
        case .newProject(let name): return name
        }
    }
}

public struct ParsedNote: Equatable {
    public var destination: Destination
    public var kind: NoteKind
    public var body: String
    public var cancelled: Bool

    public init(destination: Destination, kind: NoteKind, body: String, cancelled: Bool = false) {
        self.destination = destination
        self.kind = kind
        self.body = body
        self.cancelled = cancelled
    }
}

/// Things you can say to Broski that aren't notes.
public enum VoiceCommand: Equatable {
    /// "open the dashboard", "show my notes", "show the strado notes"
    case openDashboard(project: Project?)
}

/// Turns a dictated sentence into a routed note:
/// "In the trading bot project, add a todo: retry failed orders" ->
/// (project trading-bot, todo, "Retry failed orders").
public struct NoteParser {
    public var catalog: ProjectCatalog

    public init(catalog: ProjectCatalog) {
        self.catalog = catalog
    }

    public func parse(_ raw: String) -> ParsedNote {
        var text = TextTools.trimLeadingSeparators(raw)
        text = TextTools.trimLeadingSeparators(Self.leadingFiller.replace(in: text, with: ""))

        if Self.cancel.matches(text) {
            return ParsedNote(destination: .inbox, kind: .note, body: "", cancelled: true)
        }

        var kinds: [NoteKind] = []
        var destination: Destination = .inbox
        var rest = text
        if let route = route(text) {
            destination = route.destination
            rest = route.rest
            if let k = route.kind { kinds.append(k) }
        }

        var body = TextTools.trimLeadingSeparators(rest)
        for _ in 0..<2 {
            guard let (stripped, kind) = Self.stripCommand(body) else { break }
            body = TextTools.trimLeadingSeparators(stripped)
            if let kind { kinds.append(kind) }
        }
        if kinds.isEmpty, let g = Self.kindLeadIn.groups(in: body), let k = Self.kind(from: g["kind"]) {
            kinds.append(k)
        }

        let kind = kinds.first { $0 != .note } ?? .note
        return ParsedNote(destination: destination, kind: kind, body: TextTools.capitalizingFirst(body))
    }

    /// A short command instead of a note. Only whole sentences count, so "show the pricing page to Sam" stays a note.
    public func command(in raw: String) -> VoiceCommand? {
        let text = TextTools.trimSeparators(Self.leadingFiller.replace(in: TextTools.trimLeadingSeparators(raw), with: ""))
        guard let g = Self.openCommand.groups(in: text), let target = g["what"] else { return nil }
        let what = TextTools.trimSeparators(target.lowercased())
        if Self.dashboardWords.contains(TextTools.squash(what)) { return .openDashboard(project: nil) }
        if let m = Self.projectTarget.groups(in: what), let name = m["proj"], let p = catalog.match(Self.cleanProjectPhrase(name)) {
            return .openDashboard(project: p)
        }
        return nil
    }

    static let dashboardWords: Set<String> = [
        "dashboard", "thedashboard", "mydashboard", "broskidashboard", "app", "theapp", "broski", "broskiapp",
        "notes", "mynotes", "allnotes", "allmynotes", "allthenotes", "thenotes", "inbox", "myinbox", "theinbox",
        "myideas", "ideas", "mytodos", "todos", "everything",
    ]
    static let openCommand = Pattern(#"^(?:please\s+)?(?:open|show|display|go\s+to|pull\s+up)\s+(?:me\s+)?(?<what>.{1,60}?)(?:\s+please)?[.!?]*$"#)
    static let projectTarget = Pattern(#"^(?:the\s+|my\s+)?(?:notes\s+for\s+|notes\s+in\s+)?(?:the\s+)?(?<proj>[^,:;.]{1,40}?)(?:\s+(?:project|notes|repo|app|ideas|todos))?$"#)

    // MARK: Routing

    struct Route {
        var destination: Destination
        var rest: String
        var kind: NoteKind?
    }

    func route(_ text: String) -> Route? {
        // "in the X project, ..." / "in project X, ..." — the word "project" makes intent clear,
        // so an unknown name becomes a new project.
        for pattern in [Self.prepThenProjectWord, Self.projectWordThenName] {
            if let g = pattern.groups(in: text), let phrase = g["proj"],
               let dest = resolve(phrase, projectWord: g["pw"], allowNew: true) {
                return Route(destination: dest, rest: g["rest"] ?? "", kind: nil)
            }
        }
        // "add a note to X: ...", "idea for X: ..." — only new if they also said "project".
        for pattern in [Self.commandThenProject, Self.kindThenProject] {
            if let g = pattern.groups(in: text), let phrase = g["proj"],
               let dest = resolve(phrase, projectWord: g["pw"], allowNew: g["pw"] != nil) {
                return Route(destination: dest, rest: g["rest"] ?? "", kind: Self.kind(from: g["kind"]))
            }
        }
        // Known project names without the word "project".
        if let g = Self.commandThenPrep.groups(in: text), let after = g["after"],
           let hit = knownPrefix(after, needsDelimiter: false) {
            return Route(destination: .project(hit.project), rest: hit.rest, kind: Self.kind(from: g["kind"]))
        }
        if let g = Self.prepThenAnything.groups(in: text), let after = g["after"],
           let hit = knownPrefix(after, needsDelimiter: false) {
            return Route(destination: .project(hit.project), rest: hit.rest, kind: nil)
        }
        if let hit = knownPrefix(text, needsDelimiter: true) {
            return Route(destination: .project(hit.project), rest: hit.rest, kind: nil)
        }
        return nil
    }

    func knownPrefix(_ text: String, needsDelimiter: Bool) -> (project: Project, rest: String)? {
        guard let hit = catalog.prefixMatch(in: text) else { return nil }
        let rest = Self.leadingProjectWord.replace(in: String(text[hit.end...]), with: "")
        if needsDelimiter && !Self.delimiterAhead.matches(rest) { return nil }
        return (hit.project, rest)
    }

    /// `projectWord` is the "project"/"app"/"repo" the speaker used after the name; it is tried
    /// as part of the name first, so "the trading app" finds a folder called trading-app.
    func resolve(_ phrase: String, projectWord: String? = nil, allowNew: Bool) -> Destination? {
        if let word = projectWord?.trimmingCharacters(in: .whitespaces), !word.isEmpty {
            let stripped = Self.leadingArticles.replace(in: TextTools.trimSeparators(phrase), with: "")
            // "In the project, …": only an article was caught, so there's no name to try with the word.
            if !stripped.isEmpty, let p = catalog.exact(key: TextTools.matchKey(stripped + " " + word)) { return .project(p) }
        }
        let cleaned = Self.cleanProjectPhrase(phrase)
        guard !cleaned.isEmpty else { return nil }
        if Self.inboxWords.contains(TextTools.squash(cleaned)) { return .inbox }
        if let p = catalog.match(cleaned) { return .project(p) }
        guard allowNew, Self.looksLikeName(cleaned) else { return nil }
        return .newProject(TextTools.slugify(cleaned))
    }

    static let inboxWords: Set<String> = ["self", "myself", "me", "inbox", "general", "notes", "later"]
    static let stopWords: Set<String> = [
        "to", "this", "that", "it", "is", "are", "was", "we", "i", "you", "of", "and", "with",
        "make", "order", "which", "what", "next", "some", "any", "every", "each", "all", "current",
    ]

    /// Guards against treating a whole clause ("in order to make this project work") as a name.
    static func looksLikeName(_ s: String) -> Bool {
        let words = s.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        return (1...3).contains(words.count) && !words.contains(where: stopWords.contains)
    }

    static func cleanProjectPhrase(_ phrase: String) -> String {
        var s = TextTools.trimSeparators(phrase)
        s = leadingArticles.replace(in: s, with: "")
        s = trailingProjectWord.replace(in: s, with: "")
        return TextTools.trimSeparators(s)
    }

    static func kind(from word: String?) -> NoteKind? {
        guard let w = word?.lowercased(), !w.isEmpty else { return nil }
        if w.contains("bug") { return .bug }
        if w.contains("do") || w.contains("toto") || w.contains("task") || w.contains("reminder") { return .todo }
        if w.contains("idea") || w.contains("feature") { return .idea }
        return .note
    }

    /// Removes "add a note:", "remind me to", "todo:" and similar lead-ins. Returns nil if none matched.
    static func stripCommand(_ s: String) -> (String, NoteKind?)? {
        if let r = todoLeadIn.firstMatchEnd(in: s) { return (String(s[r...]), .todo) }
        if let r = jotDown.firstMatchEnd(in: s) { return (String(s[r...]), nil) }
        if let g = commandWithKind.groups(in: s), let r = commandWithKind.firstMatchEnd(in: s) {
            return (String(s[r...]), kind(from: g["kind"]))
        }
        if let g = kindWithPunctuation.groups(in: s), let r = kindWithPunctuation.firstMatchEnd(in: s) {
            return (String(s[r...]), kind(from: g["kind"]))
        }
        if let r = rememberThat.firstMatchEnd(in: s) { return (String(s[r...]), nil) }
        return nil
    }

    // MARK: Patterns

    static let prep = #"(?:in|inside|into|for|on|to|under|within)"#
    static let art = #"(?:the|my|our)"#
    static let verb = #"(?:add|save|put|write|create|make|take|jot(?:\s+down)?|note(?:\s+down)?|log|capture|record|store|drop)"#
    static let kindWord = #"(?:feature\s+ideas?|feature\s+requests?|to-?dos?|to\s+dos?|totos?|notes?|ideas?|tasks?|features?|bugs?|reminders?|thoughts?)"#
    static let det = #"(?:(?:a|an|the|this|new|quick|another|one\s+more)\s+)*"#
    static let projWord = #"(?:project|repo|repository|app|codebase)"#
    static let name = #"(?<proj>[^,:;.!?]{1,48}?)"#
    static let sep = #"(?:\s*[,:;.!?]+\s*|\s+[-–—]+\s*)"#

    static let prepThenProjectWord = Pattern(
        #"^\#(prep)\s+(?:\#(art)\s+)?\#(name)\s+(?<pw>\#(projWord))\b\#(sep)?(?<rest>.*)$"#)
    static let projectWordThenName = Pattern(
        #"^(?:\#(prep)\s+)?(?:\#(art)\s+)?(?:project|repo)\s+(?:called\s+|named\s+)?\#(name)(?:\#(sep)|\s+(?=(?:please\s+)?(?:\#(verb)|\#(kindWord)|remind|remember)\b))(?<rest>.*)$"#)
    static let commandThenProject = Pattern(
        #"^(?:please\s+)?\#(verb)\s+\#(det)(?:(?<kind>\#(kindWord))\s+)?(?:to|for|in|into|under|on)\s+(?:\#(art)\s+)?\#(name)(?<pw>\s+\#(projWord))?(?:\#(sep)|\s+(?:that|saying|which\s+is)\s+)(?<rest>.*)$"#)
    static let kindThenProject = Pattern(
        #"^(?<kind>\#(kindWord))\s+(?:for|to|in|on)\s+(?:\#(art)\s+)?\#(name)(?<pw>\s+\#(projWord))?(?:\#(sep)|\s+(?:that|saying)\s+)(?<rest>.*)$"#)
    static let commandThenPrep = Pattern(
        #"^(?:please\s+)?\#(verb)\s+\#(det)(?:(?<kind>\#(kindWord))\s+)?(?:to|for|in|into|under|on)\s+(?:\#(art)\s+)?(?<after>.+)$"#)
    static let prepThenAnything = Pattern(#"^\#(prep)\s+(?:\#(art)\s+)?(?<after>.+)$"#)

    static let leadingProjectWord = Pattern(#"^\s*\#(projWord)\b"#)
    static let delimiterAhead = Pattern(#"^\s*(?:[,:;]|[-–—]|(?:please\s+)?(?:\#(verb)|\#(kindWord)|remind|remember)\b)"#)
    /// Also strips a bare article, so "the" caught as a name ("In the project, …") cleans to nothing.
    static let leadingArticles = Pattern(#"^(?:(?:the|my|our|a|an)(?:\s+|$))+"#)
    static let trailingProjectWord = Pattern(#"\s+\#(projWord)$"#)

    static let leadingFiller = Pattern(#"^(?:(?:hey|hi|ok|okay|so|um+|uh+|er+|hmm+|yo|alright)(?=[\s,.!?]|$)[\s,.!?]*)+"#)
    static let cancel = Pattern(
        #"(?:^|[,.!?;]\s*|\b(?:no|actually|oh|wait)[,\s]+)(?:cancel(?:\s+(?:that|it|this))?|never\s?mind(?:\s+that)?|scratch\s+that|forget\s+(?:it|that|this)|delete\s+that|discard(?:\s+(?:it|that|this))?)[\s.!?,]*$"#)

    static let todoLeadIn = Pattern(
        #"^(?:please\s+)?(?:remind\s+me\s+to|remember\s+to|don[’']?t\s+forget\s+to|(?:i|we)\s+(?:need|have)\s+to|need\s+to)\s+"#)
    static let jotDown = Pattern(#"^(?:please\s+)?(?:jot|note|write|put)\s+down\s+(?:that\s+)?"#)
    /// Dictation often hears "add a todo" as "at a todo" or "and a todo"; only accepted before a kind word.
    static let commandWithKind = Pattern(
        #"^(?:please\s+)?(?:\#(verb)|at|and|ad|had)\s+\#(det)(?<kind>\#(kindWord))(?:\s+(?:that|saying|to\s+say))?(?:\s+to(?=\s))?\s*[,:;.\-–—]*\s*"#)
    static let kindWithPunctuation = Pattern(#"^(?<kind>\#(kindWord))\s*[,:;\-–—]+\s*"#)
    static let rememberThat = Pattern(#"^(?:remember|note)\s+that\s+"#)
    static let kindLeadIn = Pattern(#"^(?<kind>\#(kindWord))\s+(?:for|about|on|regarding)\b"#)
}

/// NSRegularExpression with the named groups it declares, so lookups never ask for a missing name.
struct Pattern {
    let regex: NSRegularExpression
    let names: [String]

    init(_ pattern: String) {
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let finder = try! NSRegularExpression(pattern: #"\(\?<([A-Za-z][A-Za-z0-9]*)>"#)
        names = finder.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).compactMap {
            Range($0.range(at: 1), in: pattern).map { String(pattern[$0]) }
        }
    }

    private func firstMatch(in s: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    func matches(_ s: String) -> Bool {
        firstMatch(in: s) != nil
    }

    func groups(in s: String) -> [String: String]? {
        guard let m = firstMatch(in: s) else { return nil }
        var out: [String: String] = [:]
        for name in names {
            let r = m.range(withName: name)
            if r.location != NSNotFound, let range = Range(r, in: s) { out[name] = String(s[range]) }
        }
        return out
    }

    func firstMatchEnd(in s: String) -> String.Index? {
        guard let m = firstMatch(in: s), let r = Range(m.range, in: s) else { return nil }
        return r.upperBound
    }

    func replace(in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}
