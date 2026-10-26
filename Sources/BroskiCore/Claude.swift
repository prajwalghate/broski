import Foundation

/// Which Claude does which job: Haiku for quick background work, Sonnet for the brain, Opus for thinking with you.
public enum ClaudeModel {
    public static let fast = "claude-haiku-5-5"
    public static let brain = "claude-sonnet-5-5"
    public static let deep = "claude-opus-5-5"
}

/// Minimal Claude Messages API client over HTTPS (Swift has no official SDK).
public struct ClaudeClient {
    public var apiKey: String
    public var model: String
    /// What calls through this client are for, in the usage log ("page", "filing", "ask"…).
    public var task: String?

    /// Sonnet unless a caller picks otherwise, so nothing lands on Opus by accident.
    public init(apiKey: String, model: String = ClaudeModel.brain, task: String? = nil) {
        self.apiKey = apiKey
        self.model = model
        self.task = task
    }

    /// Called with what each request used (model, task, tokens), so the app logs these calls with the gateway's.
    public nonisolated(unsafe) static var onUsage: (@Sendable (_ model: String, _ task: String?, _ usage: ModelUsage) -> Void)?

    /// The tokens a Messages API response says it used, cache reads and writes included.
    public static func usage(from data: Data) -> ModelUsage? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else { return nil }
        func count(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        return ModelUsage(input: count("input_tokens"), output: count("output_tokens"), cacheRead: count("cache_read_input_tokens"),
                          cacheWrite: count("cache_creation_input_tokens"))
    }

    public enum Failure: LocalizedError {
        case http(Int, String)
        case refused
        case empty
        /// Ran out of max_tokens (thinking counts toward it) before the reply was finished.
        case truncated
        case badResponse(String)

        public var errorDescription: String? {
            switch self {
            case .http(401, _): return "Claude rejected the API key. Check it in Settings › AI."
            case .http(429, _): return "Claude is rate limiting this key. Try again in a moment."
            case .http(let code, let message): return "Claude returned \(code): \(message)"
            case .refused: return "Claude declined this request."
            case .empty: return "Claude sent an empty reply."
            case .truncated: return "Claude's reply hit its length limit before it finished."
            case .badResponse(let detail): return "Couldn't read Claude's reply: \(detail)"
            }
        }
    }

    /// Sends one user turn. `content` is a list of Messages API content blocks.
    /// With `schema`, the reply is constrained to JSON matching it.
    public func send(system: String, content: [[String: Any]], schema: [String: Any]? = nil,
                     effort: String = "low", maxTokens: Int = 4000, timeout: TimeInterval = 90,
                     cacheSystem: Bool = false) async throws -> String {
        try await send(system: system, messages: [["role": "user", "content": content]], schema: schema,
                       effort: effort, maxTokens: maxTokens, timeout: timeout, cacheSystem: cacheSystem)
    }

    /// Sends a whole conversation (`[{"role": "user"|"assistant", "content": …}]`).
    /// `cacheSystem` marks the system prompt for prompt caching, for long prompts reused across turns
    /// (a project page, a riff). Haiku has no server-side fallback, so it's only requested for Sonnet and Opus.
    public func send(system: String, messages: [[String: Any]], schema: [String: Any]? = nil,
                     effort: String = "low", maxTokens: Int = 4000, timeout: TimeInterval = 90,
                     cacheSystem: Bool = false) async throws -> String {
        var outputConfig: [String: Any] = ["effort": effort]
        if let schema { outputConfig["format"] = ["type": "json_schema", "schema": schema] }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": cacheSystem
                ? [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]] as Any
                : system,
            "messages": messages,
            "output_config": outputConfig,
        ]
        let fallback = !model.contains("haiku")
        if fallback { body["fallbacks"] = "default" }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if fallback { request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Billed whether or not the reply turns out usable, so it's logged first.
        if status == 200, let usage = Self.usage(from: data) { Self.onUsage?(model, task, usage) }
        let reply = try Self.parse(data, status: status)
        guard reply.truncated else { return reply.text }
        // Half a JSON object is never usable; half an answer is, as long as it says it's cut off.
        if schema != nil { throw Failure.truncated }
        return reply.text + "\n\n(Cut off: the reply hit its length limit.)"
    }

    /// Reads a Messages API response. `truncated` means Claude stopped at max_tokens, not at the end of its answer.
    public static func parse(_ data: Data, status: Int) throws -> (text: String, truncated: Bool) {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw Failure.http(status, message)
        }
        guard let json else { throw Failure.badResponse("not JSON") }
        let stop = json["stop_reason"] as? String
        if stop == "refusal" { throw Failure.refused }
        let text = ((json["content"] as? [[String: Any]]) ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        let truncated = stop == "max_tokens"
        // Cut off while still thinking leaves no text; say so rather than "empty".
        guard !text.isEmpty else { throw truncated ? Failure.truncated : Failure.empty }
        return (text, truncated)
    }

    /// Decodes a JSON reply sent with a `schema`.
    public func sendJSON<T: Decodable>(_ type: T.Type, system: String, messages: [[String: Any]], schema: [String: Any],
                                       effort: String = "low", maxTokens: Int = 4000, timeout: TimeInterval = 90,
                                       cacheSystem: Bool = false) async throws -> T {
        let reply = try await send(system: system, messages: messages, schema: schema, effort: effort,
                                   maxTokens: maxTokens, timeout: timeout, cacheSystem: cacheSystem)
        do {
            return try JSONDecoder().decode(T.self, from: Data(reply.utf8))
        } catch {
            throw Failure.badResponse(error.localizedDescription)
        }
    }

    /// Checks the key with a tiny request. Thinking counts toward max_tokens, so the cap leaves room for it.
    public func verify() async throws {
        do {
            _ = try await ClaudeClient(apiKey: apiKey, model: ClaudeModel.fast, task: "key-check")
                .send(system: "Reply with OK.", content: [Self.text("ping")], effort: "low", maxTokens: 1024, timeout: 30)
        } catch Failure.empty, Failure.truncated, Failure.refused {
            // Still a 200: the key authenticated and has credit, which is all this checks.
        }
    }

    public static func text(_ string: String) -> [String: Any] {
        ["type": "text", "text": string]
    }

    public static func image(_ data: Data, mediaType: String) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": data.base64EncodedString()]]
    }
}

// MARK: Understanding what you said

/// What Broski should do with something you said or typed.
public struct Interpretation: Codable, Equatable {
    /// "note", "start_session", "end_session", "open_dashboard", or "cancel".
    public var action: String
    /// A project name from the list, a new name, or "" for the inbox.
    public var project: String
    public var kind: String
    public var title: String
    public var body: String
    public var priority: String
    public var tags: [String]
    public var sessionKind: String
    public var sessionTitle: String

    enum CodingKeys: String, CodingKey {
        case action, project, kind, title, body, priority, tags
        case sessionKind = "session_kind"
        case sessionTitle = "session_title"
    }

    public init(action: String = "note", project: String = "", kind: String = "note", title: String, body: String = "",
                priority: String = "normal", tags: [String] = [], sessionKind: String = "", sessionTitle: String = "") {
        self.action = action
        self.project = project
        self.kind = kind
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
        self.sessionKind = sessionKind
        self.sessionTitle = sessionTitle
    }
}

public enum Interpreter {
    public struct Request {
        public var text: String
        public var spoken: Bool
        public var projects: [String]
        public var activeSession: String?
        public var context: ItemContext
        public var attachmentCount: Int

        public init(text: String, spoken: Bool, projects: [String], activeSession: String?, context: ItemContext, attachmentCount: Int) {
            self.text = text
            self.spoken = spoken
            self.projects = projects
            self.activeSession = activeSession
            self.context = context
            self.attachmentCount = attachmentCount
        }
    }

    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["note", "start_session", "end_session", "open_dashboard", "cancel"]],
            "project": ["type": "string"],
            "kind": ["type": "string", "enum": ["note", "idea", "todo", "bug"]],
            "title": ["type": "string"],
            "body": ["type": "string"],
            "priority": ["type": "string", "enum": ["low", "normal", "high", "urgent"]],
            "tags": ["type": "array", "items": ["type": "string"]],
            "session_kind": ["type": "string", "enum": ["", "qa", "research", "meeting", "review", "general"]],
            "session_title": ["type": "string"],
        ],
        "required": ["action", "project", "kind", "title", "body", "priority", "tags", "session_kind", "session_title"],
        "additionalProperties": false,
    ]

    static let system = """
    You are the brain of Broski, a Mac app that captures a developer's thoughts the moment they have them \
    and files them into the right project. You get one capture: something the user said out loud (transcribed, \
    so expect filler words, restarts and misheard names) or typed. Decide what to do and return JSON.

    Actions:
    - "note": the default. Save it as a note in a project or the inbox.
    - "start_session": the user asks to start a session, e.g. "start a QA session for strado", \
    "I'm going to test the login flow", "begin a research session". Set session_kind and a short session_title.
    - "end_session": the user wants to finish the active session or get its report, e.g. "wrap up", \
    "that's it, make the report", "end the session". Only when a session is active.
    - "open_dashboard": the whole capture is a request to see notes, e.g. "open the dashboard", \
    "show me the strado notes". Put the project in "project" if one is named.
    - "cancel": the user takes it back ("never mind", "scratch that") without saying anything worth keeping.

    For notes:
    - project: pick the closest match from the known projects when the user names or clearly means one \
    (spoken names are often misheard: "trading bought" means "trading-bot", "hip three observatory" means \
    "hip3-observatory"). Use the exact name from the list. Use a new short name only if the user explicitly \
    says it's a project that isn't listed. Otherwise "".
    - kind: "todo" for something to do, "bug" for something broken, "idea" for a possibility or feature idea, \
    "note" for anything else (observations, facts, prompts, findings).
    - title: one clear line, at most ~90 characters, in the user's voice. For spoken captures, remove filler, \
    false starts and the routing phrase ("in the strado project, add a todo:"), fix obvious transcription errors, \
    but keep their meaning and any specifics. For typed captures keep their wording; only drop the routing phrase.
    - body: everything else worth keeping (details, steps, a prompt they want to reuse, reasoning), as clean \
    markdown. Empty if the title says it all. Never invent details. If they dictated a prompt or long text \
    to keep, put it in the body verbatim apart from cleanup.
    - priority: "urgent"/"high" only if they say so or it's clearly blocking; "low" if they say it can wait.
    - tags: up to 3 short lowercase topic tags, or none.
    When a session is active, a capture that isn't a command is an observation for that session: \
    use action "note" and set title/body as usual (the app adds it to the session).
    Spoken captures often begin with the wake word "Broski" (or a mishearing like "Brass key", "Bros key", \
    "Brosky"); ignore it.
    Set unused string fields to "" and unused arrays to [].
    """

    public static func interpret(_ request: Request, with client: ClaudeClient) async throws -> Interpretation {
        var lines = [
            "Capture (\(request.spoken ? "spoken, transcribed" : "typed")):",
            request.text,
            "",
            "Known projects: " + (request.projects.isEmpty ? "(none)" : request.projects.joined(separator: ", ")),
            "Active session: " + (request.activeSession ?? "none"),
        ]
        if !request.context.isEmpty {
            lines.append("They were looking at: " + [request.context.summary, request.context.url ?? ""].filter { !$0.isEmpty }.joined(separator: " — "))
        }
        if request.attachmentCount > 0 { lines.append("Screenshots attached: \(request.attachmentCount)") }
        // Filing is routine, so it goes to Haiku: quick, and cheap on your key.
        let fast = ClaudeClient(apiKey: client.apiKey, model: ClaudeModel.fast, task: "filing")
        let reply = try await fast.send(system: system, content: [ClaudeClient.text(lines.joined(separator: "\n"))],
                                        schema: schema, effort: "low", maxTokens: 4000)
        guard let data = reply.data(using: .utf8) else { throw ClaudeClient.Failure.badResponse("encoding") }
        do {
            return try JSONDecoder().decode(Interpretation.self, from: data)
        } catch {
            throw ClaudeClient.Failure.badResponse(error.localizedDescription)
        }
    }
}

// MARK: Session reports

public struct SessionReport: Codable, Equatable {
    public struct Issue: Codable, Equatable {
        public var title: String
        public var severity: String
        public var details: String
        public var screenshot: String
    }

    public var reportMarkdown: String
    public var issues: [Issue]

    enum CodingKeys: String, CodingKey {
        case reportMarkdown = "report_markdown"
        case issues
    }
}

public enum ReportWriter {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "report_markdown": ["type": "string"],
            "issues": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "severity": ["type": "string", "enum": ["low", "medium", "high", "critical"]],
                        "details": ["type": "string"],
                        "screenshot": ["type": "string"],
                    ],
                    "required": ["title", "severity", "details", "screenshot"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["report_markdown", "issues"],
        "additionalProperties": false,
    ]

    static func system(for kind: SessionKind) -> String {
        let shape: String
        switch kind {
        case .qa:
            shape = """
            Write a QA report: a one-paragraph summary, an "Environment" line (apps/sites seen), an issues table \
            (# | issue | severity), then one section per issue with what happened, steps to reproduce when they \
            can be inferred, expected vs actual, and its screenshot. End with "Other observations" for anything \
            that isn't an issue. Also return each issue in "issues".
            """
        case .research:
            shape = "Write research notes: key findings first, then details per topic with sources (URLs seen), then open questions. Return no issues unless something is broken."
        case .meeting:
            shape = "Write meeting notes: summary, decisions, action items (owner if said), then notes. Return action items that are bugs as issues only."
        case .review:
            shape = "Write a review: summary, problems ranked by severity, suggestions. Return each problem in issues."
        case .general:
            shape = "Write a clean, well-organized summary of the session in sections. Return anything broken as issues."
        }
        return """
        You turn a developer's captured session (spoken or typed observations, each possibly with screenshots) \
        into a polished markdown document. Look at the screenshots: describe what they show when it matters. \
        \(shape)
        Embed screenshots with markdown image syntax using exactly the relative paths given (e.g. ![](shots/x.png)). \
        In "issues", "screenshot" is the most relevant path or "". Don't invent facts that aren't in the \
        captures or visible in the screenshots. Fix transcription errors silently.
        """
    }

    /// `images` maps attachment paths to their bytes (JPEG or PNG) to show Claude.
    public static func write(_ session: Session, images: [String: (data: Data, mediaType: String)], with client: ClaudeClient) async throws -> SessionReport {
        // Sonnet reads screenshots and writes reports well; these used to run on Opus by default, at twice the price.
        let client = ClaudeClient(apiKey: client.apiKey, model: ClaudeModel.brain, task: "report")
        var content: [[String: Any]] = [ClaudeClient.text("Session: \(session.title) (\(session.kind.label)), project: \(session.project ?? "none"), started \(session.started)")]
        for (index, entry) in session.entries.enumerated() {
            var line = "Capture \(index + 1) at \(Session.entryStamp.string(from: entry.time)): \(entry.text.isEmpty ? "(no comment)" : entry.text)"
            if !entry.context.isEmpty { line += "\n  Looking at: \(entry.context.summary) \(entry.context.url ?? "")" }
            if !entry.attachments.isEmpty { line += "\n  Screenshots: " + entry.attachments.joined(separator: ", ") }
            content.append(ClaudeClient.text(line))
            for path in entry.attachments {
                guard let image = images[path] else { continue }
                content.append(ClaudeClient.text("Screenshot \(path):"))
                content.append(ClaudeClient.image(image.data, mediaType: image.mediaType))
            }
        }
        let reply: String
        do {
            reply = try await client.send(system: system(for: session.kind), content: content, schema: schema,
                                          effort: "medium", maxTokens: 16000, timeout: 300)
        } catch ClaudeClient.Failure.truncated {
            // Out of room, usually from thinking: once more with less of it, leaving the tokens for the report.
            reply = try await client.send(system: system(for: session.kind), content: content, schema: schema,
                                          effort: "low", maxTokens: 16000, timeout: 300)
        }
        guard let data = reply.data(using: .utf8) else { throw ClaudeClient.Failure.badResponse("encoding") }
        do {
            return try JSONDecoder().decode(SessionReport.self, from: data)
        } catch {
            throw ClaudeClient.Failure.badResponse(error.localizedDescription)
        }
    }

    /// Plain report without AI: every capture in order.
    public static func basic(_ session: Session) -> String {
        var out = "# \(session.title)\n\n\(session.kind.label)"
        if let project = session.project { out += " · \(project)" }
        out += " · \(session.started.formatted(date: .abbreviated, time: .shortened))\n\n"
        for (index, entry) in session.entries.enumerated() {
            out += "## \(index + 1). \(entry.text.split(separator: "\n").first.map(String.init) ?? "Capture")\n\n"
            let rest = entry.text.split(separator: "\n").dropFirst().joined(separator: "\n")
            if !rest.isEmpty { out += rest + "\n\n" }
            if !entry.context.isEmpty { out += "_\(entry.context.summary) \(entry.context.url ?? "")_\n\n" }
            for path in entry.attachments { out += "![](\(path))\n\n" }
        }
        return out
    }
}
