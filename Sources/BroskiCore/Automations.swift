import Foundation

/// A rule over the change stream: when a project's tracker or conversation changes in a way you care about, Broski
/// tells you, posts to a webhook you saved, or both. Rules live in `automations.json` in the Broski folder; webhook
/// addresses never do (they stay in the Mac's secrets file, named here only).
public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    /// Empty: every project.
    public var projects: [String]
    /// Change kinds (decided, new, closed, reopened, status, attested, removed, added); empty: any.
    public var kinds: [String]
    /// Any of these in the title (any case); empty: any title.
    public var words: [String]
    public var notify: Bool
    /// A saved webhook's name ("slack"); nil: none.
    public var webhook: String?

    public init(id: String = UUID().uuidString, name: String, enabled: Bool = true, projects: [String] = [], kinds: [String] = [],
                words: [String] = [], notify: Bool, webhook: String? = nil) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.projects = projects
        self.kinds = kinds
        self.words = words
        self.notify = notify
        self.webhook = webhook
    }
}

public enum Automations {
    public struct Action: Equatable, Sendable {
        public var rule: String
        public var event: ChangeEvent
        public var notify: Bool
        public var webhook: String?
    }

    struct File: Codable {
        var v = 1
        var rules: [AutomationRule]
    }

    struct Cursor: Codable {
        var v = 1
        var through: Date
    }

    public static let kinds = ["decided", "new", "closed", "reopened", "status", "attested", "removed", "added"]

    static func file(_ root: URL) -> URL { root.appendingPathComponent("automations.json") }
    /// This Mac's own: how far it has looked (the one writer of it).
    static func cursorFile(_ root: URL) -> URL { root.appendingPathComponent(".broski/automations.mac.json") }

    public static func load(root: URL) -> [AutomationRule] {
        guard let data = try? Data(contentsOf: file(root)), let parsed = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return parsed.rules
    }

    public static func save(_ rules: [AutomationRule], root: URL) throws {
        // Its own encoder: the shared JSON Lines one must stay one line per value.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(rules: rules)).write(to: file(root), options: .atomic)
    }

    public static func matches(_ rule: AutomationRule, _ event: ChangeEvent) -> Bool {
        guard rule.enabled else { return false }
        if !rule.projects.isEmpty, !rule.projects.contains(event.project) { return false }
        if !rule.kinds.isEmpty, !rule.kinds.contains(event.kind) { return false }
        let title = event.title.lowercased()
        return rule.words.isEmpty || rule.words.contains { title.contains($0.lowercased()) }
    }

    /// What to do for these events. A local-only project's changes can still notify you, but never leave this Mac.
    public static func actions(for events: [ChangeEvent], rules: [AutomationRule], localOnly: Set<String>) -> [Action] {
        events.flatMap { event in
            rules.filter { matches($0, event) }.compactMap { rule -> Action? in
                let webhook = localOnly.contains(event.project) ? nil : rule.webhook
                guard rule.notify || webhook != nil else { return nil }
                return Action(rule: rule.id, event: event, notify: rule.notify, webhook: webhook)
            }
        }
    }

    /// Events since the last look, and moves the cursor past them. The first look only sets the cursor, so turning
    /// automations on never replays history.
    public static func pending(root: URL, now: Date = Date()) -> [ChangeEvent] {
        guard let data = try? Data(contentsOf: cursorFile(root)), let cursor = try? JSONLines.decoder.decode(Cursor.self, from: data) else {
            setCursor(now, root: root)
            return []
        }
        let events = ChangeStream.read(root: root, project: nil, since: cursor.through).filter { $0.at > cursor.through }
        if let last = events.map(\.at).max() { setCursor(last, root: root) }
        return events
    }

    static func setCursor(_ date: Date, root: URL) {
        try? FileManager.default.createDirectory(at: cursorFile(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONLines.encoder.encode(Cursor(through: date)).write(to: cursorFile(root), options: .atomic)
    }

    /// One line for a webhook: `text` for Slack, `content` for Discord.
    public static func payload(_ event: ChangeEvent) -> Data {
        let line = "\(event.project) · \(event.kind): \(event.title)"
        return (try? JSONSerialization.data(withJSONObject: ["text": line, "content": line], options: [.sortedKeys])) ?? Data()
    }
}
