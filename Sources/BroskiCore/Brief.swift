import Foundation

// MARK: What's waiting on you

/// Things that need a person, across every project: decisions they decide, steps that are theirs,
/// their own open notes, and messages between threads nobody has read.
public enum WaitingOn {
    public struct Line: Equatable {
        public var project: String
        public var text: String
        public var cite: String
        public var kind: String
        public var since: Date?
        /// From the files; live state (whether a step is ready) needs the tracker's board.
        public var stateFromFiles: Bool
    }

    /// Words trackers use for the person Broski works for.
    public static let defaultAliases = ["you", "founder", "you-and-claude", "you and the team", "you-and-team", "you and the co-developer"]
    /// The owner's own names as their trackers write them (config.json `ownerAliases`), set when the config loads.
    public static var ownerAliases: [String] = []

    public static func lines(records: [TrackerRecord], notes: [Item], aliases: [String] = defaultAliases + ownerAliases) -> [Line] {
        let me = Set(aliases.map { $0.lowercased() })
        func mine(_ who: String) -> Bool { me.contains(who.lowercased().trimmingCharacters(in: .whitespaces)) }
        var out: [Line] = []
        for r in records where !r.archived {
            switch r.kind {
            case "decision" where r.open && (mine(r.fields["decider"] ?? r.owner) || mine(r.owner)):
                out.append(Line(project: r.project, text: "Decide \(r.recordID): \(r.title)", cite: r.id, kind: "decision", since: r.date, stateFromFiles: true))
            case "step" where mine(r.owner) && r.launch != nil:
                out.append(Line(project: r.project, text: "\(r.launch ?? "") step \(r.recordID.split(separator: "/").last ?? ""): \(r.title)",
                                cite: r.id, kind: "step", since: r.date, stateFromFiles: false))
            case "task", "todo":
                if r.open && mine(r.owner) {
                    out.append(Line(project: r.project, text: "\(r.recordID): \(r.title)", cite: r.id, kind: r.kind, since: r.date, stateFromFiles: true))
                }
            default:
                break
            }
        }
        for note in notes where note.isOpenTask {
            out.append(Line(project: note.project ?? "Inbox", text: "\(note.kind.rawValue.capitalized): \(note.title)", cite: note.id,
                            kind: "note", since: note.updated, stateFromFiles: true))
        }
        return out
    }

    /// Unread messages per thread ("who hasn't read their remarks").
    public static func unread(records: [TrackerRecord]) -> [(project: String, thread: String, ids: [String])] {
        let messages = records.filter { $0.kind == "message" && $0.canonical == .unread }
        let grouped = Dictionary(grouping: messages) { "\($0.project)|\($0.fields["to"] ?? $0.owner)" }
        return grouped.map { key, value in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "?", value.map(\.id).sorted())
        }.sorted { $0.ids.count > $1.ids.count }
    }
}

// MARK: What changed

/// A timeline from the records themselves: decisions made, findings opened and closed, messages sent,
/// dated doc sections, plus commits (with the thread that made them) when git is there.
public enum Journal {
    public struct Entry: Equatable {
        public var at: Date
        public var project: String
        public var kind: String
        public var text: String
        public var cite: String?
        public var thread: String?
    }

    public static func entries(records: [TrackerRecord], notes: [Item], since: Date, until: Date = Date()) -> [Entry] {
        var out: [Entry] = []
        let day = TrackerReader.dayFormatter
        for r in records where !r.archived {
            switch r.kind {
            case "decision":
                if let decided = (r.fields["decidedAt"] ?? r.fields["decided_at"]).flatMap({ TrackerReader.parseDate($0) }), decided >= since, decided <= until {
                    out.append(Entry(at: decided, project: r.project, kind: "decided", text: "\(r.recordID) decided: \(r.summary.isEmpty ? r.title : r.summary)", cite: r.id, thread: r.fields["owner_thread"]))
                }
            case "finding", "ops", "bug", "risk":
                if let opened = r.fields["opened"].flatMap(TrackerReader.parseDate), opened >= since, opened <= until {
                    out.append(Entry(at: opened, project: r.project, kind: "opened", text: "\(r.recordID) filed (\(r.severity)): \(r.title)", cite: r.id, thread: r.fields["owner_thread"]))
                }
                if let closed = r.fields["closed"].flatMap(TrackerReader.parseDate), closed >= since, closed <= until {
                    out.append(Entry(at: closed, project: r.project, kind: "closed", text: "\(r.recordID) \(r.status): \(r.title)", cite: r.id, thread: r.fields["owner_thread"]))
                }
            case "message":
                if let at = r.date, at >= since, at <= until {
                    out.append(Entry(at: at, project: r.project, kind: "remark", text: "\(r.fields["by"] ?? "?") → \(r.fields["to"] ?? "?"): \(r.title.prefix(160))", cite: r.id, thread: r.fields["by"]))
                }
            default:
                break
            }
        }
        for note in notes where note.created >= since && note.created <= until {
            out.append(Entry(at: note.created, project: note.project ?? "Inbox", kind: "note", text: "\(note.kind.rawValue.capitalized): \(note.title)", cite: note.id, thread: nil))
        }
        _ = day
        return out.sorted { $0.at > $1.at }
    }

    #if os(macOS)
    /// Commits in a repo since a date, with the `Agent:` trailer as the thread.
    public static func commits(repo: URL, ref: String = "HEAD", since: Date, project: String) -> [Entry] {
        let iso = ISO8601DateFormatter()
        guard let data = GitSnapshotFS.git(repo, ["log", ref, "--since=\(iso.string(from: since))", "--format=%H%x1f%cI%x1f%s%x1f%(trailers:key=Agent,valueonly,separator=%x2c)%x1e"]) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { raw in
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let at = TrackerReader.parseDate(parts[1]) else { return nil }
            let thread = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return Entry(at: at, project: project, kind: "commit", text: "\(parts[0].prefix(7)) \(parts[2])", cite: nil, thread: thread.isEmpty ? nil : thread)
        }
    }
    #endif

    /// "last 3 days", "this week", "yesterday", "since monday" → the start date. Nil when the question isn't about time.
    public static func range(in question: String, now: Date = Date()) -> Date? {
        let q = question.lowercased()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if let m = q.range(of: #"(last|past)\s+(\d+|one|two|three|four|five|six|seven|ten|fourteen)\s+days?"#, options: .regularExpression) {
            let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "ten": 10, "fourteen": 14]
            let token = q[m].split(separator: " ").dropFirst().first.map(String.init) ?? "3"
            let n = Int(token) ?? words[token] ?? 3
            return calendar.date(byAdding: .day, value: -n, to: today)
        }
        if q.contains("yesterday") { return calendar.date(byAdding: .day, value: -1, to: today) }
        if q.contains("today") { return today }
        if q.contains("this week") || q.contains("past week") || q.contains("last week") {
            return calendar.date(byAdding: .day, value: q.contains("last week") ? -14 : -7, to: today)
        }
        if q.contains("this month") || q.contains("last month") { return calendar.date(byAdding: .day, value: -30, to: today) }
        if q.contains("changed") || q.contains("recently") || q.contains("lately") || q.contains("what's new") || q.contains("what happened") {
            return calendar.date(byAdding: .day, value: -7, to: today)
        }
        return nil
    }
}

// MARK: The tracker's live board

/// Reads a tracker's own board for what it derives live (step state, what's next, watcher readings).
/// GET only, loopback only, short timeouts. When the board is down or serves a different revision, the answer
/// is "unknown", never an older value.
public struct TrackerBoard {
    public let base: URL
    public init?(_ url: String) {
        guard let base = URL(string: url), let host = base.host, ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        self.base = base
    }

    public enum Reading {
        case value(Any, fetchedAt: Date)
        case unknown(String)
    }

    /// Paths Broski may call. Anything that triggers work (refresh, POST) is refused here.
    static func allowed(_ path: String) -> Bool {
        guard path.hasPrefix("/api/"), !path.contains("refresh") else { return false }
        return true
    }

    public func get(_ path: String, timeout: TimeInterval = 2) async -> Reading {
        guard Self.allowed(path), let url = URL(string: path, relativeTo: base) else { return .unknown("not an allowed read") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let json = try? JSONSerialization.jsonObject(with: data) else {
                return .unknown("the board answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            return .value(json, fetchedAt: Date())
        } catch {
            return .unknown("board offline")
        }
    }

    /// Whether the board serves the revision Broski indexed (its handshake: /api/agents → main.sha).
    public func handshake(expecting revision: String?) async -> (ok: Bool, note: String) {
        guard case .value(let json, _) = await get("/api/agents") else { return (false, "board offline") }
        let sha = ((json as? [String: Any])?["main"] as? [String: Any])?["sha"] as? String
        guard let revision, let sha else { return (true, "board up") }
        return sha.hasPrefix(String(revision.prefix(7))) || revision.hasPrefix(String(sha.prefix(7)))
            ? (true, "board serves \(sha.prefix(7))") : (false, "board serves \(sha.prefix(7)), Broski read \(revision.prefix(7))")
    }

    /// A compact text form of a live reading for Claude, always stamped with when and from where.
    public static func describe(_ reading: Reading, label: String, maxChars: Int = 6000) -> String {
        switch reading {
        case .unknown(let reason):
            return "\(label): unknown (\(reason)). Do not state any value for it."
        case .value(let json, let at):
            let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return "\(label), read live from the tracker's board at \(ISO8601DateFormatter().string(from: at)):\n" + String(decoding: data.prefix(maxChars), as: UTF8.self)
        }
    }
}
