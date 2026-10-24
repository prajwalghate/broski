import Foundation

/// A project's command center: the packs it uses and the widgets they bring (from `setup/command-center.json`, which
/// you can edit), each filled with what Broski knows. Core widgets read your notes and decisions; a pack's widget reads
/// the newest records in its tracker section; anything Broski can't fill yet says so instead of making numbers up.
public struct CommandCenter: Equatable, Sendable {
    public var project: String
    public var packs: [Pack]
    public var widgets: [Pack.Widget]
    /// From the project's own setup file (false: core and the packs its folders suggest).
    public var fromSetup: Bool

    public init(project: String, packs: [Pack], widgets: [Pack.Widget], fromSetup: Bool) {
        self.project = project
        self.packs = packs
        self.widgets = widgets
        self.fromSetup = fromSetup
    }

    public struct Tile: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        /// Up to five lines, newest or most pressing first.
        public var lines: [String]
        /// How many there are in all, when that's the point.
        public var count: Int?
        /// The tracker section it reads, when it reads one.
        public var section: String?
        /// Why it's empty, when it is.
        public var empty: String?
    }

    public struct SectionRow: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var about: String
        public var pack: String
        public var count: Int
        public var newest: String?
    }

    static func setupFile(project: String, root: URL) -> URL {
        root.appendingPathComponent("projects/\(project)/setup/command-center.json")
    }

    public static func load(project: String, root: URL, folders: [URL]) -> CommandCenter {
        let file = setupFile(project: project, root: root)
        if let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let packs = Packs.resolve(["core"] + ((object["packs"] as? [String]) ?? []), root: root)
            let widgets = ((object["widgets"] as? [[String: Any]]) ?? []).compactMap { raw -> Pack.Widget? in
                guard let id = raw["id"] as? String, let title = raw["title"] as? String else { return nil }
                return Pack.Widget(id: id, title: title, shows: (raw["shows"] as? String) ?? "")
            }
            return CommandCenter(project: project, packs: packs, widgets: widgets.isEmpty ? packs.flatMap(\.widgets) : widgets, fromSetup: true)
        }
        var ids = ["core"]
        for id in folders.flatMap(Packs.suggest(forFolder:)) where !ids.contains(id) { ids.append(id) }
        let packs = Packs.resolve(ids, root: root)
        return CommandCenter(project: project, packs: packs, widgets: packs.flatMap(\.widgets), fromSetup: false)
    }

    /// Words too general to tie a widget to a section ("Latest build" is about builds, not about "latest").
    private static let general: Set<String> = ["latest", "last", "next", "recent", "status", "open", "this", "week", "now", "and", "the"]

    private static func words(_ texts: String...) -> Set<String> {
        Set(texts.flatMap { $0.lowercased().split { !$0.isLetter } }.map(String.init).filter { $0.count >= 4 && !general.contains($0) })
    }

    /// The pack section a widget reads: one whose words share a stem with the widget's ("build" and "builds").
    static func section(for widget: Pack.Widget, in center: CommandCenter) -> Pack.Section? {
        let mine = words(widget.id, widget.title)
        return center.packs.flatMap(\.sections).first { section in
            words(section.id, section.title).contains { theirs in mine.contains { theirs.hasPrefix($0) || $0.hasPrefix(theirs) } }
        }
    }

    /// A section's records, newest first (its README, written when the pack was applied, isn't one).
    static func records(in section: String, _ records: [TrackerRecord]) -> [TrackerRecord] {
        records.filter { $0.path.contains("layers/\(section)/") && $0.file.lastPathComponent != "README.md" && !$0.archived }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    public static func tiles(_ center: CommandCenter, items: [Item], decisions: [Decision], records: [TrackerRecord]) -> [Tile] {
        center.widgets.map { widget in
            var tile = Tile(id: widget.id, title: widget.title, lines: [], count: nil, section: nil, empty: nil)
            switch widget.id {
            case "open":
                let open = items.filter { $0.project == center.project && $0.isOpenTask }.sorted { $0.updated > $1.updated }
                tile.lines = open.prefix(5).map(\.title)
                tile.count = open.count
                if open.isEmpty { tile.empty = "Nothing open. Todos and bugs you save show here." }
            case "decisions":
                tile.lines = decisions.reversed().prefix(5).map { "\(Recall.dayString($0.at)) · \($0.text)" }
                if decisions.isEmpty { tile.empty = "No decisions yet. Ones you save from a conversation show here." }
            case "milestone":
                let next = records.filter { $0.kind.contains("milestone") && $0.open }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                tile.lines = next.prefix(1).map(\.title)
                if next.isEmpty { tile.empty = "No open milestone in the tracker yet." }
            default:
                if let section = section(for: widget, in: center) {
                    let found = Self.records(in: section.id, records)
                    tile.section = section.id
                    tile.lines = found.prefix(5).map(\.title)
                    tile.count = found.count
                    if found.isEmpty { tile.empty = "Nothing in \(section.title) yet. Add a note to the tracker's layers/\(section.id)/." }
                } else {
                    tile.empty = "\(widget.shows.isEmpty ? widget.title : widget.shows). Not connected yet."
                }
            }
            return tile
        }
    }

    /// Every pack section (core has none), with how many records it holds and the newest.
    public static func sections(_ center: CommandCenter, records: [TrackerRecord]) -> [SectionRow] {
        center.packs.flatMap { pack in
            pack.sections.map { section in
                let found = Self.records(in: section.id, records)
                return SectionRow(id: section.id, title: section.title, about: section.about, pack: pack.name, count: found.count,
                                  newest: found.first?.title)
            }
        }
    }
}
