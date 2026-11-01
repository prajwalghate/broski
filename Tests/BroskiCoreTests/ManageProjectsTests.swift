import Foundation
import Testing
@testable import BroskiCore

/// Settings › Projects › Your projects: add, edit and remove projects in projects.json. Removing one only takes it
/// off Broski's list: its notes and its code stay where they are.
@Suite("Managing projects")
struct ManageProjectsTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broski-manage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a new project gets a folder-safe id from its name, and a name already used is refused")
    func add() throws {
        var registry = ProjectRegistry()
        let entry = try registry.add(name: "Strado Sniper", about: "Sniping bots on Strado.")
        #expect(entry.notes == "strado-sniper" && entry.name == "Strado Sniper" && entry.about == "Sniping bots on Strado.")
        #expect(registry.projects.map(\.notes) == ["strado-sniper"])
        #expect(throws: ProjectSetup.Failure.exists("strado-sniper")) { try registry.add(name: "strado sniper", about: "") }
        registry.projects[0].aliases = ["sniper"]
        #expect(throws: ProjectSetup.Failure.exists("sniper")) { try registry.add(name: "Sniper", about: "") }
        #expect(throws: ProjectSetup.Failure.badName) { try registry.add(name: "  !! ", about: "") }
    }

    @Test("connecting and disconnecting a code folder, with the tracker found in it")
    func folders() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("code/strado")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("register/items"), withIntermediateDirectories: true)
        var registry = ProjectRegistry()
        _ = try registry.add(name: "Strado", about: "")
        let found = try registry.connect(folder: repo, to: "strado")
        #expect(found.tracker == "register-items")
        #expect(registry.entry(notes: "strado")?.folders == [repo.path] && registry.entry(notes: "strado")?.trackers.count == 1)
        registry.disconnect(folder: repo.path, from: "strado")
        #expect(registry.entry(notes: "strado")?.folders.isEmpty == true && registry.entry(notes: "strado")?.trackers.isEmpty == true,
                "the folder's tracker goes with it")
        #expect(throws: ProjectSetup.Failure.noFolder(root.appendingPathComponent("nope").path)) {
            try registry.connect(folder: root.appendingPathComponent("nope"), to: "strado")
        }
    }

    @Test("removing a project takes it off the list, and leaves its notes and code alone")
    func remove() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("projects/strado/2026-10-30-0900-a-note.md")
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "a note".write(to: note, atomically: true, encoding: .utf8)
        var registry = ProjectRegistry()
        _ = try registry.add(name: "Strado", about: "")
        _ = try registry.add(name: "Tamer", about: "")
        try registry.save(to: root)
        registry.remove(notes: "strado")
        try registry.save(to: root)
        #expect(ProjectRegistry.load(from: root).projects.map(\.notes) == ["tamer"])
        #expect(FileManager.default.fileExists(atPath: note.path))
    }

    @Test("an unreadable projects.json is never written over")
    func unreadableIsKept() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(ProjectRegistry.fileName)
        try "{ half a sync".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: ProjectRegistry.EditProblem.unreadable) {
            try ProjectRegistry.edit(at: root) { try $0.add(name: "Tamer", about: "") }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ half a sync")
        // No file at all is a fresh start, not a problem.
        try FileManager.default.removeItem(at: file)
        try ProjectRegistry.edit(at: root) { try $0.add(name: "Tamer", about: "") }
        #expect(ProjectRegistry.load(from: root).projects.map(\.notes) == ["tamer"])
    }

    @Test("editing one project keeps a project added meanwhile, and only changes that one")
    func editIsFresh() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectRegistry.edit(at: root) { try $0.add(name: "Strado", about: "") }
        let seen = ProjectRegistry.load(from: root)
        // Something else adds a project while the editor is open.
        try ProjectRegistry.edit(at: root) { try $0.add(name: "Tamer", about: "") }
        _ = seen
        try ProjectRegistry.edit(at: root) { try $0.update(notes: "strado", name: "Strado", about: "Copy trading", aliases: ["strado trade"]) }
        let now = ProjectRegistry.load(from: root)
        #expect(now.projects.map(\.notes) == ["strado", "tamer"])
        #expect(now.entry(notes: "strado")?.about == "Copy trading" && now.entry(notes: "strado")?.aliases == ["strado trade"])
    }

    @Test("a rename or other name another project already uses is refused")
    func updateRefusesClashes() throws {
        var registry = ProjectRegistry()
        try registry.add(name: "Strado", about: "")
        try registry.add(name: "Tamer", about: "")
        #expect(throws: ProjectSetup.Failure.exists("strado")) {
            try registry.update(notes: "tamer", name: "Strado", about: "", aliases: [])
        }
        #expect(throws: ProjectSetup.Failure.exists("strado")) {
            try registry.update(notes: "tamer", name: "Tamer", about: "", aliases: ["strado"])
        }
        try registry.update(notes: "strado", name: "Strado Trade", about: "", aliases: ["strado"])
        #expect(registry.entry(notes: "strado")?.name == "Strado Trade", "its own names are fine")
    }

    @Test("taking a folder off drops trackers inside it, however the path was written")
    func disconnectByPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var registry = ProjectRegistry(projects: [ProjectRegistry.Entry(
            name: "Strado", notes: "strado", folders: ["~/code/strado"],
            trackers: [TrackerSource(id: "strado", name: "t", path: "~/code/strado/tracker", readOnly: true),
                       TrackerSource(id: "other", name: "o", path: "~/code/other", readOnly: true)])])
        registry.disconnect(folder: home + "/code/strado", from: "strado")
        #expect(registry.entry(notes: "strado")?.folders.isEmpty == true)
        #expect(registry.entry(notes: "strado")?.trackers.map(\.id) == ["other"])
    }

    @Test("other names are typed as a comma-separated list")
    func aliases() {
        #expect(ProjectRegistry.aliases(from: " SAI, sai coach ,, textsai ") == ["SAI", "sai coach", "textsai"])
        #expect(ProjectRegistry.aliases(from: "  ").isEmpty)
    }

    @Test("what you say lands in the message box to check, unless you ask for it to send at once; older configs keep that")
    func voiceWaitsForYou() throws {
        #expect(!BroskiConfig.defaults.sendWhenSpoken)
        let old = #"{"hotkey":"option+shift+b"}"#
        #expect(!(try JSONDecoder().decode(BroskiConfig.self, from: Data(old.utf8))).sendWhenSpoken)
        var config = BroskiConfig.defaults
        config.sendWhenSpoken = true
        #expect(try JSONDecoder().decode(BroskiConfig.self, from: JSONEncoder().encode(config)).sendWhenSpoken)
    }
}
