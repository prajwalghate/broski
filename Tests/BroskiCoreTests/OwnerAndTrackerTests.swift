import Foundation
import Testing
@testable import BroskiCore

/// Broski works for whoever installs it: no person or private project is named in code. The owner's own names come
/// from config.json, and a project's own tracker shape from an overlay in their Broski folder.
@Suite("Owner names and tracker shapes")
struct OwnerAndTrackerTests {
    /// A scratch folder per test, removed afterwards.
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("config.json carries the owner's names; an older file has none")
    func ownerAliasesDecode() throws {
        let set = try JSONDecoder().decode(BroskiConfig.self, from: Data(#"{"ownerAliases":["sam","founder"]}"#.utf8))
        #expect(set.ownerAliases == ["sam", "founder"])
        let older = try JSONDecoder().decode(BroskiConfig.self, from: Data(#"{"hotkey":"option+shift+b"}"#.utf8))
        #expect(older.ownerAliases.isEmpty)
    }

    @Test("waiting on you finds tasks under the owner's own name, and only once it's set")
    func waitingOnUsesOwnerNames() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = try TrackerTemplate.create(project: "trader", title: "Trader", root: root)
        _ = try TrackerTemplate.add(kind: "task", title: "Backtest the copy rule", owner: "sam", tracker: tracker, root: root)
        let records = TrackerReader.snapshot(TrackerSource(id: "trader", name: "Trader", path: tracker.path), project: "trader", overlays: nil).records

        let generic = WaitingOn.lines(records: records, notes: [], aliases: WaitingOn.defaultAliases)
        #expect(!generic.contains { $0.text.contains("Backtest the copy rule") })
        let owned = WaitingOn.lines(records: records, notes: [], aliases: WaitingOn.defaultAliases + ["sam"])
        #expect(owned.contains { $0.text.contains("Backtest the copy rule") })
    }

    @Test("an unknown shape reads as docs, and the project's overlay wins over any preset")
    func overlayWinsOverPresets() throws {
        let base = try scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("acme-tracker", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("tracker/findings"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("tracker/data"), withIntermediateDirectories: true)
        try Data(#"{"value":{"agents":[]}}"#.utf8).write(to: repo.appendingPathComponent("tracker/data/agents.json"))
        let source = TrackerSource(id: "acme", name: "Acme", path: repo.path)
        #expect(TrackerPresets.detect(source).adapter == "generic-markdown")

        let overlays = base.appendingPathComponent("trackers", isDirectory: true)
        try FileManager.default.createDirectory(at: overlays, withIntermediateDirectories: true)
        let own = TrackerManifest(id: "acme", title: "Acme", adapter: "command-center", core: [
            "findings": [TrackerManifest.Source(reader: "fm-records", glob: "tracker/findings/*.md", kindFrom: "category")],
        ])
        try JSONEncoder().encode(own).write(to: overlays.appendingPathComponent(TrackerManifest.overlayName("acme")))
        #expect(TrackerManifest.resolve(for: source, overlays: overlays) == own)
    }

    @Test("the generic presets name no person")
    func presetsNameNoOne() throws {
        let presets = [
            TrackerPresets.registerItems(id: "a", title: "A", board: nil),
            TrackerPresets.workBoard(id: "b", title: "B"),
            TrackerPresets.broskiTracker(id: "c", title: "C"),
            TrackerPresets.genericMarkdown(id: "d", title: "D", docsOnly: false),
        ]
        for preset in presets {
            let people = preset.people ?? [:]
            #expect(Set(people.keys).isSubset(of: ["owner", "claude", "team"]), "\(preset.adapter): \(people.keys.sorted())")
        }
    }
}
