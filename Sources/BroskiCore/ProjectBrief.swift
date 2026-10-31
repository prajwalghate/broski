import Foundation

// MARK: The brief

/// What a project is and where it stands, in the person's words (or Claude Code's, after they read it): kept as
/// `projects/<name>/brief.md`, written only when they tap Save, and read into a conversation about the project.
public struct ProjectBrief: Equatable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case whatItIs = "What it is"
        case stage = "Stage"
        case goalNow = "Goal now"
        case whereThingsLive = "Where things live"
        case decisions = "Decisions so far"
        case openWork = "Open work"
        case stuckOn = "Stuck on"
    }

    /// A section someone added by hand, kept as it is.
    public struct Extra: Equatable, Sendable {
        public var title: String
        public var lines: [String]
    }

    public static let fileName = "brief.md"
    public static let format = 1
    /// What an empty section says, in the file and to the model, so nothing is silently missing.
    public static let nothingYet = "Nothing yet."

    public var project: String
    public var updated: Date?
    /// interview | claude-code | edited
    public var source: String?
    public var lines: [Section: [String]]
    public var extras: [Extra]

    public init(project: String, updated: Date? = nil, source: String? = nil, lines: [Section: [String]] = [:], extras: [Extra] = []) {
        self.project = project
        self.updated = updated
        self.source = source
        self.lines = lines
        self.extras = extras
    }

    public subscript(_ section: Section) -> [String] {
        get { lines[section] ?? [] }
        set { lines[section] = newValue.isEmpty ? nil : newValue }
    }

    /// How many sections say something.
    public var filled: Int { Section.allCases.filter { !self[$0].isEmpty }.count }

    /// The whole file: a format, every section in order (an empty one says so), then any you added.
    public func render() -> String {
        var head = ["---", "format: \(Self.format)", "project: \(project)"]
        if let updated { head.append("updated: \(Self.stamp.string(from: updated))") }
        if let source { head.append("source: \(source)") }
        head.append("---")
        return head.joined(separator: "\n") + "\n# \(project) brief\n\n" + body + "\n"
    }

    /// The sections alone, for a prompt: every one of them, so the model can see what isn't known yet.
    public var body: String {
        let known = Section.allCases.map { Self.block($0.rawValue, self[$0]) }
        return (known + extras.map { Self.block($0.title, $0.lines) }).joined(separator: "\n\n")
    }

    /// A line that would read back as a heading ("## Not a heading", "**Blocked**") is written with a backslash.
    private static func block(_ title: String, _ lines: [String]) -> String {
        let safe = lines.map { heading($0) != nil || $0.hasPrefix("\\") ? "\\" + $0 : $0 }
        return "## \(title)\n" + (lines.isEmpty ? nothingYet : safe.joined(separator: "\n"))
    }

    static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Reads a brief: Broski's own, one written by hand (no front matter), or a newer format's (what it adds is
    /// ignored). Nil when no section Broski knows is there.
    public static func parse(_ text: String, project: String) -> ProjectBrief? {
        let (fields, body) = YAMLFrontMatter.split(text)
        var brief = ProjectBrief(project: fields["project"]?.string ?? project,
                                 updated: fields["updated"]?.string.flatMap { stamp.date(from: $0) },
                                 source: fields["source"]?.string)
        var found = false
        for (title, lines) in sections(body) {
            if let section = section(named: title) {
                found = true
                brief[section] = lines
            } else if !lines.isEmpty {
                // A title line ("# recipe-box brief") has nothing under it; a section you added does.
                brief.extras.append(Extra(title: title, lines: lines))
            }
        }
        return found ? brief : nil
    }

    /// The `#`–`###` headed sections of some markdown, in order, with their non-blank lines. A section that only
    /// says "Nothing yet." is empty.
    static func sections(_ markdown: String) -> [(title: String, lines: [String])] {
        var out: [(title: String, lines: [String])] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let title = heading(line) {
                out.append((title, []))
            } else if !line.isEmpty, !out.isEmpty {
                out[out.count - 1].lines.append(line.hasPrefix("\\") ? String(line.dropFirst()) : line)
            }
        }
        return out.map { section in
            let empty = section.lines.count == 1 && section.lines[0].trimmingCharacters(in: CharacterSet(charactersIn: "_*")) == nothingYet
            return (section.title, empty ? [] : section.lines)
        }
    }

    /// "## Stage", "### Stage:", "**Stage**" → "Stage".
    static func heading(_ line: String) -> String? {
        var title: Substring
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }
            guard hashes.count <= 3, line.dropFirst(hashes.count).first == " " else { return nil }
            title = line.dropFirst(hashes.count)
        } else if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            title = line.dropFirst(2).dropLast(2)
        } else {
            return nil
        }
        title = title.drop { $0 == " " }
        while let last = title.last, last == ":" || last == " " || last == "*" { title = title.dropLast() }
        return title.isEmpty ? nil : String(title)
    }

    static func section(named title: String) -> Section? {
        Section.allCases.first { $0.rawValue.caseInsensitiveCompare(title) == .orderedSame }
    }

    public static func file(root: URL, project: String) -> URL {
        ItemStore(root: root).folder(for: project).appendingPathComponent(fileName)
    }

    public static func load(root: URL, project: String) -> ProjectBrief? {
        guard let text = try? String(contentsOf: file(root: root, project: project), encoding: .utf8) else { return nil }
        return parse(text, project: project).map { var brief = $0; brief.project = project; return brief }
    }

    /// Writes the whole file. Only from the person's tap: a brief has one writer, them.
    public func save(root: URL) throws {
        let url = Self.file(root: root, project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try render().write(to: url, atomically: true, encoding: .utf8)
    }

    /// This brief's lines with the date and source of a newer one.
    public func updating(from newer: ProjectBrief) -> ProjectBrief {
        var out = self
        out.updated = newer.updated
        out.source = newer.source
        return out
    }

    // MARK: From Claude Code

    static let hints: [Section: String] = [
        .whatItIs: "one or two sentences: what it does and who it's for",
        .stage: "idea, building, beta, launched, paused, and what that means here",
        .goalNow: "the one thing it's working towards now",
        .whereThingsLive: "the repo, the tracker, docs, where it runs",
        .decisions: "the decisions that still stand, newest last",
        .openWork: "what's in progress or next, a line each",
        .stuckOn: "what's blocked or undecided",
    ]

    /// What the person pastes into the project's Claude Code thread: Claude Code has the project's tracker tools
    /// and the repository; Broski runs neither, so it asks.
    public static func claudeCodePrompt(project: String) -> String {
        let guide = Section.allCases.map { "- \($0.rawValue): \(hints[$0] ?? "")" }.joined(separator: "\n")
        let template = Section.allCases.map { "## \($0.rawValue)\n" }.joined(separator: "\n")
        return """
        Summarise this project for Broski, the companion app I talk to about my work. Use your tracker tools (MCP) and \
        this repository to find out where it stands. Only read: don't change anything, run anything or create items.

        Cite tracker items by their IDs in brackets after the line they back, like (T-12). Keep each section to a few \
        short lines. If you can't tell what goes in a section, write "\(nothingYet)" there rather than leaving it out or \
        guessing.

        \(guide)

        Reply with exactly this, filled in, as plain markdown, and nothing before or after it:

        Broski brief: \(project)

        \(template)
        """
    }

    /// Claude Code's answer, pasted back: a brief for the project its "Broski brief:" line names (one of yours),
    /// else the one you're talking about. Nil unless at least three of the sections are there.
    public static func pasted(_ text: String, projects: [String], current: String?) -> ProjectBrief? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        let markdown = lines.joined(separator: "\n")
        // A sub-heading inside a section ("### Backend" under Open work) keeps its lines there, under "Backend:".
        var found: [(title: String, lines: [String])] = []
        for (title, lines) in sections(markdown) {
            if section(named: title) != nil {
                found.append((title, lines))
            } else if !found.isEmpty {
                found[found.count - 1].lines += [title + ":"] + lines
            }
        }
        guard Set(found.map { $0.title.lowercased() }).count >= 3 else { return nil }
        var named: String?
        for line in lines {
            let plain = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_ \t"))
            guard plain.lowercased().hasPrefix("broski brief") else { continue }
            let name = plain.dropFirst("broski brief".count).trimmingCharacters(in: CharacterSet(charactersIn: ": *_\t"))
            named = projects.first { $0.caseInsensitiveCompare(name) == .orderedSame }
            break
        }
        guard let project = named ?? current else { return nil }
        var brief = ProjectBrief(project: project, source: "claude-code")
        for (title, body) in found {
            if let section = section(named: title) { brief[section] = body }
        }
        return brief
    }

    // MARK: Falling behind

    /// "Updated 18 days ago, and the tracker has 9 changes since. Refresh it?" when the brief is two weeks old and
    /// its project's tracker has moved on by five changes or more; nil otherwise.
    public func staleness(changes: [ChangeEvent], now: Date = Date()) -> String? {
        guard let updated else { return nil }
        let days = Int(now.timeIntervalSince(updated) / 86_400)
        let since = changes.filter { $0.project == project && $0.at > updated }.count
        guard days >= 14, since >= 5 else { return nil }
        return "Updated \(days) days ago, and the tracker has \(since) changes since. Refresh it?"
    }
}

// MARK: Setting one up in the conversation

/// "Let's set up recipe-box": six short questions, asked by Broski itself one at a time (no model, so it works
/// offline and with any project), ending in a brief the person saves or not. Decisions come from the ones they've
/// already saved. Updating an existing brief, "skip" keeps what it says.
public struct BriefInterview: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case ask(String)
        case done(ProjectBrief)
        case stopped
    }

    public static let questions: [(section: ProjectBrief.Section, text: String)] = [
        (.whatItIs, "What is it, in a sentence or two, and who is it for?"),
        (.stage, "What stage is it at: an idea, building, in beta, launched, paused?"),
        (.goalNow, "What's the one thing you're working towards right now?"),
        (.whereThingsLive, "Where do things live: the repo, the tracker, docs, where it runs?"),
        (.openWork, "What's in progress or next? One per line is fine."),
        (.stuckOn, "Anything you're stuck on, or haven't decided?"),
    ]

    static let skips: Set<String> = ["skip", "pass", "next", "don't know", "dont know", "no idea", "not sure", "none", "nothing", "n/a"]
    static let stops: Set<String> = ["stop", "cancel", "quit", "never mind", "nevermind", "stop the interview", "forget it"]

    public let project: String
    let existing: ProjectBrief?
    let decisions: [String]
    var answers: [ProjectBrief.Section: [String]] = [:]
    var index = 0

    public init(project: String, decisions: [String] = [], existing: ProjectBrief? = nil) {
        self.project = project
        self.decisions = decisions
        self.existing = existing
    }

    /// Commands that still work mid-interview, and never become answers: the vault, private mode, a quick note.
    public static func passesThrough(_ command: ConversationCommand) -> Bool {
        switch command {
        case .toVault, .openVault, .goPrivate, .leavePrivate, .note: return true
        default: return false
        }
    }

    /// The question waiting for an answer.
    public var question: String { Self.questions[min(index, Self.questions.count - 1)].text }

    /// "Question 2 of 6".
    public var progress: String { "Question \(min(index, Self.questions.count - 1) + 1) of \(Self.questions.count)" }

    /// What Broski says first, ending with the first question.
    public var opening: String {
        let what = existing == nil ? "Let's set up the brief for \(project)" : "Let's update the brief for \(project)"
        let skip = existing == nil ? "“skip” leaves one empty" : "“skip” keeps what it says now"
        return "\(what): six quick questions, and nothing is saved until you say so. \(skip), and “stop” ends it. \(question)"
    }

    public mutating func answer(_ text: String, at: Date = Date()) -> Step {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = said.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        if Self.stops.contains(plain) { return .stopped }
        let section = Self.questions[index].section
        if Self.skips.contains(plain) || said.isEmpty {
            answers[section] = existing?[section] ?? []
        } else {
            answers[section] = said.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        index += 1
        guard index >= Self.questions.count else { return .ask(question) }
        var brief = existing ?? ProjectBrief(project: project)
        brief.project = project
        brief.updated = at
        brief.source = "interview"
        for (section, lines) in answers { brief[section] = lines }
        if !decisions.isEmpty { brief[.decisions] = decisions }
        return .done(brief)
    }

    public static func == (a: BriefInterview, b: BriefInterview) -> Bool {
        a.project == b.project && a.index == b.index && a.answers == b.answers && a.existing == b.existing && a.decisions == b.decisions
    }
}

// MARK: Updating one

/// One line added to or taken out of a section, to accept or not.
public struct BriefChange: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case added, removed }
    public var id: Int
    public var section: ProjectBrief.Section
    public var text: String
    public var kind: Kind
}

/// A new version of a brief shown as what changed, line by line; only the changes the person accepts are kept.
public enum BriefUpdate {
    enum Op: Equatable { case keep(String), remove(String), add(String) }

    public static func changes(from old: ProjectBrief, to new: ProjectBrief) -> [BriefChange] {
        var out: [BriefChange] = []
        for section in ProjectBrief.Section.allCases {
            for op in ops(old[section], new[section]) {
                switch op {
                case .keep: break
                case .remove(let text): out.append(BriefChange(id: out.count, section: section, text: text, kind: .removed))
                case .add(let text): out.append(BriefChange(id: out.count, section: section, text: text, kind: .added))
                }
            }
        }
        return out
    }

    /// The old brief with the accepted changes made: an accepted removal goes, an accepted addition comes in where
    /// the new version has it. What you added by hand stays.
    public static func apply(_ accepted: Set<Int>, from old: ProjectBrief, to new: ProjectBrief) -> ProjectBrief {
        var out = old.updating(from: new)
        var id = 0
        for section in ProjectBrief.Section.allCases {
            var lines: [String] = []
            for op in ops(old[section], new[section]) {
                switch op {
                case .keep(let text): lines.append(text)
                case .remove(let text):
                    if !accepted.contains(id) { lines.append(text) }
                    id += 1
                case .add(let text):
                    if accepted.contains(id) { lines.append(text) }
                    id += 1
                }
            }
            out[section] = lines
        }
        return out
    }

    /// The shortest edit from one list of lines to another (longest common subsequence), removals before additions.
    static func ops(_ old: [String], _ new: [String]) -> [Op] {
        let n = old.count, m = new.count
        var common = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                common[i][j] = old[i] == new[j] ? common[i + 1][j + 1] + 1 : max(common[i + 1][j], common[i][j + 1])
            }
        }
        var out: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, old[i] == new[j] {
                out.append(.keep(old[i])); i += 1; j += 1
            } else if i < n, j == m || common[i + 1][j] >= common[i][j + 1] {
                out.append(.remove(old[i])); i += 1
            } else {
                out.append(.add(new[j])); j += 1
            }
        }
        return out
    }
}

// MARK: The card

/// A brief waiting for the person's tap: a new one saves whole; an update to an existing one shows its changes,
/// all accepted to start with, and keeps only the ones still ticked.
public struct BriefOffer: Equatable, Sendable {
    public var brief: ProjectBrief
    public var old: ProjectBrief?
    public private(set) var changes: [BriefChange]
    public var accepted: Set<Int>

    public init(brief: ProjectBrief, old: ProjectBrief?) {
        self.brief = brief
        self.old = old
        changes = old.map { BriefUpdate.changes(from: $0, to: brief) } ?? []
        accepted = Set(changes.map(\.id))
    }

    public var project: String { brief.project }
    /// An update that changes nothing.
    public var unchanged: Bool { old != nil && changes.isEmpty }

    public mutating func toggle(_ id: Int) {
        if accepted.contains(id) { accepted.remove(id) } else { accepted.insert(id) }
    }

    /// What Save writes.
    public var result: ProjectBrief {
        old.map { BriefUpdate.apply(accepted, from: $0, to: brief) } ?? brief
    }
}
