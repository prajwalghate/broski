import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// The one way Broski calls a model: masks secrets, routes by role, privacy and what the model must read, sends,
/// and logs what it cost.
public struct ModelGateway: Sendable {
    public var settings: ModelSettings
    /// The Broski folder (the usage log lives in it).
    public var root: URL
    public var device: String
    /// The key for a provider id ("claude"), from the device's Keychain or secrets file.
    public var key: @Sendable (String) -> String?
    /// Builds the connector for a provider; tests swap in their own.
    public var makeConnector: @Sendable (ModelProvider) throws -> ModelConnector

    public init(settings: ModelSettings, root: URL, device: String, key: @escaping @Sendable (String) -> String?) {
        self.settings = settings
        self.root = root
        self.device = device
        self.key = key
        self.makeConnector = { provider in try ModelGateway.connector(for: provider, key: key) }
    }

    public static func connector(for provider: ModelProvider, key: (String) -> String?,
                                 transport: @escaping ModelTransport = ModelTransports.urlSession) throws -> ModelConnector {
        switch provider.kind {
        case .anthropic:
            guard let apiKey = key(provider.id), !apiKey.isEmpty else {
                throw ModelFailure.unavailable("Add your \(provider.displayName) key in Settings › Models to use it.")
            }
            return AnthropicConnector(apiKey: apiKey, baseURL: provider.baseURL, transport: transport)
        case .openAICompatible:
            guard let url = provider.baseURL.flatMap(URL.init(string:)) else {
                throw ModelFailure.unavailable("\(provider.displayName) has no address. Set it in Settings › Models.")
            }
            let apiKey = key(provider.id)
            if provider.needsKey && (apiKey ?? "").isEmpty {
                throw ModelFailure.unavailable("Add your \(provider.displayName) key in Settings › Models to use it.")
            }
            return OpenAICompatibleConnector(baseURL: url, apiKey: apiKey, transport: transport)
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) { return AppleOnDeviceConnector() }
            #endif
            throw ModelFailure.unavailable("Apple's on-device model needs macOS 26 or iOS 26 with Apple Intelligence on.")
        }
    }

    /// Sends a request for a role. A local-only conversation that has no local model is refused before anything is sent.
    public func send(_ request: ModelRequest, role: ModelRole, project: String?, localOnly: Bool = false, task: String? = nil) async throws
        -> (reply: ModelReply, route: ModelRouter.Route) {
        let route = try ModelRouter.route(role, settings: settings, localOnly: localOnly, needs: request.needs,
                                          spentToday: UsageLog.spent(root: root))
        var outgoing = Self.masked(request)
        if route.pdfAsText { outgoing = Self.pdfsAsText(outgoing) }
        if outgoing.schemaJSON != nil && !route.provider.acceptsSchema { outgoing = Self.schemaInInstructions(outgoing) }
        let connector = try makeConnector(route.provider)
        let reply: ModelReply
        do {
            do {
                reply = try await connector.send(outgoing, model: route.model)
            } catch ModelFailure.http(400, _) where outgoing.schemaJSON != nil && route.provider.kind == .openAICompatible {
                // The server won't hold this model to a schema after all: once more, with the schema as instructions.
                reply = try await connector.send(Self.schemaInInstructions(outgoing), model: route.model)
            }
        } catch let failure as ModelFailure {
            throw Self.explained(failure, provider: route.provider)
        } catch let error as URLError where error.code != .cancelled {
            throw Self.explained(error, provider: route.provider)
        }
        try? UsageLog.append(UsageLog.Entry(device: device, role: route.role, provider: route.provider.id, model: route.model,
                                            project: project, usage: reply.usage, task: task), root: root)
        return (reply, route)
    }

    /// Sends a request whose reply must be JSON matching `schema`, and decodes it. A provider that can't hold a reply
    /// to a schema gets it as instructions; either way the reply is read leniently (a code fence or a sentence around
    /// the object is fine). A reply cut off at its length limit is an error, never half an object.
    public func sendJSON<T: Decodable>(_ type: T.Type, _ request: ModelRequest, schema: [String: Any], role: ModelRole, project: String?,
                                       localOnly: Bool = false, task: String?) async throws -> (value: T, route: ModelRouter.Route) {
        var request = request
        request.schemaJSON = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
        let (reply, route) = try await send(request, role: role, project: project, localOnly: localOnly, task: task)
        if reply.truncated { throw ModelFailure.truncated }
        return (try ModelJSON.decode(T.self, from: reply.text), route)
    }

    static func schemaInInstructions(_ request: ModelRequest) -> ModelRequest {
        guard let schema = request.schemaJSON else { return request }
        var out = request
        out.system += ModelJSON.instructions(schema)
        out.schemaJSON = nil
        return out
    }

    /// A provider's error in words a person can act on: whose key, what to do, where.
    public static func explained(_ failure: ModelFailure, provider: ModelProvider) -> ModelFailure {
        let name = provider.displayName
        guard case .http(let status, let message) = failure else { return failure }
        switch status {
        case 401, 403:
            return .unavailable("\(name) didn't accept the key. Check it in Settings › Models.")
        case 402:
            return .unavailable("\(name) says the account is out of credit. Add some on its website, or choose another model in Settings › Models.")
        case 404:
            return .unavailable("\(name) doesn't have that model (\(message.prefix(160))). Choose another in Settings › Models.")
        case 408, 504:
            return .unavailable("\(name) took too long to answer. Try again.")
        case 429:
            return .unavailable("\(name) is limiting requests on this key right now. Try again in a minute.")
        case 500...599:
            return .unavailable("\(name) is having trouble (\(status)). Try again in a moment.")
        default:
            return .unavailable("\(name) answered \(status): \(message.prefix(240))")
        }
    }

    public static func explained(_ error: URLError, provider: ModelProvider) -> ModelFailure {
        let name = provider.displayName
        if [.cannotConnectToHost, .cannotFindHost].contains(error.code) && (provider.isLocal || provider.local) {
            return .unavailable("Couldn't reach \(name) at \(provider.baseURL ?? "its address"). Is it running?")
        }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .unavailable("You're offline, so \(name) can't be reached.")
        case .timedOut:
            return .unavailable("\(name) took too long to answer. Try again.")
        default:
            return .unavailable("Couldn't reach \(name): \(error.localizedDescription)")
        }
    }

    static func masked(_ request: ModelRequest) -> ModelRequest {
        var out = request
        out.system = SecretMask.mask(request.system).text
        out.messages = request.messages.map { message in
            ModelMessage(role: message.role, parts: message.parts.map { part in
                if case .text(let text) = part { return .text(SecretMask.mask(text).text) }
                return part
            })
        }
        return out
    }

    /// PDFs replaced by their text (masked like any other text), for models that can't read PDFs.
    static func pdfsAsText(_ request: ModelRequest) -> ModelRequest {
        var out = request
        out.messages = request.messages.map { message in
            ModelMessage(role: message.role, parts: message.parts.map { part in
                guard case .pdf(let data) = part else { return part }
                let text = pdfText(data)
                return .text(text.isEmpty ? "(A PDF was attached, but its text couldn't be read.)"
                                          : "<document>\n\(SecretMask.mask(text).text)\n</document>")
            })
        }
        return out
    }

    static func pdfText(_ data: Data) -> String {
        #if canImport(PDFKit)
        return (PDFDocument(data: data)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        return ""
        #endif
    }
}

// MARK: Memory

/// What Broski knows about you: `memory/about-you.md` (yours to edit, and reflection's), plus what you asked it to
/// remember in conversation, kept per device (`memory/remembered.mac.jsonl`) so no two devices write one file.
public enum Memory {
    struct Event: Codable {
        var v = 1
        var at: Date
        var device: String
        /// remember | forget
        var op: String
        var text: String
        /// Who made the change: nil (you, in a conversation), "reflection", or "undo".
        var by: String?
        /// For reflection: what in your words led to it.
        var why: String?
    }

    static func folder(_ root: URL) -> URL { root.appendingPathComponent("memory", isDirectory: true) }

    static func events(root: URL) -> [Event] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("remembered.") && $0.pathExtension == "jsonl" }
            .flatMap { JSONLines.read(Event.self, from: $0) }
            // Same instant: the remember first, so a forget never lands before what it forgets.
            .sorted { $0.at == $1.at ? $0.op == "remember" && $1.op != "remember" : $0.at < $1.at }
    }

    /// What's still remembered from conversations, oldest first.
    public static func remembered(root: URL) -> [String] {
        var facts: [String] = []
        for event in events(root: root) {
            if event.op == "remember" {
                facts.append(event.text)
            } else if event.op == "forget" {
                facts.removeAll { $0 == event.text }
            }
        }
        return facts
    }

    static func append(_ event: Event, root: URL) throws {
        try JSONLines.append(event, to: folder(root).appendingPathComponent("remembered.\(event.device).jsonl"))
    }

    public static func remember(_ fact: String, root: URL, device: String, at: Date = Date(), by: String? = nil, why: String? = nil) throws {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        try append(Event(at: at, device: device, op: "remember", text: text, by: by, why: why), root: root)
    }

    /// Forgets the remembered fact containing `phrase` (the latest one when `phrase` is empty). False when nothing matched.
    @discardableResult
    public static func forget(_ phrase: String, root: URL, device: String, at: Date = Date(), by: String? = nil, why: String? = nil) throws -> Bool {
        let facts = remembered(root: root)
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = facts.last { $0.lowercased() == wanted }
        guard let fact = wanted.isEmpty ? facts.last : exact ?? facts.last(where: { $0.lowercased().contains(wanted) }) else { return false }
        try append(Event(at: at, device: device, op: "forget", text: fact, by: by, why: why), root: root)
        return true
    }

    /// Everything Broski knows about you, for the start of a conversation; nil when it knows nothing yet.
    public static func aboutYou(root: URL) -> String? {
        let file = (try? String(contentsOf: folder(root).appendingPathComponent("about-you.md"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let facts = remembered(root: root)
        var parts: [String] = []
        if !file.isEmpty { parts.append(file) }
        if !facts.isEmpty { parts.append("Remembered from conversations:\n" + facts.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
