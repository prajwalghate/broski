import Foundation
import Testing
@testable import BroskiCore

/// Phase 2: Broski brings back what you said before, keeps decisions with their dates, and files a stretch of
/// conversation under its project.
@Suite("Remembering: recall, decisions, review")
struct RememberingTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-remember-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let iso = ISO8601DateFormatter()
    private func at(_ s: String) -> Date { iso.date(from: s)! }

    // MARK: Recall

    @Test("past turns become searchable, and recall skips what's already in the conversation")
    func recallFromConversations() throws {
        let root = URL(fileURLWithPath: "/tmp/broski")
        let old = Turn(id: "t1", at: at("2026-10-20T10:00:00Z"), device: "mac", speaker: .you,
                       text: "Risk limits come before any live trade on strado: max 2% per position.", project: "strado")
        let recent = Turn(id: "t2", at: at("2026-10-24T10:00:00Z"), device: "mac", speaker: .you,
                          text: "Paper week first for strado, then live trade.", project: "strado")
        let unrelated = Turn(id: "t3", at: at("2026-10-21T10:00:00Z"), device: "mac", speaker: .broski,
                             text: "The onboarding kit needs ten questions for new projects.", project: "broski")
        let index = NotesIndex(Recall.refs(turns: [old, recent, unrelated], root: root))
        let hits = Recall.find("what did I decide about live trade risk on strado?", index: index, excluding: ["turn:t2"], hidden: [])
        #expect(hits.first?.id == "turn:t1")
        #expect(!hits.contains { $0.id == "turn:t2" })
        #expect(hits.first?.label.hasPrefix("You said") == true)
        #expect(Recall.find("live trade risk", index: index, excluding: [], hidden: ["strado"]).allSatisfy { $0.id == "turn:t3" })
    }

    @Test("cited numbers become sources, and the markers leave the text")
    func citations() {
        let hits = [RecallHit(id: "a", label: "Note · Oct 20 · Risk limits", text: "x"),
                    RecallHit(id: "b", label: "You said · Oct 22", text: "y"),
                    RecallHit(id: "c", label: "Decision · Oct 18", text: "z")]
        let (text, sources) = Recall.cited(in: "Risk limits come first [1], and you wanted a pass bar [2][1]. Not [9].", hits: hits)
        #expect(text == "Risk limits come first, and you wanted a pass bar. Not [9].")
        #expect(sources == ["Note · Oct 20 · Risk limits", "You said · Oct 22"])
    }

    // MARK: Decisions

    @Test("decisions are kept per device per project, and a newer one replaces an older one")
    func decisionLog() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Decision(id: "d1", at: at("2026-10-20T10:00:00Z"), device: "mac", project: "strado", text: "Start with $500 live")
        let second = Decision(id: "d2", at: at("2026-10-24T10:00:00Z"), device: "iphone", project: "strado",
                              text: "Paper-trade one week before real money", replaces: "d1")
        let other = Decision(id: "d3", at: at("2026-10-22T10:00:00Z"), device: "mac", project: "broski", text: "Conversation-first")
        try DecisionLog.record(first, root: root)
        try DecisionLog.record(second, root: root)
        try DecisionLog.record(other, root: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("projects/strado/decisions.iphone.jsonl").path))
        #expect(DecisionLog.all(root: root, project: "strado").map(\.id) == ["d1", "d2"])
        #expect(DecisionLog.current(root: root, project: "strado").map(\.text) == ["Paper-trade one week before real money"])
        #expect(DecisionLog.current(root: root, project: "broski").count == 1)
    }

    @Test("a reply's context carries the project's current decisions and numbered recall, fenced as data")
    func contextWithDecisionsAndRecall() {
        let decisions = [Decision(id: "d2", at: at("2026-10-24T10:00:00Z"), device: "mac", project: "strado", text: "Paper week first")]
        let recall = [RecallHit(id: "turn:t1", label: "You said · Oct 20", text: "Max 2% per position.")]
        let turn = Turn(device: "mac", speaker: .you, text: "What's next on strado?", project: "strado")
        let request = ConversationContext.build(aboutYou: nil, page: nil, project: "strado", turns: [turn], isPrivate: false,
                                                decisions: decisions, recall: recall)
        #expect(request.system.contains("<decisions>") && request.system.contains("Paper week first") && request.system.contains("</decisions>"))
        // Recall changes every turn, so it rides on the last message and the cached system prompt stays the same.
        #expect(!request.system.contains("</notes>"))
        let last = request.messages.last?.text ?? ""
        #expect(last.contains("<notes>") && last.contains("[1] You said · Oct 20") && last.contains("</notes>") && last.hasSuffix("What's next on strado?"))
        let blank = ConversationContext.build(aboutYou: nil, page: nil, project: "strado", turns: [turn], isPrivate: true,
                                              decisions: decisions, recall: recall)
        #expect(!blank.system.contains("Paper week first") && !(blank.messages.last?.text.contains("Max 2%") ?? true))
    }

    // MARK: Review after a reply

    @Test("the review names the project and topic even with nothing to save, and links a changed decision")
    func review() throws {
        let catalog = ProjectCatalog(projects: ["strado", "broski"].map { Project(name: $0) })
        let nothing = try #require(SaveCard.review(#"{"project":"Strado","topic":"launch plan","items":[]}"#, catalog: catalog))
        #expect(nothing.project == "strado" && nothing.topic == "launch plan" && nothing.card == nil)

        let current = [Decision(id: "d1", at: Date(), device: "mac", project: "strado", text: "Start with $500 live")]
        let changed = try #require(SaveCard.review(#"{"project":"strado","topic":"","items":[{"kind":"decision","title":"Paper-trade a week first","body":"","replaces":"Start with $500 live"}]}"#,
                                                   catalog: catalog, decisions: current))
        #expect(changed.topic == nil)
        #expect(changed.card?.items.first?.replaces == "d1")
        #expect(SaveCard.review(#"{"project":"moon","topic":"x","items":[]}"#, catalog: catalog)?.project == nil)
    }
}
