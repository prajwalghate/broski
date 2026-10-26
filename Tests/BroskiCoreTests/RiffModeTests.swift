import Foundation
import Testing
@testable import BroskiCore

/// Riff mode inside the conversation: brainstorming on the deep model, with standing rules you set by just saying
/// them, no save cards while you think, and a wrap-up card at the end.
@Suite("Riff mode")
struct RiffModeTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-riff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let day = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z")!

    @Test("starting, ending and setting rules by saying so; only whole requests count")
    func commands() {
        #expect(ConversationCommand.parse("let's riff", catalog: nil) == .startRiff(nil))
        #expect(ConversationCommand.parse("Let's riff about pricing for the bot.", catalog: nil) == .startRiff("pricing for the bot"))
        #expect(ConversationCommand.parse("riff mode", catalog: nil) == .startRiff(nil))
        #expect(ConversationCommand.parse("start a riff on onboarding", catalog: nil) == .startRiff("onboarding"))
        #expect(ConversationCommand.parse("end riff", catalog: nil) == .endRiff)
        #expect(ConversationCommand.parse("wrap up", catalog: nil) == nil, "only ends a riff while riffing")
        #expect(ConversationCommand.parse("wrap it up", catalog: nil, riffing: true) == .endRiff)
        #expect(ConversationCommand.parse("rule: no code talk", catalog: nil) == .riffRule("no code talk"))
        #expect(ConversationCommand.parse("New rule: push back harder.", catalog: nil) == .riffRule("push back harder"))
        #expect(ConversationCommand.parse("drop the rule about code", catalog: nil) == .dropRiffRule("code"))
        #expect(ConversationCommand.parse("clear my riff rules", catalog: nil) == .dropRiffRule(""))
        #expect(ConversationCommand.parse("should we riff on this later?", catalog: nil) == nil)
        #expect(ConversationCommand.parse("what's the rule for naming?", catalog: nil) == nil)
    }

    @Test("your rules are kept for every riff, per device, and can be dropped")
    func rules() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RiffMode.rules(root: root).isEmpty)
        try RiffMode.addRule("No code talk", root: root, device: "mac", at: day)
        try RiffMode.addRule("Push back harder", root: root, device: "iphone", at: day.addingTimeInterval(60))
        try RiffMode.addRule("no code talk", root: root, device: "mac", at: day.addingTimeInterval(120))
        #expect(RiffMode.rules(root: root) == ["No code talk", "Push back harder"], "both devices, once each")
        #expect(try RiffMode.dropRule("code", root: root, device: "mac", at: day.addingTimeInterval(180)))
        #expect(RiffMode.rules(root: root) == ["Push back harder"])
        #expect(try !RiffMode.dropRule("nothing like this", root: root, device: "mac", at: day.addingTimeInterval(190)))
        #expect(try RiffMode.dropRule("", root: root, device: "mac", at: day.addingTimeInterval(200)))
        #expect(RiffMode.rules(root: root).isEmpty, "an empty phrase clears them all")
        #expect(throws: RiffMode.Failure.tooLong) { try RiffMode.addRule(String(repeating: "x", count: 300), root: root, device: "mac") }
    }

    @Test("while riffing, Broski is told to brainstorm by the rules, yours included; otherwise it isn't")
    func context() {
        let turns = [Turn(device: "mac", speaker: .you, text: "Pricing ideas?", mode: "riff")]
        let riffing = ConversationContext.build(aboutYou: nil, page: nil, project: "strado", turns: turns, isPrivate: false,
                                                riff: ["No code talk"])
        #expect(riffing.system.contains("riff mode") && riffing.system.contains(RiffMode.baseRules[0]))
        #expect(riffing.system.contains("- No code talk"))
        let talking = ConversationContext.build(aboutYou: nil, page: nil, project: "strado", turns: turns, isPrivate: false)
        #expect(!talking.system.contains("riff mode"))
    }

    @Test("the riff brief: proactive, fact-driven without inventing anything, ambitious, honest; and a toolkit of moves")
    func brief() {
        let system = RiffMode.system(rules: [])
        #expect(system.contains("Don't wait to be asked"))
        #expect(system.contains("never invent"))
        #expect(system.contains("10x"))
        #expect(system.contains("dark patterns"))
        #expect(system.contains("never announce"), "moves are used the way a person would, not named like a menu")
        #expect(!RiffMode.moves.isEmpty && Set(RiffMode.moves.map(\.name)).count == RiffMode.moves.count)
        #expect(RiffMode.moves.allSatisfy { !$0.ask.isEmpty && system.contains($0.name.lowercased()) }, "Broski knows every move it can pull in")
        #expect(RiffMode.moves.contains { $0.name == "Pre-mortem" } && RiffMode.moves.contains { $0.name == "Ethics check" })
    }

    @Test("a riff is on from its start marker until its end marker, across restarts")
    func active() {
        var turns = [Turn(device: "mac", speaker: .you, text: "hi")]
        #expect(!RiffMode.active(turns: turns))
        turns.append(RiffMode.startTurn(device: "mac", project: "strado", about: "pricing"))
        turns.append(Turn(device: "mac", speaker: .you, text: "Flat price?", mode: "riff"))
        #expect(RiffMode.active(turns: turns) && turns[1].text == "Riff about pricing")
        turns.append(RiffMode.endTurn(device: "mac", project: "strado"))
        #expect(!RiffMode.active(turns: turns))
    }

    @Test("the wrap-up reads the riff and becomes one save card: the summary as a note, then ideas, decisions, todos, questions")
    func wrapUp() throws {
        let turns = [Turn(device: "mac", speaker: .you, text: "Before the riff"),
                     RiffMode.startTurn(device: "mac", project: "strado", about: nil),
                     Turn(device: "mac", speaker: .you, text: "Flat price or usage?", mode: "riff"),
                     Turn(device: "mac", speaker: .broski, text: "Usage, with a cap.", mode: "riff")]
        let request = try #require(RiffMode.wrapRequest(turns: turns))
        let text = request.messages.map(\.text).joined()
        #expect(text.contains("Me: Flat price or usage?") && text.contains("Broski: Usage, with a cap.") && !text.contains("Before the riff"))
        #expect(request.schemaJSON != nil)
        let json = #"{"title":"Pricing riff","summary":"Going with usage pricing, capped.","ideas":["Free tier for students"],"decisions":["Usage pricing with a cap"],"todos":["Model the cap"],"questions":["What cap?"]}"#
        let card = try #require(RiffMode.card(from: json, project: "strado"))
        #expect(card.project == "strado")
        #expect(card.items.map(\.kind) == [.note, .idea, .decision, .todo, .note])
        #expect(card.items[0].title == "Pricing riff" && card.items[0].body == "Going with usage pricing, capped.")
        #expect(card.items[4].title == "Open question: What cap?")
        #expect(RiffMode.card(from: "nope", project: nil) == nil)
        let many = #"{"title":"t","summary":"s","ideas":["1","2","3","4","5","6","7","8"],"decisions":[],"todos":[],"questions":["a","b","c","d"]}"#
        #expect(RiffMode.card(from: many, project: nil)?.items.count == 1 + 4 + 2, "short enough to scan")
        #expect(RiffMode.wrapRequest(turns: [Turn(device: "mac", speaker: .you, text: "no riff here")]) == nil)
    }

    @Test("turns from before riff mode still read; a riff turn round-trips")
    func turnFormat() throws {
        let old = #"{"v":1,"id":"a","at":"2026-10-24T10:00:00.000Z","device":"mac","speaker":"you","text":"hi"}"#
        let decoded = try JSONLines.decoder.decode(Turn.self, from: Data(old.utf8))
        #expect(decoded.mode == nil)
        let riff = Turn(at: day, device: "mac", speaker: .you, text: "idea", mode: "riff")
        let again = try JSONLines.decoder.decode(Turn.self, from: JSONLines.encoder.encode(riff))
        #expect(again == riff)
    }
}

@Suite("Language")
struct LanguageTests {
    @Test("Broski always replies in English, even when you talk in Hinglish or Marathi, in conversation and riffs alike")
    func english() {
        #expect(ConversationContext.persona.contains("Always reply in English"))
        let turns = [Turn(device: "mac", speaker: .you, text: "Yaar, kaise start karein?", mode: "riff")]
        let riff = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: turns, isPrivate: false, riff: [])
        let privately = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: turns, isPrivate: true)
        #expect(riff.system.contains("Always reply in English") && privately.system.contains("Always reply in English"))
    }
}
