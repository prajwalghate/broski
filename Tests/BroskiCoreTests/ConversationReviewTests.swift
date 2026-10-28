import Foundation
import Testing
@testable import BroskiCore

/// "Save that", and the look after each reply, read the conversation on screen. In private mode that's the private
/// conversation, which lives only in memory: the review reads it alone, and nothing from it reaches the Broski folder.
@Suite("Conversation review")
struct ConversationReviewTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Records each review it's sent and answers with a fixed one: by default a project, a topic, a new project and a todo.
    final class FakeReviewer: ModelConnector, @unchecked Sendable {
        var sent: [ModelRequest] = []
        var answer = #"{"project":"strado","topic":"dentist visit","items":[{"kind":"todo","title":"Book the dentist","body":"","replaces":""}],"new_project":{"name":"Tooth Diary","summary":"A log of dentist visits","packs":["personal"],"goals":[],"questions":[]}}"#
        func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
            sent.append(request)
            return ModelReply(text: answer, truncated: false, usage: ModelUsage(input: 100, output: 20))
        }
    }

    private func gateway(root: URL, fake: FakeReviewer) -> ModelGateway {
        var gateway = ModelGateway(settings: .defaults, root: root, device: "mac", key: { _ in "test-key" })
        gateway.makeConnector = { _ in fake }
        return gateway
    }

    private let catalog = ProjectCatalog(projects: ["strado", "moonbase"].map { Project(name: $0) })
    private let stored = [Turn(device: "mac", speaker: .you, text: "Paper week before real money."),
                          Turn(device: "mac", speaker: .broski, text: "Agreed, with a pass bar.")]
    private let privateTurns = [Turn(device: "mac", speaker: .you, text: "I need to book the dentist about my cracked molar."),
                                Turn(device: "mac", speaker: .broski, text: "Thursday morning is free.")]

    private func review(isPrivate: Bool, privateTurns: [Turn]? = nil, project: String = "strado",
                        localOnly: Set<String> = []) -> ConversationReview {
        ConversationReview(stored: stored, privateTurns: privateTurns ?? self.privateTurns, isPrivate: isPrivate, project: project,
                           projects: ["strado"], decisions: [Decision(device: "mac", project: "strado", text: "Ship on Fridays")],
                           localOnly: localOnly, catalog: catalog)
    }

    /// Every file in the folder, as text.
    private func everythingWritten(_ root: URL) -> String {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    @Test("in private mode, a review reads only the private turns")
    func privateReadsPrivateTurns() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        let reviewed = try await review(isPrivate: true).run(gateway: gateway(root: root, fake: fake))
        let offer = try #require(reviewed)

        #expect(fake.sent.count == 1)
        let sent = fake.sent.map { $0.system + "\n" + $0.messages.map(\.text).joined(separator: "\n") }.joined()
        #expect(sent.contains("cracked molar"))
        #expect(!sent.contains("Paper week") && !sent.contains("pass bar"), "the stored conversation isn't reviewed")
        // Private mode is a blank slate: the review isn't told your projects or their decisions either.
        #expect(!sent.contains("strado") && !sent.contains("Ship on Fridays"))
        #expect(offer.card?.items.map(\.title) == ["Book the dentist"])
    }

    @Test("a private review writes nothing from the private turns to disk, and takes on no project or topic")
    func privateWritesNothing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        let reviewed = try await review(isPrivate: true).run(gateway: gateway(root: root, fake: fake))
        let offer = try #require(reviewed)

        // What a review takes on is kept: the project as a turn, the topic on every later turn, a new project as a folder.
        #expect(offer.project == nil && offer.topic == nil && offer.newProject == nil)
        // Its card files into the inbox; nothing is saved until you tap Save.
        #expect(offer.card?.project == nil)
        let written = everythingWritten(root)
        for word in ["molar", "dentist", "Thursday", "Tooth Diary", "strado"] {
            #expect(!written.contains(word), "\(word) reached the Broski folder")
        }
        #expect(ConversationStore(root: root, device: "mac").recent(10).isEmpty)
        // What it cost is still counted.
        #expect(UsageLog.entries(root: root).map(\.task) == ["review"])
    }

    @Test("nothing said in private mode yet: no review, however much the stored conversation holds")
    func privateWithNothingSaid() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        let offer = try await review(isPrivate: true, privateTurns: []).run(gateway: gateway(root: root, fake: fake))
        #expect(offer == nil)
        #expect(fake.sent.isEmpty)
    }

    @Test("a private conversation about a local-only project is never reviewed by a cloud model")
    func privateLocalOnly() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        let secret = [Turn(device: "mac", speaker: .you, text: "The moonbase demo slipped again.")]
        await #expect(throws: ModelRouter.Refusal.noLocalModel(.fast)) {
            _ = try await review(isPrivate: true, privateTurns: secret, localOnly: ["moonbase"]).run(gateway: gateway(root: root, fake: fake))
        }
        #expect(fake.sent.isEmpty)
    }

    @Test("a private conversation while a local-only project is picked is never reviewed by a cloud model")
    func privateWhileLocalOnlyPicked() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        await #expect(throws: ModelRouter.Refusal.noLocalModel(.fast)) {
            _ = try await review(isPrivate: true, project: "moonbase", localOnly: ["moonbase"]).run(gateway: gateway(root: root, fake: fake))
        }
        #expect(fake.sent.isEmpty)
    }

    @Test("a review that comes back after you let a private conversation go isn't offered in the next one")
    func staleReview() {
        let next = [Turn(device: "mac", speaker: .you, text: "Something else entirely.")]
        let reviewed = review(isPrivate: true)
        #expect(reviewed.isCurrent(isPrivate: true, privateTurns: privateTurns), "the same private conversation")
        #expect(reviewed.isCurrent(isPrivate: true, privateTurns: privateTurns + next), "the same one, carried on")
        #expect(!reviewed.isCurrent(isPrivate: false, privateTurns: []), "private mode left")
        #expect(!reviewed.isCurrent(isPrivate: true, privateTurns: next), "let go and started again")
        #expect(!reviewed.isCurrent(isPrivate: true, privateTurns: []), "let go and started again, nothing said yet")

        let stored = review(isPrivate: false)
        #expect(stored.isCurrent(isPrivate: false, privateTurns: []))
        #expect(!stored.isCurrent(isPrivate: true, privateTurns: []), "private mode went on")
    }

    @Test("outside private mode, a review reads the stored conversation and takes on its project and topic")
    func storedConversation() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        let reviewed = try await review(isPrivate: false).run(gateway: gateway(root: root, fake: fake))
        let offer = try #require(reviewed)

        let sent = fake.sent.map { $0.system + "\n" + $0.messages.map(\.text).joined(separator: "\n") }.joined()
        #expect(sent.contains("Paper week") && sent.contains("Ship on Fridays"))
        #expect(!sent.contains("cracked molar"))
        #expect(offer.project == "strado" && offer.topic == "dentist visit" && offer.newProject?.name == "Tooth Diary")
        #expect(offer.card?.project == "strado")
        #expect(UsageLog.entries(root: root).map(\.project) == ["strado"])
    }

    @Test("a card the review files under no project goes to the conversation's project")
    func cardFallsBackToProject() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeReviewer()
        fake.answer = #"{"project":"","topic":"","items":[{"kind":"todo","title":"Write the stop-loss guard","body":"","replaces":""}],"new_project":{"name":"","summary":"","packs":[],"goals":[],"questions":[]}}"#
        let reviewed = try await review(isPrivate: false).run(gateway: gateway(root: root, fake: fake))
        let offer = try #require(reviewed)
        #expect(offer.project == nil && offer.card?.project == "strado")
    }
}
