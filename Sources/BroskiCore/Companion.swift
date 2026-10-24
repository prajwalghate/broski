import Foundation

/// How much Broski speaks up on its own.
public enum CompanionMode: String, Codable, CaseIterable {
    /// Never on its own; only when you ask (and the morning check-in, if you turned it on).
    case quiet
    /// A couple of well-timed nudges a day.
    case daily
    /// Up to five nudges a day, whenever something is relevant.
    case active

    public var dailyBudget: Int {
        switch self {
        case .quiet: return 0
        case .daily: return 2
        case .active: return 5
        }
    }

    public var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .daily: return "Daily"
        case .active: return "Active"
        }
    }

    public var detail: String {
        switch self {
        case .quiet: return "Only when you ask"
        case .daily: return "Up to 2 nudges a day"
        case .active: return "Up to 5 nudges a day"
        }
    }
}

/// Something Broski would like to bring up.
public struct Nudge: Equatable, Identifiable {
    public enum Kind: String, Codable {
        /// You came back to a project that has open bugs or todos.
        case backToProject = "back_to_project"
        /// An idea you haven't touched in weeks.
        case staleIdea = "stale_idea"
        /// The morning check-in.
        case checkIn = "check_in"
    }

    public var kind: Kind
    /// Same key = same nudge; used for cooldowns and "never".
    public var key: String
    public var project: String?
    public var title: String
    public var body: String
    public var cites: [String]

    public var id: String { key }

    public init(kind: Kind, key: String, project: String?, title: String, body: String, cites: [String] = []) {
        self.kind = kind
        self.key = key
        self.project = project
        self.title = title
        self.body = body
        self.cites = cites
    }
}

/// What the companion has shown and what you said about it. Kept in `.broski/companion.json`.
public struct CompanionLedger: Codable, Equatable {
    public enum Feedback: String, Codable { case useful, notNow = "not_now", never }

    public var day: String = ""
    public var shownToday: Int = 0
    public var lastShown: [String: Date] = [:]
    /// Nudge keys and kinds you said "never" to ("kind:back_to_project" mutes the whole kind).
    public var muted: Set<String> = []
    public var feedback: [String: [String: Int]] = [:]
    public var lastCheckIn: Date?

    public init() {}

    public static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public mutating func rollOver(_ now: Date) {
        let today = Self.dayKey(now)
        if day != today {
            day = today
            shownToday = 0
        }
    }

    /// Whether a nudge may show now: within today's budget, not muted, and not shown in the last day.
    public mutating func allows(_ nudge: Nudge, mode: CompanionMode, now: Date = Date(), cooldown: TimeInterval = 20 * 3600) -> Bool {
        rollOver(now)
        if nudge.kind != .checkIn, shownToday >= mode.dailyBudget { return false }
        if muted.contains(nudge.key) || muted.contains("kind:" + nudge.kind.rawValue) { return false }
        if let last = lastShown[nudge.key], now.timeIntervalSince(last) < cooldown { return false }
        return true
    }

    public mutating func shown(_ nudge: Nudge, now: Date = Date()) {
        rollOver(now)
        if nudge.kind != .checkIn { shownToday += 1 } else { lastCheckIn = now }
        lastShown[nudge.key] = now
    }

    public mutating func record(_ value: Feedback, for nudge: Nudge) {
        feedback[nudge.kind.rawValue, default: [:]][value.rawValue, default: 0] += 1
        // "Never" on the check-in turns it off in Settings instead; a day-keyed mute would never match again.
        if value == .never, nudge.kind != .checkIn { muted.insert(nudge.key) }
    }

    /// Whether a nudge of this kind could still show today, without touching the ledger.
    /// Lets the Mac skip reading the screen when nothing could come of it.
    public func hasBudget(for kind: Nudge.Kind, mode: CompanionMode, now: Date = Date()) -> Bool {
        if muted.contains("kind:" + kind.rawValue) { return false }
        let used = day == Self.dayKey(now) ? shownToday : 0
        return kind == .checkIn || used < mode.dailyBudget
    }

    public static func load(from url: URL) -> CompanionLedger {
        guard let data = try? Data(contentsOf: url) else { return CompanionLedger() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CompanionLedger.self, from: data)) ?? CompanionLedger()
    }

    public func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Decides what's worth bringing up. Pure logic: the apps call it with what they see.
public enum CompanionPlanner {
    /// The project you seem to be working on, from the app, window title or web address in front.
    /// Matches project names in the title, and web hosts you captured notes from in that project before.
    public static func project(for context: ItemContext, catalog: ProjectCatalog, items: [Item]) -> String? {
        let haystack = [context.window, context.url].compactMap { $0 }.joined(separator: " ")
        if !haystack.isEmpty, let named = catalog.mentioned(in: haystack.replacingOccurrences(of: "-", with: " ")) {
            return named.name
        }
        if let host = context.url.flatMap({ URL(string: $0)?.host }) {
            let counts = items.filter { $0.project != nil && $0.context.url.flatMap { URL(string: $0)?.host } == host }
                .reduce(into: [String: Int]()) { $0[$1.project!, default: 0] += 1 }
            if let best = counts.max(by: { $0.value < $1.value }), best.value >= 2 { return best.key }
        }
        return nil
    }

    /// "Back on strado: 3 open bugs." Only when there's something open.
    public static func backToProject(_ project: String, items: [Item]) -> Nudge? {
        let open = items.filter { $0.project == project && $0.status != .done && ($0.kind == .bug || $0.kind == .todo) }
            .sorted { ($0.priority, $0.updated) > ($1.priority, $1.updated) }
        guard let top = open.first else { return nil }
        let bugs = open.filter { $0.kind == .bug }.count, todos = open.count - bugs
        let counts = [bugs > 0 ? "\(bugs) open bug\(bugs == 1 ? "" : "s")" : nil, todos > 0 ? "\(todos) todo\(todos == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " and ")
        return Nudge(kind: .backToProject, key: "back:\(project)", project: project,
                     title: "Back on \(project): \(counts)",
                     body: "Top of the list: \(top.title)", cites: open.prefix(3).map(\.id))
    }

    /// An idea left alone for `days`, oldest first, so good thoughts don't quietly die.
    /// `muted`: the ledger's "never" keys, so one muted idea doesn't stand in front of all the others.
    public static func staleIdea(items: [Item], now: Date = Date(), days: Double = 14, excluding muted: Set<String> = []) -> Nudge? {
        if muted.contains("kind:" + Nudge.Kind.staleIdea.rawValue) { return nil }
        let stale = items.filter { $0.kind == .idea && $0.status != .done && now.timeIntervalSince($0.updated) > days * 86_400 }
            .filter { !muted.contains("idea:\($0.id)") }
            .sorted { $0.updated < $1.updated }
        guard let idea = stale.first else { return nil }
        let weeks = Int(now.timeIntervalSince(idea.updated) / (7 * 86_400))
        return Nudge(kind: .staleIdea, key: "idea:\(idea.id)", project: idea.project,
                     title: "An idea from \(weeks) week\(weeks == 1 ? "" : "s") ago",
                     body: idea.title, cites: [idea.id])
    }
}

/// The morning check-in: what's open, what's waiting, what you captured yesterday. You choose what it covers.
public struct CheckIn: Equatable {
    public struct Options: Codable, Equatable {
        public var projects: [String]
        public var bugs: Bool
        public var todos: Bool
        public var staleIdeas: Bool
        public var yesterday: Bool

        public init(projects: [String] = [], bugs: Bool = true, todos: Bool = true, staleIdeas: Bool = true, yesterday: Bool = true) {
            self.projects = projects
            self.bugs = bugs
            self.todos = todos
            self.staleIdeas = staleIdeas
            self.yesterday = yesterday
        }

        /// One hand-edited value that's missing or the wrong type falls back on its own, not the whole set.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Options()
            projects = (try? c.decodeIfPresent([String].self, forKey: .projects)) ?? d.projects
            bugs = (try? c.decodeIfPresent(Bool.self, forKey: .bugs)) ?? d.bugs
            todos = (try? c.decodeIfPresent(Bool.self, forKey: .todos)) ?? d.todos
            staleIdeas = (try? c.decodeIfPresent(Bool.self, forKey: .staleIdeas)) ?? d.staleIdeas
            yesterday = (try? c.decodeIfPresent(Bool.self, forKey: .yesterday)) ?? d.yesterday
        }
    }

    public struct Group: Equatable {
        public var project: String
        public var lines: [ProjectPage.Line]
    }

    public var greeting: String
    public var groups: [Group]
    public var headline: String

    public var isEmpty: Bool { groups.allSatisfy { $0.lines.isEmpty } }

    /// `muted`: the ledger's "never" keys; a stale idea you muted isn't brought back as "Still waiting".
    public static func build(items: [Item], options: Options, now: Date = Date(), muted: Set<String> = []) -> CheckIn {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let greeting = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!
        let scoped = items.filter { options.projects.isEmpty || options.projects.contains($0.project ?? "") }
        // Most important first (bugs before todos at the same priority), so the cap of 4 per project keeps the urgent ones.
        let importance = { (item: Item) in (item.priority, item.kind == .bug ? 1 : 0, item.updated) }
        let open = scoped.filter { $0.status != .done && ((options.bugs && $0.kind == .bug) || (options.todos && $0.kind == .todo)) }
            .sorted { importance($0) > importance($1) }
        var byProject: [String: [ProjectPage.Line]] = [:]
        var totals = (bugs: 0, todos: 0)
        var counted = Set<String>()
        // Each project's most urgent open item, to order the groups.
        var topRank: [String: Int] = [:]
        for item in open {
            let project = item.project ?? "Inbox"
            counted.insert(item.id)
            topRank[project] = max(topRank[project] ?? -1, item.priority.rank)
            let text: String
            if item.kind == .bug {
                totals.bugs += 1
                text = "Bug: \(item.title)" + (item.priority >= .high ? " (\(item.priority.rawValue))" : "")
            } else {
                totals.todos += 1
                text = "Todo: \(item.title)"
            }
            if (byProject[project]?.count ?? 0) < 4 {
                byProject[project, default: []].append(.init(text: text, cites: [item.id]))
            }
        }
        if options.yesterday {
            for item in scoped where item.created >= yesterday && item.created < calendar.startOfDay(for: now) {
                let project = item.project ?? "Inbox"
                // Open items are already counted, even when the cap left them out; don't bring them back as "Yesterday".
                if !counted.contains(item.id) {
                    byProject[project, default: []].append(.init(text: "Yesterday: \(item.title)", cites: [item.id]))
                }
            }
        }
        if options.staleIdeas, let idea = CompanionPlanner.staleIdea(items: scoped, now: now, excluding: muted) {
            byProject[idea.project ?? "Inbox", default: []].append(.init(text: "Still waiting: \(idea.body)", cites: idea.cites))
        }
        let groups = byProject.map { Group(project: $0.key, lines: $0.value) }
            .sorted { (topRank[$0.project] ?? -1, $0.lines.count) > (topRank[$1.project] ?? -1, $1.lines.count) }
        var parts: [String] = []
        if totals.bugs > 0 { parts.append("\(totals.bugs) open bug\(totals.bugs == 1 ? "" : "s")") }
        if totals.todos > 0 { parts.append("\(totals.todos) todo\(totals.todos == 1 ? "" : "s")") }
        // Only projects with something open, not ones that just have yesterday's notes or an old idea.
        let projects = topRank.count
        let headline = parts.isEmpty ? "Nothing open. A clear day." : parts.joined(separator: " and ") + " across \(projects) project\(projects == 1 ? "" : "s")."
        return CheckIn(greeting: greeting, groups: groups, headline: headline)
    }

    /// The opening for "Plan my day with Claude". Local-only projects are left out: they never go to Claude.
    /// Nil when nothing is left to send.
    public func planPrompt(excluding localOnly: Set<String>) -> String? {
        let lines = groups.filter { !localOnly.contains($0.project) && !$0.lines.isEmpty }
            .map { "\($0.project): " + $0.lines.map(\.text).joined(separator: "; ") }
        guard !lines.isEmpty else { return nil }
        return "Help me pick what to do first today. Here's what's open:\n" + lines.joined(separator: "\n")
    }

    public var nudge: Nudge {
        Nudge(kind: .checkIn, key: "checkin:\(CompanionLedger.dayKey(Date()))", project: nil,
              title: "\(greeting). \(headline)", body: groups.prefix(2).map { "\($0.project): \($0.lines.first?.text ?? "")" }.joined(separator: "\n"),
              cites: groups.flatMap { $0.lines.flatMap(\.cites) })
    }

    /// Whether the check-in is due: after its time today, and not shown yet today.
    public static func isDue(at time: String, lastShown: Date?, now: Date = Date()) -> Bool {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        // A hand-edited "25:00" is never due, rather than whatever the calendar makes of it.
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return false }
        let calendar = Calendar.current
        guard let due = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now), now >= due else { return false }
        if let lastShown, calendar.isDate(lastShown, inSameDayAs: now) { return false }
        // Don't greet you at 11pm for a 9:30 check-in you missed.
        return now.timeIntervalSince(due) < 6 * 3600
    }
}
