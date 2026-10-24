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

    public static func connector(for provider: ModelProvider, key: (String) -> String?) throws -> ModelConnector {
        switch provider.kind {
        case .anthropic:
            guard let apiKey = key(provider.id), !apiKey.isEmpty else {
                throw ModelFailure.unavailable("Add your Claude key in Settings to talk to Broski.")
            }
            return AnthropicConnector(apiKey: apiKey)
        case .openAICompatible:
            guard let url = provider.baseURL.flatMap(URL.init(string:)) else {
                throw ModelFailure.unavailable("\(provider.id) has no address. Set it in Settings › Models.")
            }
            return OpenAICompatibleConnector(baseURL: url, apiKey: key(provider.id))
        case .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, iOS 26.0, *) { return AppleOnDeviceConnector() }
            #endif
            throw ModelFailure.unavailable("Apple's on-device model needs macOS 26 or iOS 26 with Apple Intelligence on.")
        }
    }

    /// Sends a request for a role. A local-only conversation that has no local model is refused before anything is sent.
    public func send(_ request: ModelRequest, role: ModelRole, project: String?, localOnly: Bool = false) async throws
        -> (reply: ModelReply, route: ModelRouter.Route) {
        let route = try ModelRouter.route(role, settings: settings, localOnly: localOnly, needs: request.needs,
                                          spentToday: UsageLog.spent(root: root))
        var outgoing = Self.masked(request)
        if route.pdfAsText { outgoing = Self.pdfsAsText(outgoing) }
        let reply = try await makeConnector(route.provider).send(outgoing, model: route.model)
        try? UsageLog.append(UsageLog.Entry(device: device, role: route.role, provider: route.provider.id, model: route.model,
                                            project: project, usage: reply.usage), root: root)
        return (reply, route)
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
