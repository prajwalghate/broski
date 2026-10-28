import Foundation
import Testing
@testable import BroskiCore

/// What the Mac and the iPhone conversations share: asking what's worth saving, saving a card, and keeping a
/// private conversation.
@Suite("Shared conversation steps")
struct SharedConversationTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("the save review reads the last few turns, knows only the projects it may file into, and the standing decisions")
    func reviewRequest() throws {
        let turns = [
            Turn(device: "mac", speaker: .topic, text: "strado"),
            Turn(device: "mac", speaker: .you, text: "Let's paper-trade a week first."),
            Turn(device: "mac", speaker: .broski, text: "Good call."),
            Turn(device: "mac", speaker: .note, text: "Noted in strado: x"),
        ]
        let standing = [Decision(device: "mac", project: "strado", text: "Start live with $500")]
        let request = try #require(SaveCard.request(turns: turns, projects: ["strado", "broski"], decisions: standing, project: "strado"))
        let text = request.messages.map(\.text).joined()
        #expect(text.contains("User: Let's paper-trade a week first.") && text.contains("Broski: Good call."))
        #expect(!text.contains("Noted in strado"))
        #expect(request.system.contains("strado, broski") && request.system.contains("- Start live with $500"))
        #expect(request.schemaJSON == SaveCard.schemaJSON)
        #expect(SaveCard.request(turns: [Turn(device: "mac", speaker: .broski, text: "Hi")], projects: [], decisions: [], project: nil) == nil)
    }

    @Test("saving a card writes notes to the project, decisions to its log and change stream, and says what it saved")
    func saveCard() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = SaveCard(project: "strado", items: [
            .init(kind: .decision, title: "Paper-trade a week first", replaces: "d1"),
            .init(kind: .todo, title: "Set up the paper account"),
            .init(kind: .todo, title: "Write the risk check", body: "2% per position"),
        ])
        let summary = try SaveCard.save(card, store: ItemStore(root: root), root: root, device: "iphone", turn: "t9")
        #expect(summary == "Saved to strado: 1 decision, 2 todos")
        let decisions = DecisionLog.all(root: root, project: "strado")
        #expect(decisions.map(\.text) == ["Paper-trade a week first"] && decisions.first?.device == "iphone")
        #expect(decisions.first?.replaces == "d1" && decisions.first?.turn == "t9")
        let items = ItemStore(root: root).allItems()
        #expect(items.count == 2 && items.allSatisfy { $0.project == "strado" && $0.kind == .todo && $0.tags == ["conversation"] })
        #expect(ChangeStream.read(root: root, project: "strado").contains { $0.kind == "decided" })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/strado/stream.iphone.jsonl").path),
                "the iPhone's decision goes in its own stream file")
    }

    @Test("keeping a private conversation copies its files into the project's resources")
    func keepPrivate() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8]).write(to: photo)
        let turns = [Turn(device: "iphone", speaker: .you, text: "Look", files: [photo.path], project: "strado"),
                     Turn(device: "iphone", speaker: .broski, text: "Nice")]
        let kept = Resources.keep(turns, root: root)
        let path = try #require(kept.first?.files?.first)
        #expect(path.hasPrefix("projects/strado/resources/") && path.hasSuffix("photo.jpg"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(kept.last?.files == nil)
    }
}
