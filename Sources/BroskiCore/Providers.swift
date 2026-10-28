import Foundation

// MARK: Presets

/// The providers Broski knows how to reach: what each needs, what it can read, and the model it suggests for each
/// role. A preset is a starting point; the provider's own model list, read when you connect it, decides what's offered.
public struct ProviderPreset: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ModelProvider.Kind
    public var baseURL: String?
    /// Where to get a key, for the providers that need one.
    public var keyURL: String?
    public var needsKey: Bool
    /// Runs on this device (at a loopback address).
    public var local: Bool
    public var capabilities: Set<ModelCapability>
    /// The API can hold a reply to a JSON schema; without it the schema goes in the instructions.
    public var structuredOutput: Bool
    /// The model for each role, when the provider still offers it.
    public var suggested: [ModelRole: String]
    /// One line for the chooser.
    public var blurb: String

    public static let claude = ProviderPreset(
        id: "claude", name: "Claude", kind: .anthropic, baseURL: nil, keyURL: "https://platform.claude.com/settings/keys",
        needsKey: true, local: false, capabilities: [.images, .pdfs, .caching], structuredOutput: true,
        suggested: [.fast: ClaudeModel.fast, .everyday: ClaudeModel.brain, .deep: ClaudeModel.deep],
        blurb: "Anthropic's models. Reads images and PDFs.")
    public static let openAI = ProviderPreset(
        id: "openai", name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
        keyURL: "https://platform.openai.com/api-keys", needsKey: true, local: false, capabilities: [.images], structuredOutput: true,
        suggested: [.fast: "gpt-6-luna", .everyday: "gpt-6.1-terra", .deep: "gpt-6.1-sol"],
        blurb: "GPT models. Reads images.")
    public static let gemini = ProviderPreset(
        id: "gemini", name: "Google Gemini", kind: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
        keyURL: "https://aistudio.google.com/apikey", needsKey: true, local: false, capabilities: [.images], structuredOutput: true,
        suggested: [.fast: "gemini-3.5-flash-lite", .everyday: "gemini-3.8-flash", .deep: "gemini-3.1-pro-preview"],
        blurb: "Google's models, with a free tier. Reads images.")
    public static let openRouter = ProviderPreset(
        id: "openrouter", name: "OpenRouter", kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1",
        keyURL: "https://openrouter.ai/keys", needsKey: true, local: false, capabilities: [.images], structuredOutput: false,
        suggested: [.fast: "anthropic/claude-haiku-5.5", .everyday: "anthropic/claude-sonnet-5.5", .deep: "anthropic/claude-opus-5.5"],
        blurb: "One key for hundreds of models from every lab.")
    public static let groq = ProviderPreset(
        id: "groq", name: "Groq", kind: .openAICompatible, baseURL: "https://api.groq.com/openai/v1",
        keyURL: "https://console.groq.com/keys", needsKey: true, local: false, capabilities: [], structuredOutput: false,
        suggested: [.fast: "llama-3.1-8b-instant", .everyday: "openai/gpt-oss-120b", .deep: "openai/gpt-oss-120b"],
        blurb: "Open models, very fast. Text only.")
    public static let mistral = ProviderPreset(
        id: "mistral", name: "Mistral", kind: .openAICompatible, baseURL: "https://api.mistral.ai/v1",
        keyURL: "https://console.mistral.ai/api-keys", needsKey: true, local: false, capabilities: [.images], structuredOutput: true,
        suggested: [.fast: "mistral-small-latest", .everyday: "mistral-medium-latest", .deep: "mistral-large-latest"],
        blurb: "Mistral's models, hosted in Europe. Reads images.")
    public static let deepSeek = ProviderPreset(
        id: "deepseek", name: "DeepSeek", kind: .openAICompatible, baseURL: "https://api.deepseek.com/v1",
        keyURL: "https://platform.deepseek.com/api_keys", needsKey: true, local: false, capabilities: [], structuredOutput: false,
        suggested: [.fast: "deepseek-chat", .everyday: "deepseek-chat", .deep: "deepseek-reasoner"],
        blurb: "Low-cost models. Text only.")
    public static let ollama = ProviderPreset(
        id: "ollama", name: "Ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", keyURL: nil,
        needsKey: false, local: true, capabilities: [], structuredOutput: true, suggested: [:],
        blurb: "Models on this Mac. Free and private.")
    public static let lmStudio = ProviderPreset(
        id: "lm-studio", name: "LM Studio", kind: .openAICompatible, baseURL: "http://localhost:1234/v1", keyURL: nil,
        needsKey: false, local: true, capabilities: [], structuredOutput: true, suggested: [:],
        blurb: "Models on this Mac. Free and private.")
    public static let apple = ProviderPreset(
        id: "apple", name: "Apple on-device", kind: .appleOnDevice, baseURL: nil, keyURL: nil, needsKey: false, local: true,
        capabilities: [], structuredOutput: false, suggested: [.fast: "default", .everyday: "default", .deep: "default"],
        blurb: "Apple Intelligence's model. Free and private; text only, short answers.")
    public static let custom = ProviderPreset(
        id: "custom", name: "Another server", kind: .openAICompatible, baseURL: nil, keyURL: nil, needsKey: false, local: false,
        capabilities: [], structuredOutput: false, suggested: [:],
        blurb: "Any OpenAI-compatible server: llama.cpp, vLLM, LiteLLM.")

    /// In the order the chooser shows them.
    public static let all: [ProviderPreset] = [claude, openAI, gemini, openRouter, groq, mistral, deepSeek, ollama, lmStudio, apple, custom]

    public static func named(_ id: String) -> ProviderPreset? { all.first { $0.id == id } }

    /// The preset a provider was made from: the one it names, else the one its address belongs to.
    public static func of(_ provider: ModelProvider) -> ProviderPreset? {
        if let id = provider.preset, let preset = named(id) { return preset }
        switch provider.kind {
        case .anthropic: return claude
        case .appleOnDevice: return apple
        case .openAICompatible:
            guard let url = provider.baseURL.flatMap(URL.init(string:)), let host = url.host?.lowercased() else { return nil }
            return all.first { preset in
                guard preset.kind == .openAICompatible, let base = preset.baseURL.flatMap(URL.init(string:)) else { return false }
                if preset.local { return ModelProvider.loopback.contains(host) && url.port == base.port }
                return base.host == host
            }
        }
    }

    /// A provider made from this preset.
    public func provider(id: String, baseURL: String? = nil) -> ModelProvider {
        ModelProvider(id: id, kind: kind, baseURL: baseURL ?? self.baseURL, local: local, capabilities: capabilities, preset: self.id)
    }

    // MARK: Picking models

    /// What isn't a chat model, in a provider's list.
    static let notChat = ["embed", "whisper", "tts", "dall-e", "image", "audio", "moderation", "realtime", "transcribe",
                          "search", "rerank", "guard", "speech", "sora", "veo"]
    /// Words in model names that point to a role, best first.
    static let hints: [ModelRole: [String]] = [
        .fast: ["luna", "nano", "mini", "lite", "haiku", "instant", "small", "8b"],
        .deep: ["astra", "opus", "pro", "sol", "large", "reasoner", "ultra"],
        .everyday: ["terra", "sonnet", "flash", "medium", "chat", "plus"],
    ]

    static func matches(_ model: String, _ role: ModelRole) -> Bool {
        let name = model.lowercased()
        return (hints[role] ?? []).contains { name.contains($0) }
    }

    /// The model for `role` among the ones the provider offers: the suggestion when it's there, else one whose name
    /// fits the role, else the first. With nothing listed (the list couldn't be read), the suggestion.
    public func pick(_ role: ModelRole, from available: [String]) -> String? {
        guard !available.isEmpty else { return suggested[role] }
        if let suggestion = suggested[role], available.contains(suggestion) { return suggestion }
        let chat = available.filter { model in !Self.notChat.contains { model.lowercased().contains($0) } }
        guard !chat.isEmpty else { return available.first }
        let others = ModelRole.allCases.filter { $0 != role }
        for hint in Self.hints[role] ?? [] {
            let fits = chat.filter { model in
                model.lowercased().contains(hint) && (role == .fast || !others.contains { Self.matches(model, $0) && $0 != .everyday })
            }
            if let first = fits.first { return first }
        }
        return chat.first { model in !others.contains { Self.matches(model, $0) } } ?? chat.first
    }

    /// `settings` with this preset's provider added (as `providerID`) and every role on it. A provider that runs on
    /// this device also takes the local-only roles.
    public func apply(to settings: ModelSettings, providerID: String, available: [String], baseURL: String? = nil) -> ModelSettings {
        apply(to: settings, provider: self.provider(id: providerID, baseURL: baseURL ?? settings.provider(providerID)?.baseURL),
              available: available)
    }

    /// The same, for a provider already made (a server added by hand, with its own name and address).
    public func apply(to settings: ModelSettings, provider: ModelProvider, available: [String]) -> ModelSettings {
        var new = settings
        new.add(provider)
        for role in ModelRole.allCases {
            guard let model = pick(role, from: available) else { continue }
            new.roles[role] = ModelChoice(provider: provider.id, model: model)
            if provider.isLocal { new.localRoles[role] = ModelChoice(provider: provider.id, model: model) }
        }
        return new
    }
}

extension ModelSettings {
    /// The name of the provider `role` runs on ("OpenAI", "Ollama"), for labels; nil when no model is chosen.
    public func providerName(for role: ModelRole) -> String? {
        roles[role].flatMap { provider($0.provider) }?.displayName
    }

    /// The id to connect `preset` under: the provider already made from it (connecting again updates it), else the
    /// preset's own id, else a new one. Every server added by hand gets its own.
    public func providerID(for preset: ProviderPreset) -> String {
        if preset.id != ProviderPreset.custom.id,
           let existing = providers.first(where: { ProviderPreset.of($0)?.id == preset.id }) { return existing.id }
        if provider(preset.id) == nil { return preset.id }
        return newID(for: preset.id == ProviderPreset.custom.id ? "server" : preset.name)
    }
}

// MARK: Structured replies

public enum ModelJSON {
    /// The JSON object in a model's reply: as it is, inside a ```json fence, or with a sentence around it.
    public static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return Data(text[start...end].utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = object(in: text) else { throw ModelFailure.badResponse("there's no JSON object in it") }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ModelFailure.badResponse(error.localizedDescription)
        }
    }

    /// The schema as instructions, for a model whose API can't hold its reply to one.
    static func instructions(_ schemaJSON: String) -> String {
        "\n\nReply with only one JSON object that matches this JSON schema, and no other text before or after it:\n" + schemaJSON
    }
}

// MARK: Connecting

/// Connecting a provider: read its models, then send one tiny request to show the key (or the server) works.
public enum ProviderCheck {
    public struct Result: Equatable, Sendable {
        /// What the provider offers (empty when it wouldn't say).
        public var models: [String]
        /// The model the test request used.
        public var tested: String
        public var seconds: Double
    }

    /// The models a provider offers, from its own list.
    public static func models(_ provider: ModelProvider, key: String?, transport: @escaping ModelTransport = ModelTransports.urlSession) async throws -> [String] {
        switch provider.kind {
        case .anthropic:
            guard let key, !key.isEmpty else { throw ModelFailure.unavailable("Paste your \(provider.displayName) key first.") }
            return try await AnthropicConnector.models(apiKey: key, baseURL: provider.baseURL, transport: transport)
        case .openAICompatible:
            guard let base = provider.baseURL else { throw ModelFailure.unavailable("\(provider.displayName) has no address.") }
            return try await OpenAICompatibleConnector.models(base: base, apiKey: key, transport: transport)
        case .appleOnDevice:
            return ["default"]
        }
    }

    /// Reads the model list (best effort), then sends "Ready?" to `model`, or to the fast role's pick.
    public static func run(_ provider: ModelProvider, key: String?, model: String? = nil,
                           transport: @escaping ModelTransport = ModelTransports.urlSession) async throws -> Result {
        let started = Date()
        let preset = ProviderPreset.of(provider)
        var listed: [String] = []
        do {
            listed = try await models(provider, key: key, transport: transport)
        } catch let failure as ModelFailure {
            // A rejected key fails here already; a server that just won't list its models still gets the test request.
            if case .http(let status, _) = failure, [401, 403].contains(status) {
                throw ModelGateway.explained(failure, provider: provider)
            }
        } catch let error as URLError {
            throw ModelGateway.explained(error, provider: provider)
        }
        guard let tested = model ?? preset?.pick(.fast, from: listed) ?? listed.first else {
            throw ModelFailure.unavailable("\(provider.displayName) didn't list any models. Load one in it, then try again.")
        }
        let connector = try ModelGateway.connector(for: provider, key: { _ in key }, transport: transport)
        do {
            _ = try await connector.send(ModelRequest(system: "Reply with the single word OK.",
                                                      messages: [ModelMessage(role: .user, text: "Ready?")], maxTokens: 256), model: tested)
        } catch ModelFailure.empty, ModelFailure.truncated, ModelFailure.refused {
            // Still an answer: the key and the model work, which is all this checks.
        } catch let failure as ModelFailure {
            throw ModelGateway.explained(failure, provider: provider)
        } catch let error as URLError {
            throw ModelGateway.explained(error, provider: provider)
        }
        return Result(models: listed, tested: tested, seconds: Date().timeIntervalSince(started))
    }
}
