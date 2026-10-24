import Foundation

public struct Project: Equatable, Hashable {
    /// File stem and display name, e.g. "trading-bot". Matches the folder name when there is one.
    public let name: String
    /// The project's folder on disk, if it came from a project root.
    public let folder: URL?
    /// Another name that routes here ("SAI" for the rook project). Matching uses it instead of the name.
    public let alias: String?

    public init(name: String, folder: URL? = nil, spoken alias: String? = nil) {
        self.name = name
        self.folder = folder
        self.alias = alias
    }

    /// How someone would say the name: "trading-bot" / "TradingBot" / "trading_bot" -> "trading bot".
    public var spokenName: String {
        let name = alias ?? self.name
        var out = ""
        var previous: Character?
        for ch in name {
            if ch == "-" || ch == "_" || ch == "." {
                out.append(" ")
            } else {
                if let p = previous, p.isLowercase, ch.isUppercase { out.append(" ") }
                out.append(ch)
            }
            previous = ch
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    public var key: String { TextTools.matchKey(spokenName) }
}

/// The set of projects a note can be routed to: folders under the configured
/// project roots, plus any project notes files Broski created earlier.
public struct ProjectCatalog {
    public var projects: [Project]

    public init(projects: [Project]) {
        self.projects = projects
    }

    static let skippedFolders: Set<String> = ["node_modules", "build", "dist", "tmp"]

    public static func discover(roots: [URL], notesDir: URL, fileManager fm: FileManager = .default) -> ProjectCatalog {
        var found: [Project] = []
        var seen = Set<String>()
        func add(_ p: Project) {
            guard !p.key.isEmpty, seen.insert(p.key).inserted else { return }
            found.append(p)
        }

        for root in roots {
            let items = (try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir, !skippedFolders.contains(url.lastPathComponent) else { continue }
                add(Project(name: url.lastPathComponent, folder: url))
            }
        }

        let notes = (try? fm.contentsOfDirectory(at: notesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in notes where url.pathExtension == "md" {
            add(Project(name: url.deletingPathExtension().lastPathComponent))
        }
        return ProjectCatalog(projects: found)
    }

    public func exact(key: String) -> Project? {
        guard !key.isEmpty else { return nil }
        return projects.first { $0.key == key }
    }

    /// Closest project by edit distance, allowing about one mistake per four letters
    /// (enough for "trading bought" -> trading-bot, not enough for unrelated names).
    public func fuzzy(key: String) -> Project? {
        guard key.count >= 4 else { return nil }
        var best: (project: Project, distance: Int)?
        for p in projects {
            let pk = p.key
            guard pk.count >= 4, abs(pk.count - key.count) <= 3 else { continue }
            let d = TextTools.levenshtein(key, pk)
            if d <= max(1, max(pk.count, key.count) / 4), d < (best?.distance ?? .max) {
                best = (p, d)
            }
        }
        return best?.project
    }

    /// Resolve a spoken project phrase like "the trading bot" to a known project.
    public func match(_ phrase: String) -> Project? {
        let key = TextTools.matchKey(phrase)
        return exact(key: key) ?? fuzzy(key: key)
    }

    /// If `text` starts with a known project name, returns it and the index right after the name.
    public func prefixMatch(in text: String, maxWords: Int = 5) -> (project: Project, end: String.Index)? {
        let tokens = TextTools.tokens(in: text)
        guard let first = tokens.first, text[text.startIndex..<first.range.lowerBound].allSatisfy(\.isWhitespace) else {
            return nil
        }
        let limit = min(maxWords, tokens.count)
        guard limit > 0 else { return nil }
        for exactOnly in [true, false] {
            for n in stride(from: limit, through: 1, by: -1) {
                let key = TextTools.matchKey(tokens[0..<n].map(\.text).joined(separator: " "))
                let hit = exactOnly ? exact(key: key) : (key.count >= 5 ? fuzzy(key: key) : nil)
                // "On one hand…", "The bug: …": a one-word hit that's just an ordinary word isn't the project.
                if hit != nil, exactOnly, n == 1,
                   Self.plainWord(tokens[0].text, next: tokens.count > 1 ? tokens[1].text : nil, atStart: false) { continue }
                if let hit { return (hit, tokens[n - 1].range.upperBound) }
            }
        }
        return nil
    }

    /// Words too common to be a project name on their own ("the", "a"); a project called that is only found as "the project".
    static let commonWords: Set<String> = ["the", "a", "an", "and", "or", "for", "to", "in", "on", "of", "it", "is", "my", "me", "we",
                                           "this", "that", "what", "which", "who", "all", "any", "new", "now", "today", "next", "last"]
    /// Ordinary words that are also project names ("one" for a project called One): matched only when written as a name ("One").
    static let wordNames: Set<String> = ["one", "lab", "bots", "evm", "supra", "impro", "rook", "raven", "tamer"]

    /// Whether a single word that matched a project is only an ordinary word here: a common word, a bare number
    /// ("Inbox (1)" isn't the "one" project), or a word name not written as a name. "… project" always counts.
    /// `atStart`: a capital on the first word is just the sentence's, so it doesn't make a name.
    static func plainWord(_ w: String, next: String?, atStart: Bool) -> Bool {
        if let next, ["project", "tracker", "repo"].contains(next.lowercased()) { return false }
        let lower = w.lowercased()
        if commonWords.contains(lower) || w.allSatisfy(\.isNumber) { return true }
        return wordNames.contains(lower) && !(w.first?.isUppercase == true && !atStart)
    }

    /// A project named anywhere in `text` ("what's left on strado?", "bugs in the trading bot", "waiting on me for One").
    public func mentioned(in text: String) -> Project? {
        var tokens = TextTools.tokens(in: text)
        // "Yo Broski, …" / "Broski, what's …": that's talking to Broski, not naming the broski project.
        if let i = tokens.prefix(2).firstIndex(where: { ["broski", "bro", "broskii"].contains($0.text.lowercased()) }) {
            let rest = tokens.dropFirst(i + 1).map(\.text).joined(separator: " ").lowercased()
            if !rest.hasPrefix("project") { tokens.remove(at: i) }
        }
        let words = tokens.map(\.text)
        for n in stride(from: min(3, words.count), through: 1, by: -1) where n > 0 {
            for start in 0...(words.count - n) {
                let phrase = words[start..<start + n]
                let key = TextTools.matchKey(phrase.joined(separator: " "))
                guard let hit = exact(key: key) else { continue }
                if n == 1, Self.plainWord(phrase.first!, next: start + 1 < words.count ? words[start + 1] : nil, atStart: start == 0) {
                    continue
                }
                return hit
            }
        }
        return nil
    }
}
