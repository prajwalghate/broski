import Foundation
import Testing
@testable import BroskiCore

/// Broski isn't tied to one AI company: every provider is a preset, every feature asks the gateway for a role, and
/// nothing assumes Claude.
@Suite("Providers")
struct ProvidersTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-providers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Records what it was sent; answers with `replies` in turn (the last one repeats), or throws `errors` first.
    final class Fake: ModelConnector, @unchecked Sendable {
        var sent: [ModelRequest] = []
        var models: [String] = []
        var replies: [String]
        var truncated = false
        var errors: [Error] = []

        init(_ replies: String...) { self.replies = replies.isEmpty ? ["ok"] : replies }

        func send(_ request: ModelRequest, model: String) async throws -> ModelReply {
            sent.append(request)
            models.append(model)
            if !errors.isEmpty { throw errors.removeFirst() }
            let text = replies.count > 1 ? replies.removeFirst() : replies[0]
            return ModelReply(text: text, truncated: truncated, usage: ModelUsage(input: 100, output: 10))
        }
    }

    private func gateway(_ root: URL, _ fake: Fake, preset: ProviderPreset = .claude, structured: Bool? = nil) -> ModelGateway {
        var settings = preset.apply(to: ModelSettings(providers: [], roles: [:]), providerID: preset.id, available: [])
        if let structured { settings.providers[0].structuredOutput = structured }
        var gateway = ModelGateway(settings: settings, root: root, device: "mac", key: { _ in "test-key" })
        gateway.makeConnector = { _ in fake }
        return gateway
    }

    // MARK: Presets

    @Test("every preset has a name and a way to reach it; cloud ones say where to get a key")
    func presetsComplete() {
        let ids = ProviderPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for preset in ProviderPreset.all {
            #expect(!preset.name.isEmpty && !preset.blurb.isEmpty)
            if preset.kind == .openAICompatible && preset.id != ProviderPreset.custom.id {
                #expect(preset.baseURL.flatMap(URL.init(string:))?.host != nil, "\(preset.id) has an address")
            }
            if preset.needsKey { #expect(preset.keyURL?.hasPrefix("https://") == true, "\(preset.id) links to its keys") }
            if preset.local { #expect(preset.provider(id: preset.id).isLocal, "\(preset.id) runs on this device") }
        }
        #expect(ProviderPreset.all.contains { $0.kind == .anthropic } && ProviderPreset.all.contains { $0.kind == .appleOnDevice })
        #expect(ProviderPreset.all.filter(\.local).count >= 3)
    }

    @Test("a provider saved before presets is recognized from its address")
    func recognizedFromAddress() {
        func preset(_ url: String) -> String? {
            ProviderPreset.of(ModelProvider(id: "added", kind: .openAICompatible, baseURL: url))?.id
        }
        #expect(preset("https://api.openai.com/v1") == ProviderPreset.openAI.id)
        #expect(preset("https://generativelanguage.googleapis.com/v1beta/openai/") == ProviderPreset.gemini.id)
        #expect(preset("https://openrouter.ai/api/v1") == ProviderPreset.openRouter.id)
        #expect(preset("http://localhost:11434/v1") == ProviderPreset.ollama.id)
        #expect(preset("http://127.0.0.1:1234/v1") == ProviderPreset.lmStudio.id)
        #expect(preset("https://llm.example.com/v1") == nil)
        #expect(ProviderPreset.of(ModelProvider(id: "claude", kind: .anthropic))?.id == ProviderPreset.claude.id)
        #expect(ProviderPreset.of(ModelProvider(id: "apple", kind: .appleOnDevice))?.id == ProviderPreset.apple.id)
        // A saved preset id wins over the address.
        #expect(ProviderPreset.of(ModelProvider(id: "x", kind: .openAICompatible, baseURL: "https://llm.example.com/v1", preset: "groq"))?.id == "groq")
    }

    @Test("picking a model: the suggestion when it's offered, else one that fits the role, else the first")
    func picking() {
        let openAI = ProviderPreset.openAI
        let offered = [openAI.suggested[.fast]!, openAI.suggested[.everyday]!, openAI.suggested[.deep]!, "gpt-4.1"]
        for role in ModelRole.allCases { #expect(openAI.pick(role, from: offered) == openAI.suggested[role]) }

        let later = ["text-embedding-9", "whisper-9", "gpt-9-mini", "gpt-9", "gpt-9-pro"]
        #expect(openAI.pick(.fast, from: later) == "gpt-9-mini")
        #expect(openAI.pick(.everyday, from: later) == "gpt-9")
        #expect(openAI.pick(.deep, from: later) == "gpt-9-pro")

        #expect(ProviderPreset.ollama.pick(.everyday, from: ["qwen3:8b"]) == "qwen3:8b")
        #expect(ProviderPreset.ollama.pick(.fast, from: []) == nil)
        // Nothing listed (the list couldn't be read): the suggestion, if there is one.
        #expect(openAI.pick(.deep, from: []) == openAI.suggested[.deep])
    }

    @Test("choosing a provider puts every role on it and keeps the other providers")
    func applying() {
        let settings = ProviderPreset.openAI.apply(to: .defaults, providerID: "openai", available: [])
        #expect(settings.providers.map(\.id).contains("claude") && settings.provider("openai")?.preset == "openai")
        #expect(ModelRole.allCases.allSatisfy { settings.roles[$0]?.provider == "openai" })
        #expect(settings.roles[.deep]?.model == ProviderPreset.openAI.suggested[.deep])
        #expect(settings.localRoles.isEmpty)

        // A model on this Mac can talk about local-only projects too.
        let local = ProviderPreset.ollama.apply(to: .defaults, providerID: "ollama", available: ["llama4:8b"])
        #expect(ModelRole.allCases.allSatisfy { local.roles[$0]?.model == "llama4:8b" && local.localRoles[$0]?.provider == "ollama" })
    }

    @Test("connecting a preset again reuses its provider; another server gets its own id")
    func providerIDs() {
        var settings = ModelSettings.defaults
        #expect(settings.providerID(for: .claude) == "claude")
        #expect(settings.providerID(for: .openAI) == "openai")
        settings = ProviderPreset.openAI.apply(to: settings, providerID: "openai", available: [])
        #expect(settings.providerID(for: .openAI) == "openai")
        // One added by hand before presets existed is recognized by its address.
        settings.add(ModelProvider(id: "my-ollama", kind: .openAICompatible, baseURL: "http://localhost:11434/v1", local: true))
        #expect(settings.providerID(for: .ollama) == "my-ollama")
        #expect(settings.providerID(for: .custom) == "custom")
        settings.add(ProviderPreset.custom.provider(id: "custom", baseURL: "https://llm.example.com/v1"))
        #expect(settings.providerID(for: .custom) != "custom")
    }

    @Test("a server added by hand keeps its name, and takes local-only work when it runs on this Mac")
    func customServer() {
        var provider = ProviderPreset.custom.provider(id: "custom", baseURL: "http://127.0.0.1:8080/v1")
        provider.name = "llama.cpp"
        provider.local = true
        let settings = ProviderPreset.custom.apply(to: .defaults, provider: provider, available: ["qwen3"])
        #expect(settings.provider("custom")?.displayName == "llama.cpp")
        #expect(settings.roles[.everyday]?.model == "qwen3" && settings.localRoles[.everyday]?.model == "qwen3")
        #expect(!ModelProvider(id: "x", kind: .openAICompatible, baseURL: "https://llm.example.com/v1").needsKey)
    }

    @Test("ready to talk: a cloud provider needs its key, a local one doesn't")
    func readiness() {
        let cloud = ProviderPreset.gemini.apply(to: ModelSettings(providers: [], roles: [:]), providerID: "gemini", available: [])
        #expect(!ModelSetup.ready(cloud, hasKey: { _ in false }, appleAvailable: false))
        #expect(ModelSetup.ready(cloud, hasKey: { $0 == "gemini" }, appleAvailable: false))
        let local = ProviderPreset.lmStudio.apply(to: ModelSettings(providers: [], roles: [:]), providerID: "lm-studio", available: ["m"])
        #expect(ModelSetup.ready(local, hasKey: { _ in false }, appleAvailable: false))
        #expect(!ModelSetup.ready(.defaults, hasKey: { _ in false }, appleAvailable: false))
        #expect(ModelSetup.ready(.defaults, hasKey: { $0 == "claude" }, appleAvailable: false))
    }

    @Test("a provider saved by an older version still reads, and the new fields don't break older versions")
    func providerFormat() throws {
        let old = try JSONDecoder().decode(ModelProvider.self, from: Data(#"{"id":"ollama","kind":"openai","baseURL":"http://localhost:11434/v1","local":true,"capabilities":[]}"#.utf8))
        #expect(old.preset == nil && ProviderPreset.of(old)?.id == "ollama")
        let new = ProviderPreset.groq.provider(id: "groq")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(new)) as? [String: Any]
        // Capabilities stay among the values older versions know, so they can still read config.json.
        let known: Set<String> = ["images", "pdfs", "caching"]
        let saved = Set(json?["capabilities"] as? [String] ?? [])
        #expect(saved.isSubset(of: known))
        #expect(try JSONDecoder().decode(ModelProvider.self, from: JSONEncoder().encode(new)) == new)
    }

    // MARK: Structured replies

    @Test("JSON is read even when a model wraps it in a code fence or a sentence")
    func lenientJSON() throws {
        struct Reply: Decodable, Equatable { var title: String }
        for text in [#"{"title":"A"}"#, "```json\n{\"title\":\"A\"}\n```", "Here you go:\n{\"title\": \"A\"}\nHope that helps."] {
            #expect(try ModelJSON.decode(Reply.self, from: text) == Reply(title: "A"))
        }
        #expect(throws: (any Error).self) { try ModelJSON.decode(Reply.self, from: "no json here") }
    }

    static let titleSchema: [String: Any] = ["type": "object", "properties": ["title": ["type": "string"]], "required": ["title"]]
    struct Titled: Decodable { var title: String }

    @Test("a provider that can constrain replies gets the schema as a constraint")
    func schemaAsConstraint() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake(#"{"title":"Done"}"#)
        let request = ModelRequest(system: "Name it.", messages: [ModelMessage(role: .user, text: "x")])
        let (value, _) = try await gateway(root, fake, preset: .openAI)
            .sendJSON(Titled.self, request, schema: Self.titleSchema, role: .fast, project: nil, task: "filing")
        #expect(value.title == "Done")
        #expect(fake.sent[0].schemaJSON != nil && fake.sent[0].system == "Name it.")
    }

    @Test("a provider that can't gets the schema in its instructions")
    func schemaInInstructions() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake("```json\n{\"title\":\"Done\"}\n```")
        let request = ModelRequest(system: "Name it.", messages: [ModelMessage(role: .user, text: "x")])
        let (value, _) = try await gateway(root, fake, preset: .deepSeek)
            .sendJSON(Titled.self, request, schema: Self.titleSchema, role: .fast, project: nil, task: "filing")
        #expect(value.title == "Done")
        #expect(fake.sent[0].schemaJSON == nil)
        #expect(fake.sent[0].system.hasPrefix("Name it.") && fake.sent[0].system.contains("\"title\""))
    }

    @Test("a server that rejects the constraint is asked once more with the schema in its instructions")
    func schemaRejected() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake(#"{"title":"Done"}"#)
        fake.errors = [ModelFailure.http(400, "response_format json_schema is not supported for this model")]
        let request = ModelRequest(system: "Name it.", messages: [ModelMessage(role: .user, text: "x")])
        let (value, _) = try await gateway(root, fake, preset: .openRouter, structured: true)
            .sendJSON(Titled.self, request, schema: Self.titleSchema, role: .fast, project: nil, task: "filing")
        #expect(value.title == "Done" && fake.sent.count == 2)
        #expect(fake.sent[0].schemaJSON != nil && fake.sent[1].schemaJSON == nil && fake.sent[1].system.contains("\"title\""))
        #expect(UsageLog.entries(root: root).count == 1)
    }

    @Test("a JSON reply cut off at the length limit is an error, not half an object")
    func truncatedJSON() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake(#"{"title":"Do"#)
        fake.truncated = true
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "x")])
        await #expect(throws: ModelFailure.truncated) {
            _ = try await gateway(root, fake).sendJSON(Titled.self, request, schema: Self.titleSchema, role: .fast, project: nil, task: "t")
        }
    }

    @Test("a rejected key says which provider and where to fix it")
    func rejectedKey() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake()
        fake.errors = [ModelFailure.http(401, "invalid api key")]
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "x")])
        do {
            _ = try await gateway(root, fake, preset: .mistral).send(request, role: .everyday, project: nil)
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("Mistral") && error.localizedDescription.contains("Settings › Models"))
        }
    }

    // MARK: Every feature through the gateway

    @Test("filing a note runs on the fast model, as structured output")
    func filing() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake(#"{"action":"note","project":"launch site","kind":"todo","title":"Fix the footer","body":"","priority":"normal","tags":[],"session_kind":"","session_title":""}"#)
        let request = Interpreter.Request(text: "launch site todo fix the footer", spoken: true, projects: ["launch site"],
                                          activeSession: nil, context: ItemContext(), attachmentCount: 0)
        let result = try await Interpreter.interpret(request, gateway: gateway(root, fake, preset: .gemini))
        #expect(result.kind == "todo" && result.project == "launch site")
        let entry = try #require(UsageLog.entries(root: root).first)
        #expect(entry.role == .fast && entry.task == "filing" && entry.provider == "gemini")
    }

    @Test("a session report reads the screenshots, or is written from the text when the model can't see")
    func reports() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(id: "s1", folder: root, project: "launch site", kind: .qa, title: "Checkout test", started: Date(),
                              ended: nil, entries: [SessionEntry(time: Date(), text: "the pay button is grey", attachments: ["shots/a.png"])])
        let images = ["shots/a.png": (data: Data([1, 2, 3]), mediaType: "image/png")]
        let json = ##"{"report_markdown":"# Report","issues":[]}"##

        let seeing = Fake(json)
        _ = try await ReportWriter.write(session, images: images, gateway: gateway(root, seeing, preset: .openAI))
        #expect(seeing.sent[0].needs.contains(.images))

        let blind = Fake(json)
        let report = try await ReportWriter.write(session, images: images, gateway: gateway(root, blind, preset: .deepSeek))
        #expect(report.reportMarkdown == "# Report")
        #expect(!blind.sent[0].needs.contains(.images) && blind.sent[0].messages[0].text.contains("1 screenshot"))
        #expect(UsageLog.entries(root: root).allSatisfy { $0.role == .everyday && $0.task == "report" })
    }

    @Test("help with a screenshot needs a model that reads images, and says so")
    func screenHelp() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake("The build fails because the key is missing.")
        let text = try await ScreenHelp.help(screenshot: Data([1]), mediaType: "image/png", context: ItemContext(app: "Xcode"),
                                             page: nil, question: nil, gateway: gateway(root, fake, preset: .claude), project: nil)
        #expect(text.hasPrefix("The build fails") && fake.sent[0].needs.contains(.images))
        await #expect(throws: ModelRouter.Refusal.cantRead(.images)) {
            _ = try await ScreenHelp.help(screenshot: Data([1]), mediaType: "image/png", context: ItemContext(), page: nil,
                                          question: nil, gateway: gateway(root, Fake(), preset: .groq), project: nil)
        }
    }

    @Test("call notes and project pages run on the everyday model")
    func everydayWork() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        var call = CallTranscript(started: Date())
        call.lines = [.init(time: Date(), speaker: .them, text: "Ship Friday?")]
        let notes = try await call.notes(project: nil, page: nil, gateway: gateway(root, Fake(
            #"{"title":"Ship date","summary_markdown":"Friday.","decisions":["Ship Friday"],"action_items":[],"follow_ups":[]}"#), preset: .mistral))
        #expect(notes.decisions == ["Ship Friday"])

        let ref = NoteRef(id: "n1", project: "launch site", kind: .todo, title: "Fix the footer", body: "", date: Date(), open: true,
                          file: root.appendingPathComponent("n1.md"))
        let page = try await ProjectPageBuilder.compile(project: "launch site", refs: [ref], previous: nil, gateway: gateway(root, Fake(
            #"{"summary":"Nearly there.","where_it_stands":[],"open_bugs":[],"todos":[{"text":"Fix the footer","cites":["n1","made-up"]}],"ideas":[],"decisions":[],"open_questions":[],"actions":[]}"#), preset: .openAI))
        #expect(page.summary == "Nearly there." && page.sections.first { $0.title == "To do" }?.lines.first?.cites == ["n1"])
        #expect(Set(UsageLog.entries(root: root).compactMap(\.task)) == Set(["call", "page"]))
        #expect(UsageLog.entries(root: root).allSatisfy { $0.role == .everyday })
    }

    @Test("Ask answers through the gateway, and a question about a local-only project never leaves the device")
    func asking() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = [NoteRef(id: "n1", project: "launch site", kind: .note, title: "Launch on Friday", body: "", date: Date(), open: true,
                            file: root.appendingPathComponent("n1.md")),
                    NoteRef(id: "n2", project: "diary", kind: .note, title: "Private plans for Friday", body: "", date: Date(), open: true,
                            file: root.appendingPathComponent("n2.md"))]
        let catalog = ProjectCatalog(projects: ["launch site", "diary"].map { Project(name: $0) })
        let fake = Fake(#"{"answer_markdown":"Friday [[n1]]."}"#)
        let answer = try await Ask.answer("what is happening on Friday?", index: NotesIndex(refs), catalog: catalog, pages: [],
                                          gateway: gateway(root, fake, preset: .openRouter), localOnly: ["diary"])
        #expect(answer.usedAI && answer.sources.map(\.id) == ["n1"])
        #expect(!fake.sent[0].messages[0].text.contains("Private plans"))

        let quiet = Fake()
        _ = try await Ask.answer("what are my diary plans for Friday?", index: NotesIndex(refs), catalog: catalog, pages: [],
                                 gateway: gateway(root, quiet, preset: .openRouter), localOnly: ["diary"])
        #expect(quiet.sent.isEmpty)
    }

    @Test("local-only work is refused before anything is sent when only cloud models are set up")
    func localOnlyEverywhere() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = Fake()
        let gw = gateway(root, fake, preset: .openAI)
        let session = Session(id: "s", folder: root, project: "diary", kind: .general, title: "t", started: Date(), ended: nil,
                              entries: [SessionEntry(time: Date(), text: "secret")])
        await #expect(throws: ModelRouter.Refusal.self) { _ = try await ReportWriter.write(session, images: [:], gateway: gw, localOnly: true) }
        await #expect(throws: ModelRouter.Refusal.self) {
            _ = try await ScreenHelp.help(screenshot: Data([1]), mediaType: "image/png", context: ItemContext(), page: nil, question: nil,
                                          gateway: gw, project: "diary", localOnly: true)
        }
        var call = CallTranscript()
        call.lines = [.init(time: Date(), speaker: .you, text: "secret")]
        await #expect(throws: ModelRouter.Refusal.self) { _ = try await call.notes(project: "diary", page: nil, gateway: gw, localOnly: true) }
        #expect(fake.sent.isEmpty)
    }

    // MARK: Wire

    @Test("Anthropic: its own address gets its extras; another address gets plain Messages API calls")
    func anthropicAddresses() async throws {
        final class Captured: @unchecked Sendable { var requests: [URLRequest] = [] }
        let captured = Captured()
        let reply = Data(#"{"content":[{"type":"text","text":"Hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#.utf8)
        let transport: ModelTransport = { request in
            captured.requests.append(request)
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let request = ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "x")])
        _ = try await AnthropicConnector(apiKey: "k", transport: transport).send(request, model: "claude-sonnet-5-5")
        _ = try await AnthropicConnector(apiKey: "k", baseURL: "https://gateway.example.com/anthropic", transport: transport)
            .send(request, model: "claude-sonnet-5-5")
        #expect(captured.requests[0].url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(captured.requests[0].value(forHTTPHeaderField: "anthropic-beta") != nil)
        #expect(captured.requests[1].url?.absoluteString == "https://gateway.example.com/anthropic/v1/messages")
        #expect(captured.requests[1].value(forHTTPHeaderField: "anthropic-beta") == nil)
        let body = try JSONSerialization.jsonObject(with: captured.requests[1].httpBody ?? Data()) as? [String: Any]
        #expect(body?["fallbacks"] == nil && captured.requests[1].value(forHTTPHeaderField: "x-api-key") == "k")
    }

    @Test("OpenAI-compatible: the key is a bearer token and the address ends in chat/completions")
    func openAIAddresses() async throws {
        final class Captured: @unchecked Sendable { var request: URLRequest? }
        let captured = Captured()
        let transport: ModelTransport = { request in
            captured.request = request
            let data = Data(#"{"choices":[{"message":{"content":"Hi"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let connector = OpenAICompatibleConnector(baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/")!,
                                                  apiKey: "k", transport: transport)
        _ = try await connector.send(ModelRequest(system: "s", messages: [ModelMessage(role: .user, text: "x")]), model: "m")
        #expect(captured.request?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(captured.request?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test("model lists are read from Anthropic and OpenAI-compatible replies")
    func modelLists() {
        #expect(AnthropicConnector.parseModels(Data(#"{"data":[{"id":"claude-sonnet-5-5","type":"model"},{"id":"claude-haiku-5-5","type":"model"}]}"#.utf8))
                == ["claude-haiku-5-5", "claude-sonnet-5-5"])
        #expect(OpenAICompatibleConnector.parseModels(Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)) == ["a", "b"])
    }
}
