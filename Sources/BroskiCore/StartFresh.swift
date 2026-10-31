import Foundation

// MARK: Start fresh

/// Settings › General › Start fresh, in three separate levels. None deletes anything: pausing keeps everything,
/// forgetting keeps the old words aside (and every forget can be seen in What Broski knows), and starting completely
/// fresh moves the whole Broski folder aside, where it can be put back.
public enum StartFresh {
    public enum Level: String, CaseIterable, Sendable {
        /// Keep everything, stop using it.
        case pauseMemory
        /// Forget what Broski knows about you.
        case forgetMe
        /// Move the whole folder aside and begin again.
        case everything
    }

    /// What a level clears and what it keeps, in the person's words.
    public struct Effect: Equatable, Sendable {
        public var clears: [String]
        public var keeps: [String]
    }

    public enum Problem: Error, Equatable, LocalizedError {
        /// The archive to put back isn't there any more.
        case missing(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let name): return "“\(name)” isn't there any more. Check the folder next to your Broski folder."
            }
        }
    }

    public static func effect(_ level: Level, forgetKeys: Bool = false) -> Effect {
        switch level {
        case .pauseMemory:
            return Effect(clears: ["Using what Broski knows about you, and what you said before, in replies",
                                   "Learning about you from your conversations"],
                          keeps: ["What Broski knows about you, ready for when you turn it back on",
                                  "Your conversations, notes, projects and briefs"])
        case .forgetMe:
            return Effect(clears: ["What Broski knows about you: the facts it remembered and the About you page"],
                          keeps: ["The old About you page, set aside in memory/forgotten",
                                  "A record of each fact forgotten, in What Broski knows",
                                  "Your conversations, notes, projects and briefs"])
        case .everything:
            let keys = "Your model keys on this Mac"
            return Effect(clears: ["Conversations, notes, projects, briefs and what Broski knows about you, moved into an archived folder",
                                   "The folders Broski looks in for projects, and the names your trackers use for you"]
                                  + (forgetKeys ? [keys + ", which you'll paste in again"] : []),
                          keeps: ["The whole old folder, next to the new one as “Broski (archived <date>)”, ready to put back",
                                 "Which model does each job, your shortcuts and voice settings",
                                 "Which projects are local only"]
                                 + (forgetKeys ? [] : [keys]))
        }
    }

    // MARK: Forget what Broski knows about me

    /// Forgets every remembered fact (from every device, written into this device's own file) and sets the About you
    /// page aside in `memory/forgotten/`. Returns how many things it forgot.
    @discardableResult
    public static func forgetMe(root: URL, device: String, at: Date = Date()) throws -> Int {
        var count = 0
        for fact in Memory.remembered(root: root) {
            try Memory.append(Memory.Event(at: at, device: device, op: "forget", text: fact, by: "reset",
                                           why: "Forgot everything from Settings on \(Recall.dayString(at))"), root: root)
            count += 1
        }
        let page = Memory.folder(root).appendingPathComponent("about-you.md")
        let text = (try? String(contentsOf: page, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if FileManager.default.fileExists(atPath: page.path) {
            let aside = Memory.folder(root).appendingPathComponent("forgotten", isDirectory: true)
            try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: page, to: free(aside, "about-you \(day(at))", ext: "md"))
            if !text.isEmpty { count += 1 }
        }
        return count
    }

    // MARK: Start completely fresh

    /// Moves the whole Broski folder aside as "Broski (archived 2026-11-01)" next to it, and starts an empty one
    /// with only the settings that aren't about you or your projects. Returns where the old folder went.
    /// Where the folder would go if it were archived now: "Broski (archived 2026-11-01)", or " 2" when that's taken.
    public static func nextArchive(of root: URL, at: Date = Date()) -> URL {
        free(root.deletingLastPathComponent(), "\(root.lastPathComponent) (archived \(day(at))", closing: ")")
    }

    public static func everything(root: URL, config: BroskiConfig, at: Date = Date(),
                                  write: (BroskiConfig, URL) throws -> Void = { try $0.save(to: $1) }) throws -> URL {
        let archive = try archive(root, at: at)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try write(freshConfig(config), root.appendingPathComponent("config.json"))
        } catch {
            // All or nothing: the new folder holds at most the config just written, so it goes, and the old one comes back.
            let made = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            if made.allSatisfy({ $0 == "config.json" || $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: root) }
            try? FileManager.default.moveItem(at: archive, to: root)
            throw error
        }
        return archive
    }

    /// The settings a fresh folder starts with: models, shortcuts, voice and the rest of how Broski works on this
    /// Mac come along, and local-only marks stay (in case a project comes back). What's about you or your projects
    /// doesn't.
    public static func freshConfig(_ old: BroskiConfig) -> BroskiConfig {
        var config = old
        config.projectRoots = []
        config.ownerAliases = []
        config.memoryPaused = false
        config.pausedBriefs = []
        config.checkInOptions.projects = []
        return config
    }

    /// The archived folders next to this one, newest first.
    public static func archives(of root: URL) -> [URL] {
        let parent = root.deletingLastPathComponent()
        let prefix = root.lastPathComponent + " (archived "
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        // "2026-11-01 2)" → ("2026-11-01", 2); the first of a day has no number.
        func order(_ name: String) -> (String, Int) {
            let parts = name.dropFirst(prefix.count).dropLast().split(separator: " ")
            return (parts.first.map(String.init) ?? "", parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        }
        return names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(")") }
            .sorted { order($0) > order($1) }
            .map { parent.appendingPathComponent($0, isDirectory: true) }
    }

    /// Puts an archived folder back. The folder it replaces is archived first, so nothing is lost either way.
    /// Returns where that one went.
    @discardableResult
    public static func restore(_ archived: URL, root: URL, at: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: archived.path) else { throw Problem.missing(archived.lastPathComponent) }
        guard FileManager.default.fileExists(atPath: root.path) else {
            try FileManager.default.moveItem(at: archived, to: root)
            return nil
        }
        let replaced = try archive(root, at: at)
        do {
            try FileManager.default.moveItem(at: archived, to: root)
        } catch {
            // All or nothing: the folder that was in use goes back.
            try? FileManager.default.moveItem(at: replaced, to: root)
            throw error
        }
        return replaced
    }

    private static func archive(_ root: URL, at: Date) throws -> URL {
        let target = nextArchive(of: root, at: at)
        try FileManager.default.moveItem(at: root, to: target)
        return target
    }

    /// A name that isn't taken yet in `folder`: "name", then "name 2", "name 3"…
    private static func free(_ folder: URL, _ name: String, closing: String = "", ext: String? = nil) -> URL {
        func url(_ candidate: String) -> URL {
            let file = folder.appendingPathComponent(candidate + closing)
            return ext.map { file.appendingPathExtension($0) } ?? file
        }
        var candidate = url(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(name) \(number)")
            number += 1
        }
        return candidate
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: What a reply may read

/// What a conversation reply is given from the Broski folder, by the person's switches: nothing in private mode;
/// no memory while it's paused; no brief while that brief is paused. The Mac and the iPhone both ask here.
public struct ReplyMemory: Equatable {
    public var aboutYou: String?
    public var brief: ProjectBrief?
    public var decisions: [Decision]
    /// Whether recall may bring back what you said in earlier conversations.
    public var recallsConversations: Bool

    public static func gather(root: URL, project: String?, isPrivate: Bool, config: BroskiConfig) -> ReplyMemory {
        guard !isPrivate else { return ReplyMemory(aboutYou: nil, brief: nil, decisions: [], recallsConversations: false) }
        let paused = config.memoryPaused
        return ReplyMemory(aboutYou: paused ? nil : Memory.aboutYou(root: root),
                           brief: project.flatMap { config.pausedBriefs.contains($0) ? nil : ProjectBrief.load(root: root, project: $0) },
                           decisions: project.map { DecisionLog.current(root: root, project: $0) } ?? [],
                           recallsConversations: !paused)
    }

    /// Whether a recall hit may go with the reply: earlier conversations only while memory is on.
    public func allows(_ hit: RecallHit) -> Bool {
        recallsConversations || !hit.id.hasPrefix("turn:")
    }
}
