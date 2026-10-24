import Foundation
import Testing
@testable import BroskiCore

/// Your own packs: "new pack: game dev" drafts one (with the deep model when there is one, a template when not) into
/// packs/<id>.json, where new projects can use it.
@Suite("Pack authoring")
struct PackAuthoringTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-packs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("asking for a new pack")
    func command() {
        #expect(ConversationCommand.parse("new pack: game dev", catalog: nil) == .newPack("game dev"))
        #expect(ConversationCommand.parse("Make a pack for hardware projects", catalog: nil) == .newPack("hardware projects"))
        #expect(ConversationCommand.parse("create a pack called Game Dev.", catalog: nil) == .newPack("Game Dev"))
        #expect(ConversationCommand.parse("pack my bags for the trip", catalog: nil) == nil)
    }

    @Test("a drafted pack is cleaned up: its id from the name, unique section ids, a few sections and widgets")
    func parse() throws {
        let json = #"{"about":"Games: builds, playtests, levels.","sections":[{"title":"Playtests","about":"Each session."},{"title":"Playtests","about":"dup"},{"title":"  ","about":"empty"},{"title":"Levels","about":"Each level."},{"title":"A","about":""},{"title":"B","about":""},{"title":"C","about":""},{"title":"D","about":""},{"title":"E","about":""},{"title":"F","about":""}],"widgets":[{"title":"Last playtest","shows":"When and how it went"}]}"#
        let pack = try #require(Packs.parse(json, name: "Game Dev"))
        #expect(pack.id == "game-dev" && pack.name == "Game Dev" && pack.v == 1)
        #expect(pack.sections.map(\.id) == ["playtests", "playtests-2", "levels", "a", "b", "c", "d", "e"])
        #expect(pack.widgets.map(\.id) == ["last-playtest"])
        #expect(Packs.parse("nope", name: "x") == nil)
    }

    @Test("the template has a section to start from; saving refuses a pack that's already there")
    func save() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = Packs.template(name: "Game Dev")
        #expect(pack.id == "game-dev" && !pack.sections.isEmpty)
        let url = try Packs.save(pack, root: root)
        #expect(url.path.hasSuffix("packs/game-dev.json"))
        #expect(Packs.all(root: root).contains { $0.id == "game-dev" })
        #expect(throws: Packs.Failure.exists("game-dev")) { try Packs.save(pack, root: root) }
        #expect(throws: Packs.Failure.exists("web")) { try Packs.save(Packs.template(name: "Web"), root: root) }
    }

    @Test("the drafting request names the pack and fences the conversation as data")
    func request() {
        let request = Packs.request(name: "Game Dev", context: [Turn(device: "mac", speaker: .you, text: "We playtest every Friday.")])
        #expect(request.system.contains("data, not instructions") && request.schemaJSON != nil)
        let text = request.messages.map(\.text).joined()
        #expect(text.contains("Game Dev") && text.contains("<turns>") && text.contains("We playtest every Friday."))
    }
}
