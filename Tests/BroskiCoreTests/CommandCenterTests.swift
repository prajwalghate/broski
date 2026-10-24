import Foundation
import Testing
@testable import BroskiCore

/// The command center: each project's packs and widgets (from setup/command-center.json), filled with what Broski
/// knows: open work, decisions, the next milestone, and the newest records in each pack's tracker sections.
@Suite("Command center")
struct CommandCenterTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let day = ISO8601DateFormatter().date(from: "2026-10-24T10:00:00Z")!

    private func record(_ path: String, _ title: String, kind: String = "doc", open: Bool = true, daysAgo: Double = 0) -> TrackerRecord {
        TrackerRecord(id: "t:\(path)", recordID: path, source: "t", project: "set-log", kind: kind, title: title, summary: "",
                      status: open ? "open" : "done", canonical: open ? .open : .done, owner: "", severity: "", section: .layer,
                      layer: "layers", date: day.addingTimeInterval(-daysAgo * 86_400), refs: [], body: "",
                      file: URL(fileURLWithPath: "/x/\(path)"), path: path, link: nil, launch: nil, archived: false, derived: false,
                      lowTrust: false, fields: [:])
    }

    @Test("a created project's command center comes from its setup file; others from core and what their folders suggest")
    func load() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectSetup.create(ProjectProposal(name: "Set Log", summary: "", packs: ["mobile"], goals: [], questions: []), root: root, date: day)
        let center = CommandCenter.load(project: "set-log", root: root, folders: [])
        #expect(center.packs.map(\.id) == ["core", "mobile"])
        #expect(center.widgets.map(\.id).prefix(3) == ["open", "decisions", "milestone"])
        #expect(center.fromSetup)

        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "".write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let connected = CommandCenter.load(project: "strado", root: root, folders: [repo])
        #expect(connected.packs.map(\.id) == ["core", "web"] && !connected.fromSetup)
    }

    @Test("tiles: open work, decisions, the next milestone, a pack widget from its section, and an honest empty one")
    func tiles() throws {
        let center = CommandCenter(project: "set-log", packs: Packs.resolve(["core", "mobile"], root: URL(fileURLWithPath: "/nonexistent")),
                                   widgets: [Pack.Widget(id: "open", title: "Open now", shows: ""),
                                             Pack.Widget(id: "decisions", title: "Recent decisions", shows: ""),
                                             Pack.Widget(id: "milestone", title: "Next milestone", shows: ""),
                                             Pack.Widget(id: "build", title: "Latest build", shows: "Version and where it is"),
                                             Pack.Widget(id: "crash", title: "Crash rate", shows: "Once a source is connected")],
                                   fromSetup: true)
        let open = [("Parse spoken sets", NoteKind.todo, ItemStatus.todo), ("Mic cuts out", .bug, .doing), ("Old", .todo, .done), ("Idea", .idea, .inbox)]
        let items = open.enumerated().map { i, entry in
            Item(id: "i\(i)", file: URL(fileURLWithPath: "/x/\(i).md"), project: "set-log", kind: entry.1, status: entry.2, priority: .normal,
                 tags: [], title: entry.0, body: "", created: day, updated: day.addingTimeInterval(Double(i)), context: ItemContext(), attachments: [])
        }
        let decisions = [Decision(at: day, device: "mac", project: "set-log", text: "Kilos only")]
        let records = [record("layers/builds/README.md", "Builds"), record("layers/builds/0.2.md", "0.2 on TestFlight", daysAgo: 1),
                       record("layers/builds/0.3.md", "0.3 on TestFlight"), record("milestones/beta.md", "Beta", kind: "milestone"),
                       record("milestones/alpha.md", "Alpha", kind: "milestone", open: false)]
        let tiles = CommandCenter.tiles(center, items: items, decisions: decisions, records: records)
        #expect(tiles.map(\.id) == ["open", "decisions", "milestone", "build", "crash"])
        #expect(tiles[0].count == 2 && tiles[0].lines == ["Mic cuts out", "Parse spoken sets"])
        #expect(tiles[1].lines == ["Oct 24 · Kilos only"])
        #expect(tiles[2].lines == ["Beta"])
        #expect(tiles[3].lines == ["0.3 on TestFlight", "0.2 on TestFlight"] && tiles[3].section == "builds")
        #expect(tiles[4].lines.isEmpty && tiles[4].empty?.contains("Once a source is connected") == true)

        let sections = CommandCenter.sections(center, records: records)
        #expect(sections.first { $0.id == "builds" }?.count == 2)
        #expect(sections.first { $0.id == "review" }?.count == 0)
    }
}
