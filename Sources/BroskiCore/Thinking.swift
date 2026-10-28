import Foundation

// MARK: Riff mode

/// Thinking out loud with a model about a project. It knows the project's living page, pushes back,
/// asks the next good question, and at the end turns the conversation into a note.
public struct Riff: Equatable {
    public struct Turn: Equatable, Identifiable {
        public enum Role: String { case you = "user", broski = "assistant" }
        public let id = UUID()
        public var role: Role
        public var text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }

        public static func == (a: Turn, b: Turn) -> Bool { a.id == b.id && a.text == b.text }
    }

    public var project: String?
    public var turns: [Turn] = []

    public init(project: String?) {
        self.project = project
    }

    static func system(page: ProjectPage?, project: String?) -> String {
        var text = """
        You are Broski, a thinking partner for a solo builder. They're riffing out loud (often by voice, so expect \
        transcription slips) about \(project.map { "their project \($0)" } ?? "an idea").

        How to riff:
        - Be a sharp, warm collaborator, not an assistant. Build on their idea, then add one thing they haven't \
          considered: a risk, a simpler path, a sharper framing, or a question that moves it forward.
        - Keep replies short and spoken-friendly: 2–5 sentences, no headings, no bullet walls. One question at a time.
        - Use what you know about the project (below) when it's relevant, and say so ("you noted last week that…").
        - Don't summarize the conversation unless asked. Don't flatter.
        """
        if let page {
            text += "\n\nThe project's living page:\n" + (page.render().components(separatedBy: "\n---\n").last ?? "")
        }
        return text
    }

    /// Broski's next reply, from the deep model. The project page sits in a cached system prompt, so long riffs stay cheap.
    public func reply(page: ProjectPage?, gateway: ModelGateway, localOnly: Bool = false) async throws -> String {
        let messages = turns.map { ModelMessage(role: $0.role == .you ? .user : .assistant, text: $0.text) }
        let request = ModelRequest(system: Self.system(page: page, project: project), messages: messages, maxTokens: 6000,
                                   cacheSystem: page != nil, effort: "medium")
        let (reply, _) = try await gateway.send(request, role: .deep, project: project, localOnly: localOnly, task: "riff")
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public struct WrapUp: Decodable, Equatable {
        public var title: String
        public var summary_markdown: String
        public var ideas: [String]
        public var decisions: [String]
        public var todos: [String]

        public init(title: String, summary_markdown: String, ideas: [String], decisions: [String], todos: [String]) {
            self.title = title
            self.summary_markdown = summary_markdown
            self.ideas = ideas
            self.decisions = decisions
            self.todos = todos
        }
    }

    static let wrapSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["title", "summary_markdown", "ideas", "decisions", "todos"],
        "properties": [
            "title": ["type": "string"], "summary_markdown": ["type": "string"],
            "ideas": ["type": "array", "items": ["type": "string"]],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "todos": ["type": "array", "items": ["type": "string"]],
        ],
    ]

    /// The riff as a note: what you landed on, the ideas worth keeping, and todos to file.
    public func wrapUp(gateway: ModelGateway, localOnly: Bool = false) async throws -> WrapUp {
        let transcript = turns.map { "\($0.role == .you ? "Me" : "Broski"): \($0.text)" }.joined(separator: "\n\n")
        let request = ModelRequest(system: """
            Turn this riff between a builder and their thinking partner into a note they'll want to reread. \
            title: under 70 characters, what the riff was about. summary_markdown: 3–6 sentences on where they \
            landed, in their voice ("I" not "the user"). ideas, decisions, todos: short, concrete, only what they \
            actually said or agreed to. Empty lists are fine.
            """, messages: [ModelMessage(role: .user, text: transcript)], maxTokens: 6000, effort: "low")
        return try await gateway.sendJSON(WrapUp.self, request, schema: Self.wrapSchema, role: .everyday, project: project,
                                          localOnly: localOnly, task: "riff").value
    }

    /// Without a model: the transcript itself becomes the note.
    public var plainNote: (title: String, body: String) {
        let first = turns.first { $0.role == .you }?.text ?? "Riff"
        let title = "Riff: " + String(first.prefix(60))
        return (title, turns.map { "**\($0.role == .you ? "Me" : "Broski"):** \($0.text)" }.joined(separator: "\n\n"))
    }
}

// MARK: Help with this

/// "Help with this": what's on screen, read alongside the project's memory.
public enum ScreenHelp {
    static func system(page: ProjectPage?) -> String {
        var text = """
        You are Broski, the user's companion for their projects. They pressed "Help with this" while looking at \
        their screen (attached). Figure out what they're likely doing and give the single most useful help:
        - An error or stack trace: the likely cause and the fix.
        - A UI they're testing: what looks broken or off, concretely.
        - Docs, an article or a thread: the 2–3 points that matter for their project.
        - Code: what it does and anything suspicious.
        Lead with the answer in one or two sentences, then at most 4 short bullets. If it connects to something in \
        their project notes (below), say so and cite the note id like [[note-id]]. Never invent citations.
        """
        if let page {
            text += "\n\nTheir project's living page:\n" + (page.render().components(separatedBy: "\n---\n").last ?? "")
        }
        return text
    }

    public static func help(screenshot: Data, mediaType: String, context: ItemContext, page: ProjectPage?,
                            question: String?, gateway: ModelGateway, project: String?, localOnly: Bool = false) async throws -> String {
        var note = "Looking at: " + [context.summary, context.url ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
        if let selection = context.selection, !selection.isEmpty { note += "\nSelected text:\n" + selection.prefix(3000) }
        if let question, !question.isEmpty { note += "\nTheir question: \(question)" }
        let request = ModelRequest(system: system(page: page), messages: [ModelMessage(role: .user, parts: [.image(screenshot, mediaType: mediaType), .text(note)])],
                                   maxTokens: 8000, cacheSystem: page != nil, effort: "medium")
        let (reply, _) = try await gateway.send(request, role: .everyday, project: project, localOnly: localOnly, task: "help")
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.truncated ? text + "\n\n(Cut off: the reply hit its length limit.)" : text
    }
}

// MARK: Call notes

/// Notes from a call: who said what (you vs. them), turned into a summary, decisions and action items.
public struct CallTranscript: Equatable {
    public struct Line: Equatable {
        public enum Speaker: String { case you = "Me", them = "Them" }
        public var time: Date
        public var speaker: Speaker
        public var text: String

        public init(time: Date, speaker: Speaker, text: String) {
            self.time = time
            self.speaker = speaker
            self.text = text
        }
    }

    public var started: Date
    public var lines: [Line] = []
    /// Moments you marked during the call.
    public var marks: [Date] = []

    public init(started: Date = Date()) {
        self.started = started
    }

    public var text: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        var out = ""
        for line in lines.sorted(by: { $0.time < $1.time }) {
            let marked = marks.contains { abs($0.timeIntervalSince(line.time)) < 20 }
            out += "[\(f.string(from: line.time))] \(line.speaker.rawValue): \(line.text)\(marked ? "  ★" : "")\n"
        }
        return out
    }

    public struct Notes: Decodable, Equatable {
        public var title: String
        public var summary_markdown: String
        public var decisions: [String]
        public var action_items: [String]
        public var follow_ups: [String]

        public init(title: String, summary_markdown: String, decisions: [String], action_items: [String], follow_ups: [String]) {
            self.title = title
            self.summary_markdown = summary_markdown
            self.decisions = decisions
            self.action_items = action_items
            self.follow_ups = follow_ups
        }
    }

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "required": ["title", "summary_markdown", "decisions", "action_items", "follow_ups"],
        "properties": [
            "title": ["type": "string"], "summary_markdown": ["type": "string"],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "action_items": ["type": "array", "items": ["type": "string"]],
            "follow_ups": ["type": "array", "items": ["type": "string"]],
        ],
    ]

    public func notes(project: String?, page: ProjectPage?, gateway: ModelGateway, localOnly: Bool = false) async throws -> Notes {
        var system = """
        Write notes from this call transcript for a solo builder. "Me" is the user; "Them" is everyone else on the \
        call (one mixed audio track, so "Them" may be several people). Lines marked ★ are moments the user flagged \
        as important: make sure they're covered. title: under 70 characters. summary_markdown: what the call was \
        about and where it landed, 4–8 sentences. decisions: settled points. action_items: concrete next steps, \
        "Me: …" or "Them: …" when clear. follow_ups: open questions. Only what was actually said; transcription may \
        have slips, so don't over-trust odd words.
        """
        if let page { system += "\n\nContext, the project's living page:\n" + (page.render().components(separatedBy: "\n---\n").last ?? "") }
        let request = ModelRequest(system: system, messages: [ModelMessage(role: .user, text: text)], maxTokens: 12000, effort: "medium",
                                   timeout: 180)
        return try await gateway.sendJSON(Notes.self, request, schema: Self.schema, role: .everyday, project: project,
                                          localOnly: localOnly, task: "call").value
    }
}
