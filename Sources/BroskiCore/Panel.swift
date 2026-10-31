import Foundation

// MARK: What a reply used

/// What a Broski reply was given to work from, kept with it and shown folded under it, so you can see why it knew
/// what it knew: "Used what it knows about you, the strado page and 2 decisions". Every field is optional, so a turn
/// stores only what applied.
public struct ReplyContext: Codable, Equatable, Sendable {
    /// It read what Broski knows about you.
    public var aboutYou: Bool?
    /// The project whose living page it read.
    public var page: String?
    /// How many of the project's current decisions it read.
    public var decisions: Int?
    /// What recall brought back, labelled the way sources are ("Decision · Oct 20").
    public var recalled: [String]?

    /// Nil when the reply used nothing, and always in private mode, which reads no memory, projects or recall.
    public init?(aboutYou: Bool, page: String?, decisions: Int, recalled: [String], isPrivate: Bool = false) {
        guard !isPrivate, aboutYou || page != nil || decisions > 0 || !recalled.isEmpty else { return nil }
        self.aboutYou = aboutYou ? true : nil
        self.page = page
        self.decisions = decisions > 0 ? decisions : nil
        self.recalled = recalled.isEmpty ? nil : recalled
    }

    /// One line, in Broski's voice: "Used what I know about you, the strado page, 2 decisions and 3 from earlier".
    public var summary: String {
        var parts: [String] = []
        if aboutYou == true { parts.append("what I know about you") }
        if let page { parts.append("the \(page) page") }
        if let decisions { parts.append(Self.count(decisions, "decision")) }
        if let recalled, !recalled.isEmpty { parts.append("\(recalled.count) from earlier") }
        return "Used " + Self.list(parts)
    }

    /// Each thing on its own line, for when you open it.
    public var lines: [String] {
        var out: [String] = []
        if aboutYou == true { out.append("What Broski knows about you") }
        if let page { out.append("The \(page) page") }
        if let decisions { out.append("\(decisions) current decision\(decisions == 1 ? "" : "s")") }
        return out + (recalled ?? [])
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private static func list(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
}

// MARK: Project colours

/// A project's colour, the same on every device and every launch: an index into the app's palette, worked out from
/// the project's name (FNV-1a, not Swift's hash, which changes from launch to launch).
public enum ProjectColor {
    public static let count = 6

    public static func index(for project: String) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in project.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return Int(hash % UInt32(count))
    }
}

// MARK: Broski's own lines

/// The few things Broski says in its own voice outside a reply: plain, a little warm, never an exclamation mark.
public enum BroskiLines {
    /// The empty conversation's greeting, for the hour on your clock.
    public static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Morning. What are we working on?"
        case 12..<17: return "Afternoon. What's on your mind?"
        case 17..<22: return "Evening. Want to think something through?"
        default: return "Up late. What are we thinking about?"
        }
    }

    static let waiting = ["Thinking…", "Thinking it over…", "Mulling that over…", "Turning it over…"]

    /// What shows while a reply is coming. It changes from reply to reply rather than flickering within one.
    public static func thinking(replies: Int, deep: Bool) -> String {
        deep ? "Thinking harder…" : waiting[abs(replies) % waiting.count]
    }
}

// MARK: The command palette

/// One thing ⌘K can do, with the words it answers to.
public struct PaletteItem: Equatable, Sendable, Identifiable {
    public enum Action: Equatable, Sendable {
        case note, saveThat, toggleDeep, startRiff, wrapUp, togglePrivate
        /// Talk about this project (nil: no project).
        case project(String?)
        case dashboard, memory, vault
        /// A Settings page by its id: "models", "voice", "general".
        case settings(String)
    }

    public var title: String
    public var detail: String
    public var keywords: [String]
    public var action: Action
    public var id: String { title }

    public init(_ title: String, _ detail: String, keywords: [String] = [], action: Action) {
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.action = action
    }
}

/// ⌘K in the conversation: everything the panel can do, found by typing a few letters.
public enum Palette {
    public struct State: Equatable, Sendable {
        public var projects: [String]
        public var current: String?
        public var isPrivate: Bool
        public var riffing: Bool
        public var deep: Bool

        public init(projects: [String], current: String?, isPrivate: Bool, riffing: Bool, deep: Bool) {
            self.projects = projects
            self.current = current
            self.isPrivate = isPrivate
            self.riffing = riffing
            self.deep = deep
        }
    }

    /// What you can do now, in the order shown before you type.
    public static func items(_ state: State) -> [PaletteItem] {
        var items = [
            PaletteItem("New note", "Save a note without a reply", keywords: ["write", "capture"], action: .note),
            PaletteItem("Save that", "Offer a card for the last few turns", keywords: ["keep", "card", "todo", "decision"],
                        action: .saveThat),
            state.deep
                ? PaletteItem("Back to everyday", "Reply with your Everyday model again", keywords: ["model"], action: .toggleDeep)
                : PaletteItem("Think harder", "Reply with your Deep model", keywords: ["deep", "model"], action: .toggleDeep),
            state.riffing
                ? PaletteItem("Wrap up the riff", "One card: summary, ideas, decisions, todos", keywords: ["end", "finish"],
                              action: .wrapUp)
                : PaletteItem("Start a riff", "Brainstorm with your Deep model", keywords: ["brainstorm", "ideas"], action: .startRiff),
            state.isPrivate
                ? PaletteItem("Leave private mode", "Back to the conversation that remembers", keywords: ["private"],
                              action: .togglePrivate)
                : PaletteItem("Go private", "Start blank and keep nothing", keywords: ["incognito", "private"],
                              action: .togglePrivate),
        ]
        items += state.projects.filter { $0 != state.current }.map {
            PaletteItem("Switch to \($0)", "Talk about \($0)", keywords: ["project"], action: .project($0))
        }
        if state.current != nil {
            items.append(PaletteItem("No project", "Talk without a project", keywords: ["project", "clear"], action: .project(nil)))
        }
        items += [
            PaletteItem("Open the dashboard", "Every project, its page and tracker", keywords: ["projects", "board"],
                        action: .dashboard),
            PaletteItem("What Broski knows about you", "Read it, and undo any change", keywords: ["memory", "facts"],
                        action: .memory),
            PaletteItem("Open the private vault", "Encrypted notes no model reads", keywords: ["vault", "secret", "lock"],
                        action: .vault),
            PaletteItem("Settings: Models", "Which model does each job", keywords: ["provider", "key", "ai"],
                        action: .settings("models")),
            PaletteItem("Settings: Voice", "Mic, recognition and reading aloud", keywords: ["mic", "speech"],
                        action: .settings("voice")),
        ]
        return items
    }

    /// The items matching every word of `query`, best first; ties keep their usual order. A blank query keeps them all.
    public static func search(_ query: String, in items: [PaletteItem]) -> [PaletteItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        let scored = items.enumerated().compactMap { offset, item -> (Int, Int, PaletteItem)? in
            var total = 0
            for word in words {
                let score = self.score(word, item)
                if score == 0 { return nil }
                total += score
            }
            return (total, offset, item)
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    private static func score(_ word: String, _ item: PaletteItem) -> Int {
        let title = item.title.lowercased()
        let titleWords = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if titleWords.contains(where: { $0.hasPrefix(word) }) { return 4 }
        if title.contains(word) { return 3 }
        if item.keywords.contains(where: { $0.hasPrefix(word) }) { return 2 }
        return isSubsequence(word, of: title) && word.count >= 3 ? 1 : 0
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var rest = Substring(text)
        for character in word {
            guard let found = rest.firstIndex(of: character) else { return false }
            rest = rest[rest.index(after: found)...]
        }
        return true
    }
}
