import Foundation

/// Claude's models for each role, when Claude is the provider: Haiku for quick background work, Sonnet for everyday
/// work, Opus for thinking with you.
public enum ClaudeModel {
    public static let fast = "claude-haiku-5-5"
    public static let brain = "claude-sonnet-5-5"
    public static let deep = "claude-opus-5-5"
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

    public static func interpret(_ request: Request, gateway: ModelGateway) async throws -> Interpretation {
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
        // Filing is routine, so it runs on the fast model: quick, and cheap on your key.
        let ask = ModelRequest(system: system, messages: [ModelMessage(role: .user, text: lines.joined(separator: "\n"))],
                               maxTokens: 4000, effort: "low", timeout: 90)
        return try await gateway.sendJSON(Interpretation.self, ask, schema: schema, role: .fast, project: nil, task: "filing").value
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

    /// `images` maps attachment paths to their bytes (JPEG or PNG) to show the model. A model that can't read images
    /// writes the report from the captions; a local-only session uses only models on this device.
    public static func write(_ session: Session, images: [String: (data: Data, mediaType: String)], gateway: ModelGateway,
                             localOnly: Bool = false) async throws -> SessionReport {
        func request(showing: Bool, effort: String) -> ModelRequest {
            var parts: [ModelPart] = [.text("Session: \(session.title) (\(session.kind.label)), project: \(session.project ?? "none"), started \(session.started)")]
            var unseen = 0
            for (index, entry) in session.entries.enumerated() {
                var line = "Capture \(index + 1) at \(Session.entryStamp.string(from: entry.time)): \(entry.text.isEmpty ? "(no comment)" : entry.text)"
                if !entry.context.isEmpty { line += "\n  Looking at: \(entry.context.summary) \(entry.context.url ?? "")" }
                if !entry.attachments.isEmpty { line += "\n  Screenshots: " + entry.attachments.joined(separator: ", ") }
                parts.append(.text(line))
                for path in entry.attachments {
                    guard let image = images[path] else { continue }
                    if showing {
                        parts.append(.text("Screenshot \(path):"))
                        parts.append(.image(image.data, mediaType: image.mediaType))
                    } else {
                        unseen += 1
                    }
                }
            }
            if unseen > 0 {
                parts.append(.text("(\(unseen) screenshot\(unseen == 1 ? "" : "s") can't be shown to you: write the report from the captions, and say the screenshots weren't reviewed.)"))
            }
            return ModelRequest(system: system(for: session.kind), messages: [ModelMessage(role: .user, parts: parts)],
                                maxTokens: 16000, effort: effort, timeout: 300)
        }
        func send(showing: Bool) async throws -> SessionReport {
            do {
                return try await gateway.sendJSON(SessionReport.self, request(showing: showing, effort: "medium"), schema: schema, role: .everyday,
                                                  project: session.project, localOnly: localOnly, task: "report").value
            } catch ModelFailure.truncated {
                // Out of room, usually from thinking: once more with less of it, leaving the tokens for the report.
                return try await gateway.sendJSON(SessionReport.self, request(showing: showing, effort: "low"), schema: schema, role: .everyday,
                                                  project: session.project, localOnly: localOnly, task: "report").value
            }
        }
        do {
            return try await send(showing: true)
        } catch ModelRouter.Refusal.cantRead(.images) {
            return try await send(showing: false)
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
