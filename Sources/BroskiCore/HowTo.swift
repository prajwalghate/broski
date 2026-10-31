import Foundation

/// Broski explaining itself: a compact guide made from docs/ (HowToGuide.swift, kept in step by the site tests),
/// sent with a message only when it asks how Broski works.
public enum HowTo {
    /// What "How Broski works" in ⌘K says, in Broski's voice.
    public static let overview = """
    Here's how I work. Talk to me about anything you're working on, by typing, the mic or holding fn, and I'll use \
    what I know about you and the project you're on: its page, its brief and the decisions you've saved. When you \
    decide something or name a todo, I offer a card, and nothing is saved until you tap Save. Each project can have a \
    brief: say "let's set up" and the project's name, or ask its Claude Code thread for one. Private mode keeps \
    nothing, and Settings › General › Start fresh lets you pause or clear what I know. ⌘K finds every command, and \
    you can ask me "how do I…" about anything here.
    """

    static let questionStarts = ["how ", "what ", "where ", "can ", "could ", "does ", "do ", "is ", "why ", "which ", "when ", "should "]
    static let askingHow = ["how do i", "how can i", "how does", "how to", "where do i", "where can i", "where is", "can i", "is there a way",
                            "what does", "what happens when", "what happens if", "why does", "why can't i", "why doesn't"]
    static let features = ["private", "vault", "riff", "brief", "tracker", "note", "memory", "remember", "forget", "model", "key",
                           "shortcut", "⌘k", "cmd-k", "command palette", "palette", "voice", "mic", "iphone", "phone", "mcp",
                           "claude code", "save card", "save", "card", "reset", "start fresh", "pause", "settings", "local only",
                           "local-only", "dashboard", "wake word", "fn ", "hold fn", "export", "check-in", "pill", "dictation"]

    /// Whether a message asks how Broski itself works: a question naming Broski, or "how do I…" about one of its
    /// features. A question about the person's own project isn't.
    public static func wanted(_ said: String) -> Bool {
        let text = said.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let question = text.contains("?") || questionStarts.contains { text.hasPrefix($0) }
        guard question else { return false }
        if text.contains("broski") { return true }
        guard askingHow.contains(where: { text.hasPrefix($0) }) else { return false }
        return features.contains { text.contains($0) }
    }
}
