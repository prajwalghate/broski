import Foundation
import Testing
@testable import BroskiCore

/// Every model call goes through one gateway, and what Broski remembers about you is yours to add to and take back.
@Suite("Gateway and memory")
struct GatewayAndMemoryTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-gw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Records what it was sent and answers with fixed usage.
    final class FakeConnector: ModelConnector, @unchecked Sendable {
        var sent: [(ModelRequest, String)] = []
        func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
            sent.append((request, model))
            return ModelReply(text: "ok", truncated: false, usage: ModelUsage(input: 1000, output: 100))
        }
    }

    private func gateway(root: URL, fake: FakeConnector, settings: ModelSettings = .defaults) -> ModelGateway {
        var gateway = ModelGateway(settings: settings, root: root, device: "mac", key: { _ in "test-key" })
        gateway.makeConnector = { _ in fake }
        return gateway
    }

    @Test("secrets are masked, the role's model is used, and the cost is logged")
    func sendMasksRoutesAndLogs() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeConnector()
        let key = "sk-" + "ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "my key is \(key)")])
        let result = try await gateway(root: root, fake: fake).send(request, role: .deep, project: "strado")
        #expect(result.route.model == "claude-opus-5-5")
        #expect(fake.sent.count == 1 && !fake.sent[0].0.messages[0].text.contains(key))
        let logged = UsageLog.entries(root: root)
        #expect(logged.count == 1 && logged[0].project == "strado" && logged[0].role == .deep && logged[0].usd > 0)
    }

    @Test("a local-only conversation is refused before anything is sent")
    func localOnlyRefusedEarly() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeConnector()
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "hi")])
        await #expect(throws: ModelRouter.Refusal.noLocalModel(.everyday)) {
            _ = try await gateway(root: root, fake: fake).send(request, role: .everyday, project: "secret", localOnly: true)
        }
        #expect(fake.sent.isEmpty && UsageLog.entries(root: root).isEmpty)
    }

    @Test("a fact already remembered is kept once, even when two devices remember it")
    func rememberedOnce() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try Memory.remember("Prefers short answers", root: root, device: "mac")
        try Memory.remember("prefers short answers ", root: root, device: "mac")
        // Each device writes only its own file, so the iPhone can't see the Mac's copy before it writes.
        try Memory.remember("Prefers short answers", root: root, device: "iphone")
        try Memory.remember("Works late on Fridays", root: root, device: "iphone")
        #expect(Memory.remembered(root: root) == ["Prefers short answers", "Works late on Fridays"])
        #expect(try Memory.forget("short answers", root: root, device: "mac"))
        #expect(Memory.remembered(root: root) == ["Works late on Fridays"])
    }

    @Test("a PDF goes as text to a model that can't read PDFs")
    func pdfAsText() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeConnector()
        var settings = ModelSettings.defaults
        settings.providers.append(ModelProvider(id: "ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", local: true))
        settings.localRoles = [.everyday: ModelChoice(provider: "ollama", model: "qwen3.5:4b")]
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, parts: [.text("read this"), .pdf(Data("not a real pdf".utf8))])])
        _ = try await gateway(root: root, fake: fake, settings: settings).send(request, role: .everyday, project: nil, localOnly: true)
        let parts = fake.sent[0].0.messages[0].parts
        #expect(!parts.contains { if case .pdf = $0 { return true } else { return false } })
        #expect(parts.count == 2)
    }

    @Test("remember and forget, per device, into what Broski knows about you")
    func memory() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(Memory.aboutYou(root: root) == nil)
        try Memory.remember("Prefers short replies", root: root, device: "mac")
        try Memory.remember("Builds on an 8 GB Mac", root: root, device: "iphone")
        var known = try #require(Memory.aboutYou(root: root))
        #expect(known.contains("Prefers short replies") && known.contains("Builds on an 8 GB Mac"))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory/remembered.mac.jsonl").path))

        #expect(try Memory.forget("8 gb", root: root, device: "mac"))
        known = try #require(Memory.aboutYou(root: root))
        #expect(!known.contains("8 GB") && known.contains("Prefers short replies"))
        #expect(try Memory.forget("", root: root, device: "mac"))
        #expect(Memory.aboutYou(root: root) == nil)
        #expect(try !Memory.forget("never said this", root: root, device: "mac"))

        try "# About you\n\nWorks in Swift.\n".write(to: root.appendingPathComponent("memory/about-you.md"), atomically: true, encoding: .utf8)
        #expect(Memory.aboutYou(root: root)?.contains("Works in Swift.") == true)
    }
}
