import Foundation
import Testing
@testable import BroskiCore

/// Automations: rules over the change stream that tell you, or post to a webhook you saved, when something changes.
@Suite("Automations")
struct AutomationsTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-auto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-25T10:00:00Z")!

    private func event(_ project: String, _ kind: String, _ title: String, at offset: TimeInterval = 0) -> ChangeEvent {
        ChangeEvent(at: now.addingTimeInterval(offset), project: project, source: "broski", kind: kind, id: "\(project):x/\(title)", title: title)
    }

    @Test("a rule matches by project, kind and words in the title; empty means any")
    func matching() {
        let rule = AutomationRule(name: "Risk decisions", projects: ["strado"], kinds: ["decided"], words: ["risk", "limit"], notify: true)
        #expect(Automations.matches(rule, event("strado", "decided", "Raise the Risk cap")))
        #expect(!Automations.matches(rule, event("strado", "decided", "Paper-trade a week")))
        #expect(!Automations.matches(rule, event("broski", "decided", "Risk")))
        #expect(!Automations.matches(rule, event("strado", "closed", "risk")))
        var any = AutomationRule(name: "Everything", notify: true)
        #expect(Automations.matches(any, event("broski", "reopened", "anything")))
        any.enabled = false
        #expect(!Automations.matches(any, event("broski", "reopened", "anything")))
    }

    @Test("actions: one per matching rule and event; a local-only project is never posted to a webhook")
    func actions() {
        let rules = [AutomationRule(name: "Tell me", kinds: ["decided"], notify: true, webhook: "team"),
                     AutomationRule(name: "Post only", kinds: ["reopened"], notify: false, webhook: "team")]
        let events = [event("strado", "decided", "A"), event("secret", "decided", "B"), event("secret", "reopened", "C")]
        let actions = Automations.actions(for: events, rules: rules, localOnly: ["secret"])
        #expect(actions.count == 2)
        #expect(actions[0].event.title == "A" && actions[0].notify && actions[0].webhook == "team")
        #expect(actions[1].event.title == "B" && actions[1].notify && actions[1].webhook == nil)
    }

    @Test("rules are kept in automations.json; the cursor starts now, so history never fires")
    func storage() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Automations.load(root: root).isEmpty)
        let rule = AutomationRule(name: "Decisions", kinds: ["decided"], notify: true)
        try Automations.save([rule], root: root)
        #expect(Automations.load(root: root) == [rule])

        try ChangeStream.append([event("strado", "decided", "Old", at: -60)], root: root, project: "strado")
        #expect(Automations.pending(root: root, now: now).isEmpty, "the first look sets the cursor and fires nothing")
        try ChangeStream.append([event("strado", "decided", "New", at: 30)], root: root, project: "strado")
        let pending = Automations.pending(root: root, now: now.addingTimeInterval(60))
        #expect(pending.map(\.title) == ["New"])
        #expect(Automations.pending(root: root, now: now.addingTimeInterval(120)).isEmpty, "each event fires once")
    }

    @Test("a webhook gets one line Slack and Discord both read")
    func payload() throws {
        let body = Automations.payload(event("strado", "decided", "Paper-trade a week first"))
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(object["text"] == "strado · decided: Paper-trade a week first")
        #expect(object["content"] == object["text"])
    }
}
