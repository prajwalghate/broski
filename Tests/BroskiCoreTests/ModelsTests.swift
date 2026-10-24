import Foundation
import Testing
@testable import BroskiCore

/// Code asks for a role; the router picks a model allowed for this conversation; every call is masked, priced and logged.
@Suite("Models: roles, router, connectors, usage, secrets")
struct ModelsTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var withOllama: ModelSettings {
        var settings = ModelSettings.defaults
        settings.providers.append(ModelProvider(id: "ollama", kind: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", local: true))
        settings.localRoles = [.fast: ModelChoice(provider: "ollama", model: "gemma4:e2b"),
                               .everyday: ModelChoice(provider: "ollama", model: "qwen3.5:4b")]
        return settings
    }

    // MARK: Router

    @Test("by default each role goes to its Claude model")
    func defaultsByRole() throws {
        let settings = ModelSettings.defaults
        #expect(try ModelRouter.route(.fast, settings: settings).model == "claude-haiku-5-5")
        #expect(try ModelRouter.route(.everyday, settings: settings).model == "claude-sonnet-5-5")
        #expect(try ModelRouter.route(.deep, settings: settings).model == "claude-opus-5-5")
        #expect(try ModelRouter.route(.everyday, settings: settings).provider.id == "claude")
    }

    @Test("a local-only conversation never reaches a cloud model")
    func localOnlyStaysLocal() throws {
        #expect(throws: ModelRouter.Refusal.noLocalModel(.everyday)) {
            try ModelRouter.route(.everyday, settings: ModelSettings.defaults, localOnly: true)
        }
        let route = try ModelRouter.route(.everyday, settings: withOllama, localOnly: true)
        #expect(route.provider.id == "ollama" && route.provider.local && route.model == "qwen3.5:4b")
        // Deep has no local model of its own: the best local one stands in, and says so.
        let deep = try ModelRouter.route(.deep, settings: withOllama, localOnly: true)
        #expect(deep.provider.local && deep.model == "qwen3.5:4b" && deep.substituted)
    }

    @Test("a cloud provider marked local, or a remote address, doesn't count as local")
    func remoteIsNotLocal() throws {
        var settings = withOllama
        settings.providers[settings.providers.count - 1].baseURL = "https://ollama.example.com/v1"
        #expect(throws: ModelRouter.Refusal.noLocalModel(.everyday)) {
            try ModelRouter.route(.everyday, settings: settings, localOnly: true)
        }
    }

    @Test("PDFs go as text to a model that can't read them; images need a model that can")
    func capabilities() throws {
        let claude = try ModelRouter.route(.everyday, settings: ModelSettings.defaults, needs: [.images, .pdfs])
        #expect(!claude.pdfAsText)
        let local = try ModelRouter.route(.everyday, settings: withOllama, localOnly: true, needs: [.pdfs])
        #expect(local.pdfAsText)
        #expect(throws: ModelRouter.Refusal.cantRead(.images)) {
            try ModelRouter.route(.everyday, settings: withOllama, localOnly: true, needs: [.images])
        }
    }

    @Test("past the daily limit deep work drops to the everyday model, and says so")
    func budget() throws {
        var settings = ModelSettings.defaults
        settings.dailyLimitUSD = 2
        #expect(try ModelRouter.route(.deep, settings: settings, spentToday: 1.99).model == "claude-opus-5-5")
        let over = try ModelRouter.route(.deep, settings: settings, spentToday: 2.01)
        #expect(over.model == "claude-sonnet-5-5" && over.overBudget)
        #expect(try ModelRouter.route(.fast, settings: settings, spentToday: 5).model == "claude-haiku-5-5")
    }

    // MARK: Prices and usage

    @Test("cost from the published prices")
    func prices() {
        let million = ModelUsage(input: 1_000_000, output: 1_000_000)
        #expect(UsageLog.cost(model: "claude-opus-5-5", usage: million) == 24)
        #expect(UsageLog.cost(model: "claude-sonnet-5-5", usage: million) == 12)
        // Haiku costs more once a prompt passes 100,000 tokens.
        #expect(abs(UsageLog.cost(model: "claude-haiku-5-5", usage: ModelUsage(input: 50_000, output: 1_000_000)) - 0.505) < 1e-9)
        #expect(abs(UsageLog.cost(model: "claude-haiku-5-5", usage: ModelUsage(input: 200_000)) - 0.1) < 1e-9)
        #expect(abs(UsageLog.cost(model: "claude-sonnet-5-5", usage: ModelUsage(cacheRead: 1_000_000)) - 0.1) < 1e-9)
        #expect(UsageLog.cost(model: "qwen3.5:4b", usage: million) == 0)
    }

    @Test("each device logs its own month file; reading merges them")
    func usageFiles() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let day = ISO8601DateFormatter().date(from: "2026-10-24T10:00:00Z")!
        let mac = UsageLog.Entry(at: day, device: "mac", role: .deep, provider: "claude", model: "claude-opus-5-5",
                                 project: "strado", usage: ModelUsage(input: 1000, output: 500))
        let phone = UsageLog.Entry(at: day.addingTimeInterval(60), device: "iphone", role: .fast, provider: "claude",
                                   model: "claude-haiku-5-5", project: nil, usage: ModelUsage(input: 2000, output: 100))
        try UsageLog.append(mac, root: root)
        try UsageLog.append(phone, root: root)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("usage/2026-10.mac.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("usage/2026-10.iphone.jsonl").path))
        let all = UsageLog.entries(root: root)
        #expect(all.map(\.device) == ["mac", "iphone"])
        #expect(abs(UsageLog.spent(root: root, on: day) - (mac.usd + phone.usd)) < 1e-12)
        #expect(mac.usd == 0.004 + 0.01)
    }

    // MARK: Connectors

    @Test("Anthropic: cached system prompt, content blocks, usage read back")
    func anthropicWire() throws {
        let request = ModelRequest(system: "You are Broski.", messages: [
            ModelMessage(role: .user, parts: [.text("hello"), .pdf(Data("%PDF".utf8))]),
            ModelMessage(role: .assistant, parts: [.text("hi")]),
        ], maxTokens: 500, cacheSystem: true)
        let body = AnthropicConnector.body(for: request, model: "claude-sonnet-5-5")
        let system = body["system"] as? [[String: Any]]
        #expect(system?.first?["cache_control"] != nil)
        let first = (body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]
        #expect(first?.map { $0["type"] as? String } == ["text", "document"])
        let reply = try AnthropicConnector.parse(Data(#"{"content":[{"type":"text","text":"Sure."}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":5}}"#.utf8), status: 200)
        #expect(reply.text == "Sure." && reply.usage == ModelUsage(input: 12, output: 3, cacheRead: 40, cacheWrite: 5))
    }

    @Test("OpenAI-compatible: system first, images as data URLs, usage read back")
    func openAIWire() throws {
        let request = ModelRequest(system: "Be brief.", messages: [
            ModelMessage(role: .user, parts: [.text("what's this?"), .image(Data([1, 2, 3]), mediaType: "image/png")]),
        ], maxTokens: 300)
        let body = OpenAICompatibleConnector.body(for: request, model: "qwen3.5:4b")
        let messages = body["messages"] as? [[String: Any]]
        #expect(messages?.first?["role"] as? String == "system" && messages?.first?["content"] as? String == "Be brief.")
        let parts = messages?.last?["content"] as? [[String: Any]]
        #expect(parts?.last?["type"] as? String == "image_url")
        #expect(((parts?.last?["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        let reply = try OpenAICompatibleConnector.parse(Data(#"{"choices":[{"message":{"role":"assistant","content":"A square."},"finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":4}}"#.utf8), status: 200)
        #expect(reply.text == "A square." && reply.usage == ModelUsage(input: 20, output: 4))
        #expect(throws: (any Error).self) { try OpenAICompatibleConnector.parse(Data(#"{"error":{"message":"model not found"}}"#.utf8), status: 404) }
    }

    // MARK: Secrets

    @Test("keys and env lines are masked before anything leaves the device")
    func secretsMasked() {
        // Fake keys, put together here so no line of this file looks like a real one to the secret scan.
        let anthropic = "sk-" + "ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"
        let openAI = "sk-" + "proj-0123456789abcdefghijklmnopqrstuvwx"
        let text = """
        here's my key \(anthropic) and
        OPENAI_API_KEY=\(openAI)
        DATABASE_PASSWORD = hunter2hunter2
        the stop-loss guard needs a 2% limit
        """
        let masked = SecretMask.mask(text)
        #expect(masked.count == 3)
        #expect(!masked.text.contains("sk-ant-api03") && !masked.text.contains("hunter2"))
        #expect(masked.text.contains("the stop-loss guard needs a 2% limit"))
        #expect(SecretMask.mask("nothing secret here, just sk-ant as a word").count == 0)
    }
}
