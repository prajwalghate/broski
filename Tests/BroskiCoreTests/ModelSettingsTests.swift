import Foundation
import Testing
@testable import BroskiCore

/// Settings › Models: adding and removing providers, choosing a model per role, and what it all cost.
@Suite("Model settings")
struct ModelSettingsTests {
    @Test("a provider's id comes from its name and never clashes")
    func ids() {
        var settings = ModelSettings.defaults
        #expect(settings.newID(for: "Ollama") == "ollama")
        #expect(settings.newID(for: "LM Studio!") == "lm-studio")
        #expect(settings.newID(for: "Claude") == "claude-2")
        settings.add(ModelProvider(id: "ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", local: true))
        #expect(settings.newID(for: "ollama") == "ollama-2")
        #expect(settings.newID(for: "  ") == "model")
    }

    @Test("removing a provider takes it out of every role it had")
    func remove() {
        var settings = ModelSettings.defaults
        settings.add(ModelProvider(id: "ollama", kind: .openAICompatible, baseURL: "http://127.0.0.1:11434/v1", local: true))
        let set1 = settings.set(.fast, to: ModelChoice(provider: "ollama", model: "llama3.2"), local: false)
        #expect(set1)
        let set2 = settings.set(.everyday, to: ModelChoice(provider: "ollama", model: "llama3.2"), local: true)
        #expect(set2)
        settings.remove("ollama")
        #expect(settings.provider("ollama") == nil)
        #expect(settings.roles[.fast] == nil && settings.localRoles.isEmpty)
        #expect(settings.roles[.deep]?.provider == "claude")
    }

    @Test("only a model on this device can be a local-only role, and a role can be cleared")
    func localRoles() {
        var settings = ModelSettings.defaults
        settings.add(ModelProvider(id: "remote", kind: .openAICompatible, baseURL: "https://api.example.com/v1", local: true))
        let set3 = settings.set(.everyday, to: ModelChoice(provider: "remote", model: "m"), local: true)
        #expect(!set3)
        let set4 = settings.set(.everyday, to: ModelChoice(provider: "claude", model: ClaudeModel.brain), local: true)
        #expect(!set4)
        let set5 = settings.set(.everyday, to: ModelChoice(provider: "nobody", model: "m"), local: false)
        #expect(!set5)
        settings.add(ModelProvider(id: "apple", kind: .appleOnDevice))
        let set6 = settings.set(.everyday, to: ModelChoice(provider: "apple", model: "default"), local: true)
        #expect(set6)
        settings.clear(.everyday, local: true)
        #expect(settings.localRoles.isEmpty)
    }

    @Test("spend today, this month, and by model")
    func summary() {
        let now = ISO8601DateFormatter().date(from: "2026-10-24T12:00:00Z")!
        let usage = ModelUsage(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0)
        let entries = [
            UsageLog.Entry(at: now, device: "mac", role: .everyday, provider: "claude", model: ClaudeModel.brain, project: nil, usage: usage),
            UsageLog.Entry(at: now.addingTimeInterval(-3 * 86_400), device: "iphone", role: .deep, provider: "claude", model: ClaudeModel.deep, project: nil, usage: usage),
            UsageLog.Entry(at: now.addingTimeInterval(-40 * 86_400), device: "mac", role: .deep, provider: "claude", model: ClaudeModel.deep, project: nil, usage: usage),
            UsageLog.Entry(at: now, device: "mac", role: .fast, provider: "ollama", model: "llama3.2", project: nil, usage: usage),
        ]
        let summary = UsageLog.summary(entries, now: now)
        #expect(summary.today == 2)
        #expect(summary.month == 6)
        #expect(summary.byModel.map(\.model) == [ClaudeModel.deep, ClaudeModel.brain, "llama3.2"])
        #expect(summary.byModel.first?.calls == 1 && summary.byModel.last?.usd == 0)
    }

    @Test("an OpenAI-compatible server's models are listed from /models")
    func listModels() {
        let json = #"{"object":"list","data":[{"id":"qwen2.5:7b","object":"model"},{"id":"llama3.2","object":"model"},{"object":"model"}]}"#
        #expect(OpenAICompatibleConnector.parseModels(Data(json.utf8)) == ["llama3.2", "qwen2.5:7b"])
        #expect(OpenAICompatibleConnector.parseModels(Data("nope".utf8)).isEmpty)
        #expect(OpenAICompatibleConnector.modelsURL("http://localhost:11434/v1/")?.absoluteString == "http://localhost:11434/v1/models")
    }
}
