import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: Roles and settings

/// Which kind of model a job needs. Code asks for a role; Settings maps each role to a model.
public enum ModelRole: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    /// Quick notes, titles, project and topic tags, save suggestions.
    case fast
    /// Normal conversation turns and Ask.
    case everyday
    /// Brainstorming, reflection, setting up a project.
    case deep

    /// The next role down, used past the daily limit.
    var cheaper: ModelRole? {
        switch self {
        case .deep: return .everyday
        case .everyday: return .fast
        case .fast: return nil
        }
    }

    /// When this role has no model of its own on this device, the roles that stand in, best first.
    var standIns: [ModelRole] {
        switch self {
        case .deep: return [.everyday, .fast]
        case .everyday: return [.deep, .fast]
        case .fast: return [.everyday, .deep]
        }
    }
}

public enum ModelCapability: String, Codable, Sendable {
    case images, pdfs, caching
}

/// Somewhere models run: Claude, any OpenAI-compatible API (OpenAI, Gemini, OpenRouter, Ollama, LM Studio), or
/// Apple's on-device model.
public struct ModelProvider: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case anthropic
        case openAICompatible = "openai"
        case appleOnDevice = "apple"
    }

    public var id: String
    public var kind: Kind
    public var baseURL: String?
    /// The user says it runs on this device. It only counts when the address really is this device (see `isLocal`).
    public var local: Bool
    /// Only the values older versions know go here (they read config.json too); newer facts are optional fields.
    public var capabilities: Set<ModelCapability>
    /// The `ProviderPreset` it was made from ("openai"); nil for providers added before presets.
    public var preset: String?
    /// A name you gave it; nil uses the preset's.
    public var name: String?
    /// Whether its API holds replies to a JSON schema; nil uses the preset's answer.
    public var structuredOutput: Bool?

    public init(id: String, kind: Kind, baseURL: String? = nil, local: Bool = false, capabilities: Set<ModelCapability>? = nil,
                preset: String? = nil, name: String? = nil, structuredOutput: Bool? = nil) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.local = local
        self.capabilities = capabilities ?? (kind == .anthropic ? [.images, .pdfs, .caching] : [])
        self.preset = preset
        self.name = name
        self.structuredOutput = structuredOutput
    }

    static let loopback: Set<String> = ["127.0.0.1", "localhost", "::1", "[::1]"]

    /// Runs on this device: Apple's model, or an OpenAI-compatible server on a loopback address marked local.
    public var isLocal: Bool {
        switch kind {
        case .appleOnDevice: return true
        case .anthropic: return false
        case .openAICompatible:
            guard local, let host = baseURL.flatMap(URL.init(string:))?.host?.lowercased() else { return false }
            return Self.loopback.contains(host)
        }
    }

    /// "OpenAI", "Ollama", or the id of a server added by hand.
    public var displayName: String { name ?? ProviderPreset.of(self).map { $0.id == ProviderPreset.custom.id ? id : $0.name } ?? id }

    /// A cloud provider that won't answer without a key.
    public var needsKey: Bool { kind == .anthropic || (ProviderPreset.of(self)?.needsKey ?? false) }

    /// Its API can hold a reply to a JSON schema (otherwise the schema goes in the instructions).
    public var acceptsSchema: Bool { structuredOutput ?? ProviderPreset.of(self)?.structuredOutput ?? (kind == .anthropic) }
}

public struct ModelChoice: Codable, Equatable, Sendable {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// Which model does what. Kept in config.json; keys stay in each device's Keychain.
public struct ModelSettings: Codable, Equatable, Sendable {
    public var providers: [ModelProvider]
    /// The model for each role.
    public var roles: [ModelRole: ModelChoice]
    /// The model for each role when only this device may be used (local-only projects).
    public var localRoles: [ModelRole: ModelChoice]
    /// Past this spend in a day (US dollars), work moves one role down. Nil: no limit.
    public var dailyLimitUSD: Double?

    public init(providers: [ModelProvider], roles: [ModelRole: ModelChoice], localRoles: [ModelRole: ModelChoice] = [:],
                dailyLimitUSD: Double? = nil) {
        self.providers = providers
        self.roles = roles
        self.localRoles = localRoles
        self.dailyLimitUSD = dailyLimitUSD
    }

    public static let defaults = ModelSettings(
        providers: [ModelProvider(id: "claude", kind: .anthropic)],
        roles: [.fast: ModelChoice(provider: "claude", model: ClaudeModel.fast),
                .everyday: ModelChoice(provider: "claude", model: ClaudeModel.brain),
                .deep: ModelChoice(provider: "claude", model: ClaudeModel.deep)])

    public func provider(_ id: String) -> ModelProvider? { providers.first { $0.id == id } }

    /// An id for a new provider from its name ("LM Studio" → "lm-studio"), never one already taken.
    public func newID(for name: String) -> String {
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        let base = words.isEmpty ? "model" : words.joined(separator: "-")
        var id = base
        var n = 2
        // "claude" is Claude's own: its key is the Claude key.
        while provider(id) != nil || id == "claude" {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    /// Adds the provider, or replaces the one with its id.
    public mutating func add(_ provider: ModelProvider) {
        if let i = providers.firstIndex(where: { $0.id == provider.id }) { providers[i] = provider } else { providers.append(provider) }
    }

    /// Removes the provider and every role it had.
    public mutating func remove(_ id: String) {
        providers.removeAll { $0.id == id }
        roles = roles.filter { $0.value.provider != id }
        localRoles = localRoles.filter { $0.value.provider != id }
    }

    /// Sets a role's model. False when the provider isn't there, or (for `local`) doesn't run on this device.
    @discardableResult
    public mutating func set(_ role: ModelRole, to choice: ModelChoice, local: Bool) -> Bool {
        guard let provider = provider(choice.provider), !choice.model.isEmpty, !local || provider.isLocal else { return false }
        if local { localRoles[role] = choice } else { roles[role] = choice }
        return true
    }

    public mutating func clear(_ role: ModelRole, local: Bool) {
        if local { localRoles[role] = nil } else { roles[role] = nil }
    }
}

// MARK: Router

/// Picks the model for a job: privacy first, then what the model must read, then the day's budget.
public enum ModelRouter {
    public struct Route: Equatable, Sendable {
        public var provider: ModelProvider
        public var model: String
        /// The role whose model was used.
        public var role: ModelRole
        /// Another role's model stood in (this device has none for the role asked for).
        public var substituted: Bool
        /// Moved one role down past the daily limit.
        public var overBudget: Bool
        /// The model can't read PDFs: send their text instead.
        public var pdfAsText: Bool
    }

    public enum Refusal: Error, Equatable, LocalizedError {
        case noLocalModel(ModelRole)
        case noModel(ModelRole)
        case cantRead(ModelCapability)

        public var errorDescription: String? {
            switch self {
            case .noLocalModel:
                return "This conversation has to stay on this device, and no local model is set up. Add one in Settings › Models."
            case .noModel(let role):
                return "No model is chosen for \(role.rawValue) work. Choose one in Settings › Models."
            case .cantRead(let capability):
                return "The model allowed here can't read \(capability.rawValue). Describe it in words, or allow a model that can."
            }
        }
    }

    public static func route(_ role: ModelRole, settings: ModelSettings, localOnly: Bool = false,
                             needs: Set<ModelCapability> = [], spentToday: Double = 0) throws -> Route {
        var wanted = role
        var overBudget = false
        if let limit = settings.dailyLimitUSD, spentToday > limit, let cheaper = role.cheaper {
            wanted = cheaper
            overBudget = true
        }
        let map = localOnly ? settings.localRoles : settings.roles
        for (candidate, substituted) in [(wanted, false)] + wanted.standIns.map({ ($0, true) }) {
            // Away from a local-only conversation, only the role's own model is used.
            if substituted && !localOnly { break }
            guard let choice = map[candidate], let provider = settings.provider(choice.provider) else { continue }
            if localOnly && !provider.isLocal { continue }
            if needs.contains(.images) && !provider.capabilities.contains(.images) { throw Refusal.cantRead(.images) }
            return Route(provider: provider, model: choice.model, role: candidate, substituted: substituted,
                         overBudget: overBudget, pdfAsText: needs.contains(.pdfs) && !provider.capabilities.contains(.pdfs))
        }
        throw localOnly ? Refusal.noLocalModel(role) : Refusal.noModel(role)
    }
}

// MARK: Requests and replies

public enum ModelPart: Equatable, Sendable {
    case text(String)
    case image(Data, mediaType: String)
    case pdf(Data)
}

public struct ModelMessage: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }

    public var role: Role
    public var parts: [ModelPart]

    public init(role: Role, parts: [ModelPart]) {
        self.role = role
        self.parts = parts
    }

    public init(role: Role, text: String) {
        self.init(role: role, parts: [.text(text)])
    }

    /// The text parts, joined.
    public var text: String {
        parts.compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n\n")
    }
}

public struct ModelRequest: Equatable, Sendable {
    public var system: String
    public var messages: [ModelMessage]
    public var maxTokens: Int
    /// Mark the system prompt for caching (memory and a project page reused across turns).
    public var cacheSystem: Bool
    /// Also mark the conversation up to the previous reply: the next turn sends it unchanged, so it's read from the
    /// cache instead of billed again.
    public var cacheHistory: Bool
    /// Claude's effort setting; other providers ignore it.
    public var effort: String
    /// A JSON schema the reply must match, as JSON text; nil for free text.
    public var schemaJSON: String?
    /// Seconds to wait for the whole reply.
    public var timeout: TimeInterval

    public init(system: String, messages: [ModelMessage], maxTokens: Int = 4000, cacheSystem: Bool = false, cacheHistory: Bool = false,
                effort: String = "low", schemaJSON: String? = nil, timeout: TimeInterval = 120) {
        self.system = system
        self.messages = messages
        self.maxTokens = maxTokens
        self.cacheSystem = cacheSystem
        self.cacheHistory = cacheHistory
        self.effort = effort
        self.schemaJSON = schemaJSON
        self.timeout = timeout
    }

    /// What the model has to be able to read.
    public var needs: Set<ModelCapability> {
        var needs: Set<ModelCapability> = []
        for part in messages.flatMap(\.parts) {
            switch part {
            case .image: needs.insert(.images)
            case .pdf: needs.insert(.pdfs)
            case .text: break
            }
        }
        return needs
    }
}

public struct ModelUsage: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct ModelReply: Equatable, Sendable {
    public var text: String
    /// The model stopped at its length limit.
    public var truncated: Bool
    public var usage: ModelUsage
}

public enum ModelFailure: Error, Equatable, LocalizedError {
    case http(Int, String)
    case badResponse(String)
    case empty
    /// Stopped at its length limit with nothing usable (a JSON reply cut in half, or only thinking).
    case truncated
    case refused
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let message): return "The model answered \(status): \(message)"
        case .badResponse(let why): return "The model's reply couldn't be read (\(why))."
        case .empty: return "The model sent an empty reply."
        case .truncated: return "The model's reply hit its length limit before it finished."
        case .refused: return "The model declined this request."
        case .unavailable(let why): return why
        }
    }
}

public protocol ModelConnector: Sendable {
    func send(_ request: ModelRequest, model: String) async throws -> ModelReply
}

/// How a connector reaches its server; tests pass their own, so no test touches the network.
public typealias ModelTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public enum ModelTransports {
    public static let urlSession: ModelTransport = { request in try await URLSession.shared.data(for: request) }
}

private func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }

/// The error message in a provider's JSON error reply, else the start of what it sent.
private func errorMessage(_ data: Data, json: [String: Any]?) -> String {
    ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String)
        ?? String(decoding: data.prefix(300), as: UTF8.self)
}

// MARK: Connectors

/// Claude through the Messages API: Anthropic's own, or another address that speaks it (a company gateway, a proxy).
public struct AnthropicConnector: ModelConnector {
    public static let defaultBase = "https://api.anthropic.com"
    public var apiKey: String
    public var baseURL: String
    public var transport: ModelTransport

    public init(apiKey: String, baseURL: String? = nil, transport: @escaping ModelTransport = ModelTransports.urlSession) {
        self.apiKey = apiKey
        self.baseURL = baseURL ?? Self.defaultBase
        self.transport = transport
    }

    /// Server-side fallbacks are Anthropic's own; another address gets a plain Messages API call.
    var isAnthropic: Bool { URL(string: baseURL)?.host?.lowercased() == "api.anthropic.com" }

    static func endpoint(_ base: String, _ path: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1") { trimmed.removeLast(3) }
        return URL(string: trimmed + "/v1/" + path)
    }

    public static func body(for request: ModelRequest, model: String, extras: Bool = true) -> [String: Any] {
        var output: [String: Any] = ["effort": request.effort]
        if let schema = request.schemaJSON.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) {
            output["format"] = ["type": "json_schema", "schema": schema]
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": request.cacheSystem
                ? [["type": "text", "text": request.system, "cache_control": ["type": "ephemeral"]]] as Any
                : request.system,
            "messages": messages(for: request),
            "output_config": output,
        ]
        // Haiku has no server-side fallback.
        if extras && !model.contains("haiku") { body["fallbacks"] = "default" }
        return body
    }

    /// The messages as content blocks; with `cacheHistory`, a cache marker on the last block of the previous reply
    /// (everything up to there is the same next turn), never on the new message.
    static func messages(for request: ModelRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = request.messages.map { ["role": $0.role.rawValue, "content": $0.parts.map(block)] }
        if request.cacheHistory, let index = request.messages.indices.dropLast().last(where: { request.messages[$0].role == .assistant }),
           var blocks = messages[index]["content"] as? [[String: Any]], !blocks.isEmpty {
            blocks[blocks.count - 1]["cache_control"] = ["type": "ephemeral"]
            messages[index]["content"] = blocks
        }
        return messages
    }

    static func block(_ part: ModelPart) -> [String: Any] {
        switch part {
        case .text(let text): return ["type": "text", "text": text]
        case .image(let data, let mediaType):
            return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
        case .pdf(let data):
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]]
        }
    }

    /// Reads a Messages API reply. `truncated` means it stopped at max_tokens, not at the end of its answer; cut off
    /// while still thinking (no text at all) is `ModelFailure.truncated`.
    public static func parse(_ data: Data, status: Int) throws -> ModelReply {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else { throw ModelFailure.http(status, errorMessage(data, json: json)) }
        guard let json else { throw ModelFailure.badResponse("not JSON") }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw ModelFailure.refused }
        let text = ((json["content"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let truncated = stop == "max_tokens"
        guard !text.isEmpty else { throw truncated ? ModelFailure.truncated : ModelFailure.empty }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return ModelReply(text: text, truncated: truncated, usage: ModelUsage(
            input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
            cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0, cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0))
    }

    /// The model ids in a `/v1/models` reply, sorted.
    static func parseModels(_ data: Data) -> [String] {
        OpenAICompatibleConnector.parseModels(data)
    }

    func headers(_ request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    }

    public static func models(apiKey: String, baseURL: String? = nil, transport: @escaping ModelTransport = ModelTransports.urlSession) async throws -> [String] {
        let connector = AnthropicConnector(apiKey: apiKey, baseURL: baseURL, transport: transport)
        guard let url = endpoint(connector.baseURL, "models?limit=1000") else { throw ModelFailure.unavailable("That address isn't a URL.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        connector.headers(&request)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(status(response)) else {
            throw ModelFailure.http(status(response), errorMessage(data, json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]))
        }
        return parseModels(data)
    }

    public func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
        guard let url = Self.endpoint(baseURL, "messages") else { throw ModelFailure.unavailable("\(baseURL) isn't a URL.") }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout
        headers(&urlRequest)
        let fallback = isAnthropic && !model.contains("haiku")
        if fallback { urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: model, extras: isAnthropic))
        let (data, response) = try await transport(urlRequest)
        return try Self.parse(data, status: status(response))
    }
}

/// Any server speaking OpenAI's chat completions: OpenAI, Gemini's compatible API, OpenRouter, Groq, Mistral,
/// DeepSeek, Ollama, LM Studio, llama.cpp, vLLM.
public struct OpenAICompatibleConnector: ModelConnector {
    public var baseURL: URL
    public var apiKey: String?
    public var transport: ModelTransport

    public init(baseURL: URL, apiKey: String? = nil, transport: @escaping ModelTransport = ModelTransports.urlSession) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    static func modelsURL(_ base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + "/models")
    }

    /// The model ids in a `/models` reply, sorted.
    static func parseModels(_ data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// What the server at `base` offers (OpenAI, Gemini, OpenRouter, Ollama, LM Studio, llama.cpp, vLLM all answer `/models`).
    public static func models(base: String, apiKey: String?, transport: @escaping ModelTransport = ModelTransports.urlSession) async throws -> [String] {
        guard let url = modelsURL(base) else { throw ModelFailure.unavailable("That address isn't a URL.") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport(request)
        guard (200..<300).contains(status(response)) else {
            throw ModelFailure.http(status(response), errorMessage(data, json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]))
        }
        return parseModels(data)
    }

    /// OpenAI's newer models take `max_completion_tokens` and refuse `max_tokens`; every other server takes `max_tokens`.
    public static func body(for request: ModelRequest, model: String, host: String? = nil) -> [String: Any] {
        var messages: [[String: Any]] = [["role": "system", "content": request.system]]
        for message in request.messages {
            let textOnly = message.parts.allSatisfy { if case .text = $0 { return true } else { return false } }
            messages.append(["role": message.role.rawValue, "content": textOnly ? message.text as Any : message.parts.map(part) as Any])
        }
        var body: [String: Any] = ["model": model, "messages": messages]
        body[host == "api.openai.com" ? "max_completion_tokens" : "max_tokens"] = request.maxTokens
        if let schema = request.schemaJSON.flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) {
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "reply", "schema": schema]]
        }
        return body
    }

    static func part(_ part: ModelPart) -> [String: Any] {
        switch part {
        case .text(let text): return ["type": "text", "text": text]
        case .image(let data, let mediaType):
            return ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(data.base64EncodedString())"]]
        case .pdf:
            // The router asks for PDFs as text when a model can't read them; this is the fallback if one slips through.
            return ["type": "text", "text": "(A PDF was attached; this model can't read it.)"]
        }
    }

    public static func parse(_ data: Data, status: Int) throws -> ModelReply {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else { throw ModelFailure.http(status, errorMessage(data, json: json)) }
        guard let json else { throw ModelFailure.badResponse("not JSON") }
        let choice = (json["choices"] as? [[String: Any]])?.first
        let finish = choice?["finish_reason"] as? String
        guard let text = (choice?["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
            throw finish == "length" ? ModelFailure.truncated : ModelFailure.empty
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return ModelReply(text: text, truncated: finish == "length",
                          usage: ModelUsage(input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0))
    }

    public func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = max(request.timeout, 180)
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: request, model: model, host: baseURL.host?.lowercased()))
        let (data, response) = try await transport(urlRequest)
        return try Self.parse(data, status: status(response))
    }
}

#if canImport(FoundationModels)
/// Apple's on-device model (macOS 26 and iOS 26 with Apple Intelligence on). Free, private, text only.
@available(macOS 26.0, iOS 26.0, *)
public struct AppleOnDeviceConnector: ModelConnector {
    public init() {}

    public static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    public func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
        guard Self.isAvailable else { throw ModelFailure.unavailable("Apple's on-device model isn't available on this device.") }
        let session = LanguageModelSession(instructions: request.system)
        // The earlier turns go in as text ahead of the last one.
        let earlier = request.messages.dropLast().map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
        let last = request.messages.last?.text ?? ""
        let prompt = earlier.isEmpty ? last : earlier.joined(separator: "\n\n") + "\n\nUser: " + last
        let response = try await session.respond(to: prompt)
        return ModelReply(text: response.content, truncated: false, usage: ModelUsage())
    }
}
#endif

// MARK: Usage and cost

/// What each model call cost, one file per device per month (`usage/2026-10.mac.jsonl`), so devices never share a file.
public enum UsageLog {
    public struct Entry: Codable, Equatable, Sendable {
        public var v = 1
        public var at: Date
        public var device: String
        public var role: ModelRole
        public var provider: String
        public var model: String
        public var project: String?
        public var usage: ModelUsage
        public var usd: Double
        /// What the call was for: conversation, review, page, filing, ask, riff, reflection… (nil in older lines).
        public var task: String?

        public init(at: Date = Date(), device: String, role: ModelRole, provider: String, model: String, project: String?,
                    usage: ModelUsage, task: String? = nil) {
            self.at = at
            self.device = device
            self.role = role
            self.provider = provider
            self.model = model
            self.project = project
            self.usage = usage
            self.usd = UsageLog.cost(model: model, usage: usage)
            self.task = task
        }
    }

    /// US dollars per million tokens: input, output, cache read, cache write (5-minute). From Anthropic's pricing page,
    /// October 2026. Models not listed (local ones) cost nothing here.
    struct Price {
        var input, output, cacheRead, cacheWrite: Double
    }

    static let prices: [String: Price] = [
        "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5),
        "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.50),
        "claude-haiku-5-5": Price(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
    ]
    /// Haiku's price once a prompt passes 100,000 tokens.
    static let haikuLong = Price(input: 0.50, output: 2.50, cacheRead: 0.05, cacheWrite: 0.625)

    public static func cost(model: String, usage: ModelUsage) -> Double {
        guard var price = prices[model] else { return 0 }
        if model == ClaudeModel.fast, usage.input + usage.cacheRead + usage.cacheWrite > 100_000 { price = haikuLong }
        let total = Double(usage.input) * price.input + Double(usage.output) * price.output
            + Double(usage.cacheRead) * price.cacheRead + Double(usage.cacheWrite) * price.cacheWrite
        return total / 1_000_000
    }

    static func file(for entry: Entry, root: URL) -> URL {
        let parts = Calendar.current.dateComponents([.year, .month], from: entry.at)
        let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
        return root.appendingPathComponent("usage", isDirectory: true).appendingPathComponent("\(month).\(entry.device).jsonl")
    }

    public static func append(_ entry: Entry, root: URL) throws {
        try JSONLines.append(entry, to: file(for: entry, root: root))
    }

    /// Every device's entries, oldest first. Lines that don't parse are skipped.
    public static func entries(root: URL) -> [Entry] {
        let folder = root.appendingPathComponent("usage", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.flatMap { JSONLines.read(Entry.self, from: $0) }.sorted { $0.at < $1.at }
    }

    public struct Summary: Equatable, Sendable {
        public struct Line: Equatable, Sendable {
            public var model: String
            public var calls: Int
            public var usd: Double
        }

        public struct TaskLine: Equatable, Sendable {
            public var task: String
            public var calls: Int
            public var usd: Double
        }

        public var today: Double
        public var month: Double
        /// This month by model, most spent first.
        public var byModel: [Line]
        /// This month by what the calls were for, most spent first.
        public var byTask: [TaskLine]

        public static let none = Summary(today: 0, month: 0, byModel: [], byTask: [])
    }

    /// A call's role from its model, for calls that don't say (Claude's tiers; anything else counts as everyday).
    public static func role(forModel model: String) -> ModelRole {
        if model.contains("haiku") { return .fast }
        if model.contains("opus") || model.contains("fable") || model.contains("mythos") { return .deep }
        return .everyday
    }

    /// Today, this calendar month, and this month by model, every device together.
    public static func summary(_ entries: [Entry], now: Date = Date()) -> Summary {
        let calendar = Calendar.current
        let month = entries.filter { calendar.isDate($0.at, equalTo: now, toGranularity: .month) }
        let today = month.filter { calendar.isDate($0.at, inSameDayAs: now) }.reduce(0) { $0 + $1.usd }
        let lines = Dictionary(grouping: month, by: \.model).map { model, all in
            Summary.Line(model: model, calls: all.count, usd: all.reduce(0) { $0 + $1.usd })
        }
        let tasks = Dictionary(grouping: month, by: { $0.task ?? "other" }).map { task, all in
            Summary.TaskLine(task: task, calls: all.count, usd: all.reduce(0) { $0 + $1.usd })
        }
        return Summary(today: today, month: month.reduce(0) { $0 + $1.usd },
                       byModel: lines.sorted { $0.usd == $1.usd ? $0.model < $1.model : $0.usd > $1.usd },
                       byTask: tasks.sorted { $0.usd == $1.usd ? $0.task < $1.task : $0.usd > $1.usd })
    }

    /// Spend on the calendar day of `day`, every device together.
    public static func spent(root: URL, on day: Date = Date()) -> Double {
        entries(root: root).filter { Calendar.current.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.usd }
    }
}

// MARK: Secrets

/// Masks keys, tokens and `.env`-style secrets in text before it goes to any model.
public enum SecretMask {
    /// `NAME_KEY=value` lines, as in a pasted .env file. Masked first, so a key inside one counts once.
    static let assignment = #"(?m)^[ \t]*(?:export[ \t]+)?([A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD))[ \t]*=[ \t]*\S.*$"#
    static let keys = [
        #"sk-ant-[A-Za-z0-9_-]{20,}"#,
        #"sk-(?:proj-)?[A-Za-z0-9_-]{32,}"#,
        #"gh[pousr]_[A-Za-z0-9]{36,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"AIza[0-9A-Za-z_-]{35}"#,
        #"xox[baprs]-[A-Za-z0-9-]{10,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
    ]

    public static func mask(_ text: String) -> (text: String, count: Int) {
        var out = text
        var count = 0
        func replace(_ pattern: String, with template: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(out.startIndex..., in: out)
            count += regex.numberOfMatches(in: out, range: range)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        replace(assignment, with: "$1=[hidden]")
        for pattern in keys { replace(pattern, with: "[hidden key]") }
        return (out, count)
    }
}
