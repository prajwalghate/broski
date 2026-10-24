import Foundation

/// One change between two reads of a tracker: a record new, closed, reopened, re-statused, decided, attested or gone.
public struct ChangeEvent: Codable, Equatable {
    public var at: Date
    public var project: String
    public var source: String
    /// The tracker revision the change was seen at (nil for a working tree).
    public var revision: String?
    /// new | closed | reopened | status | decided | attested | removed
    public var kind: String
    /// The record's full id ("one:ONE-X190"), usable as a citation.
    public var id: String
    public var title: String
    public var from: String?
    public var to: String?

    public init(at: Date, project: String, source: String, revision: String? = nil, kind: String, id: String, title: String,
                from: String? = nil, to: String? = nil) {
        self.at = at
        self.project = project
        self.source = source
        self.revision = revision
        self.kind = kind
        self.id = id
        self.title = title
        self.from = from
        self.to = to
    }

    /// "ONE-X190 Oracle stale (open → solved)", for a journal line.
    public var summary: String {
        let local = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
        let change = from == nil && to == nil ? "" : " (\(from ?? "–") → \(to ?? "–"))"
        return "\(local) \(title)\(change)"
    }

    /// As a journal entry, so "what changed" can show it beside the records' own dates and the commits.
    public var journalEntry: Journal.Entry {
        Journal.Entry(at: at, project: project, kind: kind, text: summary, cite: id, thread: nil)
    }
}

/// What a tracker held at its last read, kept so the next read can say what changed.
public struct TrackerState: Codable, Equatable {
    public struct Entry: Codable, Equatable {
        public var kind: String
        public var title: String
        /// The tracker's own status word.
        public var status: String
        public var open: Bool
        /// A step's attestation, as the file has it.
        public var attested: String?

        public init(kind: String, title: String, status: String, open: Bool, attested: String? = nil) {
            self.kind = kind
            self.title = title
            self.status = status
            self.open = open
            self.attested = attested
        }
    }

    public var revision: String?
    /// Record id → its state.
    public var records: [String: Entry]

    public init(revision: String? = nil, records: [String: Entry] = [:]) {
        self.revision = revision
        self.records = records
    }
}

/// The change stream: what changed in each tracker between reads, for "what changed" answers that the records'
/// own dates can't give (a finding reopened, a status moved, a step attested, a record gone). Everything lives in
/// Broski's own folder, never the tracker's: events in `projects/<p>/stream.jsonl`, the last state of each tracker
/// in `trackers/state/<id>.json`.
public enum ChangeStream {
    /// The records worth following. History, generated datasets and records without a status (docs, threads,
    /// runbooks) don't change in ways worth telling.
    public static func state(of records: [TrackerRecord], revision: String?) -> TrackerState {
        var out: [String: TrackerState.Entry] = [:]
        for r in records where !r.archived && !r.derived && r.canonical != .none {
            out[r.id] = TrackerState.Entry(kind: r.kind, title: String(r.title.prefix(200)), status: r.status, open: r.open,
                                           attested: r.fields["attested"].flatMap { $0.isEmpty ? nil : $0 })
        }
        return TrackerState(revision: revision, records: out)
    }

    /// The events between two states. No old state means a first read: it's the baseline, not a flood of "new".
    public static func diff(old: TrackerState?, new: TrackerState, project: String, source: String, at: Date = Date()) -> [ChangeEvent] {
        guard let old else { return [] }
        var out: [ChangeEvent] = []
        func event(_ kind: String, _ id: String, _ entry: TrackerState.Entry, from: String? = nil, to: String? = nil) {
            out.append(ChangeEvent(at: at, project: project, source: source, revision: new.revision, kind: kind, id: id, title: entry.title,
                                   from: from.flatMap { $0.isEmpty ? nil : $0 }, to: to.flatMap { $0.isEmpty ? nil : $0 }))
        }
        for (id, now) in new.records.sorted(by: { $0.key < $1.key }) {
            guard let before = old.records[id] else {
                event(now.kind == "decision" && !now.open ? "decided" : "new", id, now)
                continue
            }
            // A message is news once; its read receipt isn't.
            if now.kind == "message" { continue }
            if before.open && !now.open {
                event(now.kind == "decision" ? "decided" : "closed", id, now, from: before.status, to: now.status)
            } else if !before.open && now.open {
                event("reopened", id, now, from: before.status, to: now.status)
            } else if before.status != now.status {
                event("status", id, now, from: before.status, to: now.status)
            }
            if let attested = now.attested, attested != before.attested { event("attested", id, now, to: attestation(attested)) }
        }
        for (id, before) in old.records.sorted(by: { $0.key < $1.key }) where new.records[id] == nil && before.kind != "message" {
            event("removed", id, before, from: before.status)
        }
        return out
    }

    /// `{"at": "…", "by": "ops"}` → "ops at …"; anything else as written, shortened.
    static func attestation(_ raw: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { return String(raw.prefix(120)) }
        let by = TrackerReader.string(object["by"]) ?? "?"
        return TrackerReader.string(object["at"]).map { "\(by) at \($0)" } ?? by
    }

    // MARK: Storage (Broski's folder only)

    public static func streamFile(root: URL, project: String) -> URL {
        root.appendingPathComponent("projects/\(project)/stream.jsonl")
    }

    /// `trackers/state/<id>.json`, the id made a file name the way overlays make it ("tamer/Tamer" → "tamer__Tamer").
    public static func stateFile(root: URL, source: String) -> URL {
        let name = TrackerManifest.overlayName(source).dropLast(TrackerManifest.fileName.count + 1)
        return root.appendingPathComponent("trackers/state", isDirectory: true).appendingPathComponent(String(name) + ".json")
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(FrontMatter.isoFormatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = FrontMatter.isoFormatter.date(from: text) ?? TrackerReader.parseDateString(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an ISO-8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    /// Adds events to the end of a project's stream, one JSON object per line.
    public static func append(_ events: [ChangeEvent], root: URL, project: String) throws {
        guard !events.isEmpty else { return }
        let url = streamFile(root: root, project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let coder = encoder()
        var data = Data()
        for event in events {
            data.append(try coder.encode(event))
            data.append(10)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    /// A project's events since a date, oldest first; every project's when `project` is nil.
    public static func read(root: URL, project: String?, since: Date = .distantPast) -> [ChangeEvent] {
        let files: [URL]
        if let project {
            files = [streamFile(root: root, project: project)]
        } else {
            let projects = root.appendingPathComponent("projects", isDirectory: true)
            files = ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
                .map { $0.appendingPathComponent("stream.jsonl") }
        }
        let coder = decoder()
        var out: [ChangeEvent] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 10) {
                guard let event = try? coder.decode(ChangeEvent.self, from: Data(line)), event.at >= since else { continue }
                out.append(event)
            }
        }
        // Stable: one read's events share a time and keep their order.
        return out.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
    }

    public static func loadState(root: URL, source: String) -> TrackerState? {
        guard let data = try? Data(contentsOf: stateFile(root: root, source: source)) else { return nil }
        return try? decoder().decode(TrackerState.self, from: data)
    }

    public static func saveState(_ state: TrackerState, root: URL, source: String) throws {
        let url = stateFile(root: root, source: source)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder().encode(state).write(to: url, options: .atomic)
    }

    /// Reads overlap (a read cancelled on the main actor keeps running): one at a time, each diffs the state the last one saved.
    private static let lock = NSLock()

    /// After a read of a whole tracker: diff against the last state, append what changed, keep the new state.
    /// A read that found the folder missing changes nothing: it isn't every record removed.
    @discardableResult
    public static func update(with snapshot: TrackerSnapshot, project: String, root: URL, at: Date = Date()) -> [ChangeEvent] {
        if snapshot.records.isEmpty && !snapshot.problems.isEmpty { return [] }
        lock.lock()
        defer { lock.unlock() }
        let old = loadState(root: root, source: snapshot.source)
        let new = state(of: snapshot.records, revision: snapshot.revision)
        // Nothing written when nothing changed, so an unchanged read doesn't wake the notes watcher.
        guard old != new else { return [] }
        let events = diff(old: old, new: new, project: project, source: snapshot.source, at: at)
        do {
            try append(events, root: root, project: project)
            try saveState(new, root: root, source: snapshot.source)
        } catch {
            return []
        }
        return events
    }
}
