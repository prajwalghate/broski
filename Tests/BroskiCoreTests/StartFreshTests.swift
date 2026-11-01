import Foundation
import Testing
@testable import BroskiCore

/// Settings › General › Start fresh: three separate levels, each saying what it clears and what it keeps, and none
/// of them deletes anything. Every test works in a temporary folder, never the person's Broski folder.
@Suite("Start fresh")
struct StartFreshTests {
    /// A parent folder holding a Broski folder, so archives land beside it as they would next to the real one.
    private func scratch() throws -> (parent: URL, root: URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("broski-fresh-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Broski", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (parent, root)
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let day = ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z")!

    @Test("each level says what it clears and what it keeps, and none of them deletes anything")
    func levelsExplainThemselves() {
        for level in StartFresh.Level.allCases {
            let effect = StartFresh.effect(level)
            #expect(!effect.clears.isEmpty && !effect.keeps.isEmpty, "\(level)")
            #expect(!(effect.clears + effect.keeps).joined().lowercased().contains("delete"), "\(level): nothing is deleted")
        }
        #expect(StartFresh.effect(.pauseMemory).keeps.contains { $0.contains("What Broski knows about you") })
        #expect(StartFresh.effect(.everything).keeps.contains { $0.contains("model keys") })
        #expect(StartFresh.effect(.everything, forgetKeys: true).clears.contains { $0.contains("model keys") })
        #expect(!StartFresh.effect(.everything, forgetKeys: true).keeps.contains { $0.contains("model keys") })
    }

    @Test("a paused memory isn't sent with a reply, and nothing it knows is lost")
    func pausedMemoryIsKeptButUnused() throws {
        let (parent, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        try Memory.remember("Prefers short answers", root: root, device: "mac")
        var config = BroskiConfig.defaults
        #expect(ReplyMemory.gather(root: root, project: nil, isPrivate: false, config: config).aboutYou != nil)
        config.memoryPaused = true
        let paused = ReplyMemory.gather(root: root, project: nil, isPrivate: false, config: config)
        #expect(paused.aboutYou == nil)
        #expect(!paused.recallsConversations, "what you said before isn't recalled either")
        #expect(Memory.aboutYou(root: root)?.contains("Prefers short answers") == true, "kept, ready for when it's back on")
        #expect(ReplyMemory.gather(root: root, project: nil, isPrivate: false, config: .defaults).recallsConversations)
    }

    @Test("the pause switch and paused briefs are kept in config.json, and an older config still reads")
    func pauseIsStored() throws {
        var config = BroskiConfig.defaults
        config.memoryPaused = true
        config.pausedBriefs = ["recipe-box"]
        let decoded = try JSONDecoder().decode(BroskiConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.memoryPaused && decoded.pausedBriefs == ["recipe-box"])
        // A config.json written before these switches existed.
        let old = #"{"showFloatingButton":false,"hotkey":"option+shift+b","reflection":true,"localOnlyProjects":["garden"]}"#
        let upgraded = try JSONDecoder().decode(BroskiConfig.self, from: Data(old.utf8))
        #expect(!upgraded.memoryPaused && upgraded.pausedBriefs.isEmpty && upgraded.localOnlyProjects == ["garden"])
    }

    @Test("forgetting what Broski knows about you keeps the old words aside, and leaves notes alone")
    func forgetMe() throws {
        let (parent, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        try write("Calls me Sam. Building a recipe app.", "memory/about-you.md", in: root)
        try write("a note", "projects/recipe-box/2026-10-30-0900-a-note.md", in: root)
        // Remembered the day before, so the order doesn't depend on when the test runs.
        try Memory.remember("Prefers short answers", root: root, device: "mac", at: day.addingTimeInterval(-86_400))
        try Memory.remember("Works late on Fridays", root: root, device: "iphone", at: day.addingTimeInterval(-86_400))

        let forgotten = try StartFresh.forgetMe(root: root, device: "mac", at: day)
        #expect(forgotten == 3, "two remembered facts and the about-you page")
        #expect(Memory.aboutYou(root: root) == nil)
        let aside = root.appendingPathComponent("memory/forgotten/about-you 2026-11-01.md")
        #expect((try? String(contentsOf: aside, encoding: .utf8)) == "Calls me Sam. Building a recipe app.")
        // The iPhone's file is the iPhone's: the Mac writes its forgets into its own.
        let phone = try String(contentsOf: root.appendingPathComponent("memory/remembered.iphone.jsonl"), encoding: .utf8)
        #expect(phone.contains("Works late on Fridays") && !phone.contains("forget"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/recipe-box/2026-10-30-0900-a-note.md").path))
        #expect(try StartFresh.forgetMe(root: root, device: "mac", at: day) == 0, "nothing left to forget")
    }

    @Test("starting completely fresh moves the whole folder aside, and Broski starts again in an empty one")
    func everythingIsArchived() throws {
        let (parent, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        try write("a note", "projects/recipe-box/2026-10-30-0900-a-note.md", in: root)
        try Memory.remember("Prefers short answers", root: root, device: "mac")
        var config = BroskiConfig.defaults
        config.models = ModelSettings.defaults
        config.hotkey = "option+shift+k"
        config.projectRoots = ["~/Developer"]
        config.ownerAliases = ["sam"]
        config.localOnlyProjects = ["garden"]
        config.memoryPaused = true
        config.pausedBriefs = ["recipe-box"]
        try config.save(to: root.appendingPathComponent("config.json"))

        let archive = try StartFresh.everything(root: root, config: config, at: day)
        #expect(archive.lastPathComponent == "Broski (archived 2026-11-01)")
        #expect(archive.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: archive.appendingPathComponent("projects/recipe-box/2026-10-30-0900-a-note.md").path))
        #expect(Memory.aboutYou(root: archive) != nil, "everything it knew is in the archive")

        // The new folder: only a config.json, so the first conversation starts again.
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(left == ["config.json"])
        #expect(FirstRun.needed(turns: ConversationStore(root: root, device: "mac").recent(10), aboutYou: Memory.aboutYou(root: root)))
        let fresh = BroskiConfig.load(at: root.appendingPathComponent("config.json")).config
        #expect(fresh.models == ModelSettings.defaults && fresh.hotkey == "option+shift+k", "models and shortcuts come along")
        #expect(fresh.localOnlyProjects == ["garden"], "a local-only mark stays, in case the project comes back")
        #expect(fresh.projectRoots.isEmpty && fresh.ownerAliases.isEmpty && !fresh.memoryPaused && fresh.pausedBriefs.isEmpty)

        // A second fresh start the same day gets its own name.
        let again = try StartFresh.everything(root: root, config: fresh, at: day)
        #expect(again.lastPathComponent == "Broski (archived 2026-11-01 2)")
        #expect(StartFresh.archives(of: root).map(\.lastPathComponent) == ["Broski (archived 2026-11-01 2)", "Broski (archived 2026-11-01)"])
    }

    @Test("if starting fresh fails after the move, the folder goes back where it was")
    func everythingIsAllOrNothing() throws {
        let (parent, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        try write("a note", "projects/recipe-box/2026-10-30-0900-a-note.md", in: root)
        struct Full: Error {}
        #expect(StartFresh.nextArchive(of: root, at: day).lastPathComponent == "Broski (archived 2026-11-01)")
        #expect(throws: Full.self) {
            try StartFresh.everything(root: root, config: .defaults, at: day, write: { _, _ in throw Full() })
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/recipe-box/2026-10-30-0900-a-note.md").path))
        #expect(StartFresh.archives(of: root).isEmpty)
    }

    @Test("an archived folder can be put back, and the folder it replaces is archived too")
    func restore() throws {
        let (parent, root) = try scratch()
        defer { try? FileManager.default.removeItem(at: parent) }
        try write("a note", "projects/recipe-box/2026-10-30-0900-a-note.md", in: root)
        let archive = try StartFresh.everything(root: root, config: .defaults, at: day)
        try write("since", "inbox/2026-11-02-0900-since.md", in: root)

        let later = day.addingTimeInterval(86_400)
        let replaced = try #require(try StartFresh.restore(archive, root: root, at: later))
        #expect(replaced.lastPathComponent == "Broski (archived 2026-11-02)")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/recipe-box/2026-10-30-0900-a-note.md").path))
        #expect(FileManager.default.fileExists(atPath: replaced.appendingPathComponent("inbox/2026-11-02-0900-since.md").path))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(throws: StartFresh.Problem.self) { try StartFresh.restore(archive, root: root, at: later) }
        // With no folder in use at all, it just goes back.
        try FileManager.default.removeItem(at: root)
        try StartFresh.restore(replaced, root: root, at: later)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("inbox/2026-11-02-0900-since.md").path))
    }
}
