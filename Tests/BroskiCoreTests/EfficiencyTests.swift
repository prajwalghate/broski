import Foundation
import Testing
@testable import BroskiCore

/// Spending well: every model call is logged with the task it did, project pages aren't rewritten on every tracker
/// push, and nothing runs on a pricier model by accident.
@Suite("Cost efficiency")
struct EfficiencyTests {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-cost-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a page Claude never wrote is due; after that, notes changes wait 6 hours and tracker-only changes a day")
    func pageRewrites() {
        #expect(ProjectPage.rewriteDue(compiled: nil, notesChanged: false, now: now))
        #expect(!ProjectPage.rewriteDue(compiled: now.addingTimeInterval(-5 * 3600), notesChanged: true, now: now))
        #expect(ProjectPage.rewriteDue(compiled: now.addingTimeInterval(-7 * 3600), notesChanged: true, now: now))
        #expect(!ProjectPage.rewriteDue(compiled: now.addingTimeInterval(-23 * 3600), notesChanged: false, now: now))
        #expect(ProjectPage.rewriteDue(compiled: now.addingTimeInterval(-25 * 3600), notesChanged: false, now: now))
    }

    @Test("usage lines say what task they were for; lines from before still read")
    func taskInLog() throws {
        let old = #"{"v":1,"at":"2026-10-24T10:00:00.000Z","device":"mac","role":"fast","provider":"claude","model":"claude-haiku-5-5","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0},"usd":0.0}"#
        let decoded = try JSONLines.decoder.decode(UsageLog.Entry.self, from: Data(old.utf8))
        #expect(decoded.task == nil)
        let entry = UsageLog.Entry(at: now, device: "mac", role: .everyday, provider: "claude", model: ClaudeModel.brain, project: nil,
                                   usage: ModelUsage(input: 1000, output: 100), task: "page")
        let again = try JSONLines.decoder.decode(UsageLog.Entry.self, from: JSONLines.encoder.encode(entry))
        #expect(again == entry && again.task == "page")
    }

    @Test("this month's spend by task, most first; untagged lines count as other")
    func byTask() {
        let big = ModelUsage(input: 1_000_000, output: 0)
        let entries = [
            UsageLog.Entry(at: now, device: "mac", role: .everyday, provider: "claude", model: ClaudeModel.brain, project: nil, usage: big, task: "page"),
            UsageLog.Entry(at: now, device: "mac", role: .everyday, provider: "claude", model: ClaudeModel.brain, project: nil, usage: big, task: "page"),
            UsageLog.Entry(at: now, device: "iphone", role: .deep, provider: "claude", model: ClaudeModel.deep, project: nil, usage: big, task: "riff"),
            UsageLog.Entry(at: now, device: "mac", role: .fast, provider: "claude", model: ClaudeModel.fast, project: nil, usage: big),
        ]
        let summary = UsageLog.summary(entries, now: now)
        #expect(summary.byTask.map(\.task) == ["page", "riff", "other"])
        #expect(summary.byTask.first?.calls == 2 && summary.byTask.first?.usd == 4)
    }

    @Test("the gateway logs the task it was given")
    func gatewayTask() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var gateway = ModelGateway(settings: .defaults, root: root, device: "mac", key: { _ in "test-key" })
        gateway.makeConnector = { _ in FixedConnector() }
        _ = try await gateway.send(ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "hi")]), role: .fast,
                                   project: nil, task: "review")
        #expect(UsageLog.entries(root: root).map(\.task) == ["review"])
    }

    @Test("a Claude reply says what it used, cache included, for the log")
    func claudeUsage() throws {
        let body = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":1200,"output_tokens":300,"cache_read_input_tokens":800,"cache_creation_input_tokens":50}}"#
        #expect(try AnthropicConnector.parse(Data(body.utf8), status: 200).usage == ModelUsage(input: 1200, output: 300, cacheRead: 800, cacheWrite: 50))
        #expect(UsageLog.role(forModel: ClaudeModel.fast) == .fast && UsageLog.role(forModel: ClaudeModel.deep) == .deep)
        #expect(UsageLog.role(forModel: "qwen2.5:7b") == .everyday)
    }
}

/// Answers every request with fixed usage.
private struct FixedConnector: ModelConnector {
    func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
        ModelReply(text: "ok", truncated: false, usage: ModelUsage(input: 1000, output: 100))
    }
}

/// Caching the conversation: everything up to Broski's previous reply is the same on the next turn, so it's marked
/// for the cache and read back at a fraction of the price; trimming a long conversation moves in steps so that start
/// stays put.
@Suite("Conversation caching")
struct ConversationCachingTests {
    private func turns(_ count: Int, size: Int = 1000) -> [Turn] {
        (0..<count).map { i in
            Turn(at: Date(timeIntervalSince1970: Double(i) * 60), device: "mac", speaker: i % 2 == 0 ? .you : .broski,
                 text: "turn \(i) " + String(repeating: "x", count: size))
        }
    }

    @Test("the marker goes on the last block of Broski's previous reply, not on the new message")
    func marker() throws {
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "a"), ModelMessage(role: .assistant, text: "b"),
                                                           ModelMessage(role: .user, text: "c")], cacheSystem: true, cacheHistory: true)
        let body = AnthropicConnector.body(for: request, model: ClaudeModel.brain)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let blocks = messages.map { ($0["content"] as? [[String: Any]]) ?? [] }
        #expect(blocks[1].last?["cache_control"] != nil)
        #expect(blocks[0].last?["cache_control"] == nil && blocks[2].last?["cache_control"] == nil)
        let first = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "a")], cacheHistory: true)
        let none = try #require(AnthropicConnector.body(for: first, model: ClaudeModel.brain)["messages"] as? [[String: Any]])
        #expect(((none[0]["content"] as? [[String: Any]])?.last?["cache_control"]) == nil, "nothing before the new message yet")
    }

    @Test("the conversation asks for history caching, except in private mode")
    func context() {
        let some = turns(4, size: 10)
        #expect(ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: some, isPrivate: false).cacheHistory)
        #expect(!ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: some, isPrivate: true).cacheHistory)
    }

    @Test("a long conversation is trimmed in steps, so its first message stays the same for several turns in a row")
    func steps() {
        let all = turns(60)
        var firsts: [String] = []
        for n in 31...46 where n % 2 == 1 {
            let request = ConversationContext.build(aboutYou: nil, page: nil, project: nil, turns: Array(all[0..<n]), isPrivate: false)
            #expect(request.messages.map(\.text).joined().count <= 24_100 + 2_000, "still within the budget")
            firsts.append(request.messages.first?.text ?? "")
        }
        #expect(Set(firsts).count <= 3, "the start moved in steps, not every turn")
        #expect(firsts.allSatisfy { $0.hasPrefix("turn ") })
    }
}
