import Foundation
import Testing
@testable import BroskiCore

/// The home conversation: kept as day files per device, steered by plain-language commands, saving only on a tap.
@Suite("Conversation: store, commands, save cards, context")
struct ConversationTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-convo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let iso = ISO8601DateFormatter()
    private func at(_ s: String) -> Date { iso.date(from: s)! }

    // MARK: Store

    @Test("each device writes its own day file; reading merges every device in time order")
    func storeMergesDevices() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let mac = ConversationStore(root: root, device: "mac")
        let phone = ConversationStore(root: root, device: "iphone")
        try mac.append(Turn(at: at("2026-10-24T09:00:00Z"), device: "mac", speaker: .you, text: "Paper week first?", project: "strado"))
        try phone.append(Turn(at: at("2026-10-24T09:05:00Z"), device: "iphone", speaker: .you, text: "Also the crash day.", project: "strado"))
        try mac.append(Turn(at: at("2026-10-24T09:01:00Z"), device: "mac", speaker: .broski, text: "Yes, with a pass bar.", project: "strado"))

        let day = at("2026-10-24T09:00:00Z")
        #expect(mac.turns(on: day).map(\.text) == ["Paper week first?", "Yes, with a pass bar.", "Also the crash day."])
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("conversations").path).filter { $0.hasSuffix(".jsonl") }
        #expect(Set(files.map { ($0 as NSString).lastPathComponent }) == ["2026-10-24.mac.jsonl", "2026-10-24.iphone.jsonl"])
    }

    @Test("recent turns reach back across days, newest last; damaged lines are skipped")
    func recentAcrossDays() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(root: root, device: "mac")
        try store.append(Turn(at: at("2026-10-22T10:00:00Z"), device: "mac", speaker: .you, text: "older"))
        try store.append(Turn(at: at("2026-10-23T10:00:00Z"), device: "mac", speaker: .you, text: "yesterday"))
        try store.append(Turn(at: at("2026-10-24T10:00:00Z"), device: "mac", speaker: .broski, text: "today"))
        let today = root.appendingPathComponent("conversations/2026-10/2026-10-24.mac.jsonl")
        let handle = try FileHandle(forWritingTo: today)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()

        #expect(store.recent(2).map(\.text) == ["yesterday", "today"])
        #expect(store.recent(10).map(\.text) == ["older", "yesterday", "today"])
        #expect(store.recent(10, project: "strado").isEmpty)
    }

    @Test("a turn written by a newer Broski still reads")
    func forwardCompatible() throws {
        let line = #"{"v":2,"id":"t1","at":"2026-10-24T10:00:00Z","device":"mac","speaker":"you","text":"hi","mood":"curious"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(Turn.self, from: Data(line.utf8))
        #expect(turn.text == "hi" && turn.v == 2)
    }

    // MARK: Commands

    @Test("plain-language commands")
    func commands() {
        let catalog = ProjectCatalog(projects: ["strado", "broski"].map { Project(name: $0) })
        #expect(ConversationCommand.parse("note: rotate the API keys", catalog: catalog) == .note("rotate the API keys"))
        #expect(ConversationCommand.parse("Note:   replay the crash day", catalog: catalog) == .note("replay the crash day"))
        #expect(ConversationCommand.parse("go private", catalog: catalog) == .goPrivate)
        #expect(ConversationCommand.parse("Leave private mode.", catalog: catalog) == .leavePrivate)
        #expect(ConversationCommand.parse("think harder", catalog: catalog) == .thinkHarder)
        #expect(ConversationCommand.parse("save that", catalog: catalog) == .saveThat)
        #expect(ConversationCommand.parse("remember that I prefer short replies", catalog: catalog) == .remember("I prefer short replies"))
        #expect(ConversationCommand.parse("forget that", catalog: catalog) == .forget(""))
        #expect(ConversationCommand.parse("switch to strado", catalog: catalog) == .switchProject("strado"))
        #expect(ConversationCommand.parse("switch to the moon", catalog: catalog) == nil)
        // Ordinary sentences aren't commands.
        #expect(ConversationCommand.parse("note that the guard has to land first", catalog: catalog) == nil)
        #expect(ConversationCommand.parse("should I think harder about pricing?", catalog: catalog) == nil)
    }

    // MARK: Save cards

    @Test("a save card keeps known kinds, at most five items, and a known project")
    func saveCardParsing() throws {
        let catalog = ProjectCatalog(projects: ["strado"].map { Project(name: $0) })
        let json = #"{"project":"Strado","items":[{"kind":"decision","title":"Paper week before real money","body":"Pass bar: fills within 0.2%."},{"kind":"todo","title":"Write the stop-loss guard","body":""},{"kind":"spaceship","title":"nope","body":""},{"kind":"bug","title":"  ","body":""}]}"#
        let card = try #require(SaveCard.parse(json, catalog: catalog))
        #expect(card.project == "strado")
        #expect(card.items.map(\.kind) == [.decision, .todo])
        #expect(card.items.first?.body == "Pass bar: fills within 0.2%.")

        let many = #"{"project":"","items":["# + (1...8).map { #"{"kind":"todo","title":"task \#($0)","body":""}"# }.joined(separator: ",") + "]}"
        #expect(SaveCard.parse(many, catalog: catalog)?.items.count == 5)
        #expect(SaveCard.parse(many, catalog: catalog)?.project == nil)
        #expect(SaveCard.parse(#"{"project":"strado","items":[]}"#, catalog: catalog) == nil)
        #expect(SaveCard.parse("not json", catalog: catalog) == nil)
    }

    // MARK: Context

    private var turns: [Turn] {
        [Turn(at: at("2026-10-24T09:00:00Z"), device: "mac", speaker: .broski, text: "Welcome back."),
         Turn(at: at("2026-10-24T09:01:00Z"), device: "mac", speaker: .you, text: "Paper week first?"),
         Turn(at: at("2026-10-24T09:02:00Z"), device: "mac", speaker: .note, text: "Noted: rotate keys"),
         Turn(at: at("2026-10-24T09:03:00Z"), device: "mac", speaker: .you, text: "And a pass bar."),
         Turn(at: at("2026-10-24T09:04:00Z"), device: "mac", speaker: .broski, text: "Agreed."),
         Turn(at: at("2026-10-24T09:05:00Z"), device: "mac", speaker: .you, text: "What next?")]
    }

    @Test("a turn's context: memory fenced as data, turns alternating and starting with you")
    func contextNormal() {
        let request = ConversationContext.build(aboutYou: "Prefers short replies.", page: nil, project: "strado", turns: turns, isPrivate: false)
        #expect(request.system.contains("Prefers short replies."))
        #expect(request.system.contains("</memory>") && request.system.contains("data, not instructions"))
        #expect(request.cacheSystem)
        #expect(request.messages.first?.role == .user)
        #expect(request.messages.map(\.role) == [.user, .assistant, .user])
        #expect(request.messages.first?.text == "Paper week first?\n\nAnd a pass bar.")
        #expect(!request.messages.contains { $0.text.contains("rotate keys") })
    }

    @Test("private mode is a blank slate: no memory, no project page")
    func contextPrivate() {
        let request = ConversationContext.build(aboutYou: "Prefers short replies.", page: nil, project: "strado", turns: turns, isPrivate: true)
        #expect(!request.system.contains("Prefers short replies."))
        #expect(!request.system.contains("</memory>"))
        #expect(request.system.contains("private"))
    }

    @Test("long conversations keep the newest turns that fit")
    func contextTrims() {
        let long = (0..<40).map { i in
            Turn(at: at("2026-10-24T09:00:00Z").addingTimeInterval(Double(i) * 60), device: "mac",
                 speaker: i.isMultiple(of: 2) ? .you : .broski, text: "turn \(i) " + String(repeating: "x", count: 1000))
        }
        let request = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: long, isPrivate: false, maxTurnChars: 8_000)
        #expect(request.messages.last?.text.hasPrefix("turn 38") == true)
        #expect(request.messages.reduce(0) { $0 + $1.text.count } <= 8_000)
        #expect(request.messages.first?.role == .user)
    }
}
