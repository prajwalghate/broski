import Foundation
import Testing
@testable import BroskiCore

@Suite("The conversation panel")
struct PanelTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: What a reply used

    @Test("a reply says what it was given to work from, in one line")
    func usedSummary() throws {
        let used = try #require(ReplyContext(aboutYou: true, page: "recipe-box", decisions: 2,
                                             recalled: ["Note · Oct 28 · Sync drops edits", "You said · Oct 27", "Decision · Oct 20"]))
        #expect(used.summary == "Used what I know about you, the recipe-box page, 2 decisions and 3 from earlier")
        #expect(used.lines == ["What Broski knows about you", "The recipe-box page", "2 current decisions",
                               "Note · Oct 28 · Sync drops edits", "You said · Oct 27", "Decision · Oct 20"])
        #expect(ReplyContext(aboutYou: false, page: nil, decisions: 1, recalled: [])?.summary == "Used 1 decision")
        #expect(ReplyContext(aboutYou: true, page: nil, decisions: 0, recalled: ["You said · Oct 27"])?.summary
                == "Used what I know about you and 1 from earlier")
    }

    @Test("a reply that used nothing, or a private one, records nothing")
    func usedNothing() {
        #expect(ReplyContext(aboutYou: false, page: nil, decisions: 0, recalled: []) == nil)
        #expect(ReplyContext(aboutYou: true, page: "recipe-box", decisions: 2, recalled: ["Decision · Oct 20"], isPrivate: true) == nil,
                "private mode reads no memory, so a private reply never claims it did")
    }

    @Test("a reply never claims more than the model was sent")
    func usedMatchesThePrompt() throws {
        let decisions = (0..<15).map { Decision(at: Date(timeIntervalSince1970: Double($0) * 60), device: "mac",
                                                 project: "recipe-box", text: "Decision \($0)") }
        let recall = [RecallHit(id: "turn:1", label: "You said · Oct 27", text: "Sync drops edits")]
        let used = try #require(ConversationContext.used(aboutYou: "  \n ", page: nil, project: "recipe-box",
                                                         decisions: decisions, recall: recall, isPrivate: false))
        #expect(used.decisions == ConversationContext.decisionLimit && ConversationContext.decisionLimit == 12,
                "the prompt carries the last 12 decisions, so the line says 12")
        #expect(used.aboutYou == nil, "blank memory isn't sent, so it isn't claimed")
        #expect(used.recalled == ["You said · Oct 27"])
        let request = ConversationContext.build(aboutYou: nil, page: nil, project: "recipe-box", turns: [], isPrivate: false,
                                                decisions: decisions)
        #expect(request.system.components(separatedBy: ": Decision ").count - 1 == ConversationContext.decisionLimit)
        #expect(ConversationContext.used(aboutYou: "Likes short answers", page: nil, project: "recipe-box",
                                         decisions: decisions, recall: recall, isPrivate: true) == nil)
    }

    @Test("what a reply used is kept with it, and older turns without it still read")
    func usedRoundTrip() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(root: root, device: "mac")
        let at = Date(timeIntervalSince1970: 1_793_000_000)
        let used = ReplyContext(aboutYou: true, page: "recipe-box", decisions: 1, recalled: ["Decision · Oct 20"])
        try store.append(Turn(at: at, device: "mac", speaker: .broski, text: "Launch solo.", project: "recipe-box", used: used))
        #expect(store.turns(on: at).first?.used == used)

        let old = #"{"v":1,"id":"t1","at":"2026-10-24T09:00:00Z","device":"mac","speaker":"broski","text":"Hi","model":"m"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let turn = try decoder.decode(Turn.self, from: Data(old.utf8))
        #expect(turn.used == nil && turn.text == "Hi")
        let line = String(decoding: try JSONEncoder().encode(Turn(device: "mac", speaker: .you, text: "x")), as: UTF8.self)
        #expect(!line.contains("used"), "a turn that used nothing doesn't write the field")
    }

    // MARK: Save receipts

    @Test("saving a card says where it went, and points at the files it wrote")
    func saveReceipt() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let card = SaveCard(project: "recipe-box", items: [.init(kind: .todo, title: "Log sync errors for a week"),
                                                            .init(kind: .decision, title: "Launch v1 solo")])
        let receipt = try SaveCard.keep(card, store: ItemStore(root: root), root: root, device: "mac", turn: nil)
        #expect(receipt.line == "Saved to recipe-box: 1 decision, 1 todo")
        #expect(receipt.files.count == 2)
        for file in receipt.files {
            #expect(!file.hasPrefix("/"), "paths inside the Broski folder, so they work on every device")
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path), "\(file)")
        }
        #expect(receipt.files.first?.hasPrefix("projects/recipe-box/") == true && receipt.files.first?.hasSuffix(".md") == true,
                "the first file is the note you'd want to see")
    }

    // MARK: Project colours

    @Test("a project keeps its colour on every device")
    func projectColour() {
        #expect(ProjectColor.index(for: "recipe-box") == 5)
        #expect(ProjectColor.index(for: "Recipe-Box") == ProjectColor.index(for: "recipe-box"))
        let names = ["recipe-box", "garden", "strado", "alpha", "beta", "gamma", "delta", "notes"]
        #expect(Set(names.map(ProjectColor.index(for:))).count >= 4, "projects spread across the palette")
        #expect(names.allSatisfy { (0..<ProjectColor.count).contains(ProjectColor.index(for: $0)) })
    }

    // MARK: Broski's own lines

    @Test("an empty conversation greets you for the time of day")
    func greeting() {
        #expect(BroskiLines.greeting(hour: 8) == "Morning. What are we working on?")
        #expect(BroskiLines.greeting(hour: 14) == "Afternoon. What's on your mind?")
        #expect(BroskiLines.greeting(hour: 19) == "Evening. Want to think something through?")
        #expect(BroskiLines.greeting(hour: 2) == "Up late. What are we thinking about?")
    }

    @Test("while it thinks, Broski's line changes from reply to reply, and stays plain")
    func thinkingLines() {
        #expect(BroskiLines.thinking(replies: 0, deep: true) == "Thinking harder…")
        let lines = (0..<8).map { BroskiLines.thinking(replies: $0, deep: false) }
        #expect(Set(lines).count > 1)
        #expect(lines.first == "Thinking…")
        let everything = lines + (0..<24).map { BroskiLines.greeting(hour: $0) }
        #expect(everything.allSatisfy { !$0.contains("!") }, "no exclamation marks")
    }

    // MARK: The command palette

    private func state(projects: [String] = ["recipe-box", "garden"], current: String? = "garden", isPrivate: Bool = false,
                       riffing: Bool = false, deep: Bool = false) -> Palette.State {
        Palette.State(projects: projects, current: current, isPrivate: isPrivate, riffing: riffing, deep: deep)
    }

    @Test("the palette offers what you can do now")
    func paletteItems() {
        let titles = Palette.items(state()).map(\.title)
        #expect(titles.contains("Start a riff") && titles.contains("Go private") && titles.contains("Think harder"))
        #expect(titles.contains("Switch to recipe-box") && !titles.contains("Switch to garden"), "not the project you're on")
        #expect(titles.contains("No project"))
        let riffing = Palette.items(state(isPrivate: true, riffing: true, deep: true)).map(\.title)
        #expect(riffing.contains("Wrap up the riff") && !riffing.contains("Start a riff"))
        #expect(riffing.contains("Leave private mode") && riffing.contains("Back to everyday"))
        #expect(!Palette.items(state(current: nil)).map(\.title).contains("No project"))
    }

    @Test("typing finds the command: the best match first, every word must match")
    func paletteSearch() {
        let items = Palette.items(state())
        #expect(Palette.search("rif", in: items).first?.title == "Start a riff")
        #expect(Palette.search("dash", in: items).first?.title == "Open the dashboard")
        #expect(Palette.search("rec", in: items).first?.action == .project("recipe-box"))
        #expect(Palette.search("privat", in: items).first?.action == .togglePrivate)
        #expect(Palette.search("models", in: items).first?.action == .settings("models"))
        #expect(Palette.search("switch garden", in: items).isEmpty, "the project you're on isn't offered")
        #expect(Palette.search("zzz", in: items).isEmpty)
        #expect(Palette.search("  ", in: items) == items)
    }
}
