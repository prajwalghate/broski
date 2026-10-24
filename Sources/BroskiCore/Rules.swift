import Foundation

/// Broski's built-in phrase rules: what a capture means when Claude isn't available.
/// Shared by the Mac and iPhone apps so both file notes the same way.
public enum Rules {
    public static let startSession = try! NSRegularExpression(
        pattern: #"^(?:let'?s\s+|please\s+|okay\s+)?(?:start|begin|open|new)\s+(?:a\s+|the\s+)?(qa|q\.a\.|q and a|testing|test|research|meeting|review|bug bash)?\s*session(?:\s+(?:for|on|in)\s+(?:the\s+)?(.+?))?(?:\s+project)?[.!]?$"#,
        options: [.caseInsensitive])
    /// The whole capture has to be the command ("that's it, make the report"): an observation that merely
    /// starts with one ("That's it, the coupon field is broken") is a note, not the end of the session.
    static let endCommand = #"wrap(?:\s+it)?\s+up|(?:end|stop|finish)(?:\s+(?:the|this|my))?(?:\s+\w+){0,2}?\s+session|that['’]?s\s+it|done\s+testing|(?:make|generate|write)(?:\s+(?:me\s+)?(?:the|a))?\s+report"#
    /// Harmless words after the command: "wrap up the QA session", "that's it for this session", "okay, that's it, thanks".
    static let endTail = #"please|now|thanks|thank\s+you|(?:the|this|my)(?:\s+\w+){0,2}?\s+session|for\s+(?:now|today|the\s+day|(?:the|this)\s+session)"#
    public static let endSession = try! NSRegularExpression(
        pattern: #"^(?:(?:okay|ok|so|alright|right|please)[\s,]+)*(?:"# + endCommand
            + #")(?:[\s,.!]+(?:and\s+|then\s+)?(?:"# + endCommand + #"|"# + endTail + #"))*[\s.!?]*$"#,
        options: [.caseInsensitive])
    /// Where a sentence ends: punctuation followed by a space or the end, so "v1.2" and URLs don't split.
    static let sentenceEnd = try! NSRegularExpression(pattern: #"[.!?]+(?=\s|$)|\n"#)

    /// True when the capture is nothing but "wrap up" (or "that's it, thanks"): anything more is an observation
    /// worth keeping in the session, even when Claude reads the whole capture as ending it.
    public static func isOnlyEndCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && endSession.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    public static func interpret(_ text: String, catalog: ProjectCatalog, activeSession: Session?) -> Interpretation {
        let parser = NoteParser(catalog: catalog)
        let range = NSRange(text.startIndex..., in: text)
        let trimmed = TextTools.trimSeparators(text)
        if activeSession != nil, endSession.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return Interpretation(action: "end_session", title: "")
        }
        if let m = startSession.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) {
            let kindWord = Range(m.range(at: 1), in: trimmed).map { trimmed[$0].lowercased() } ?? ""
            let kind: SessionKind = ["qa", "q.a.", "q and a", "testing", "test", "bug bash"].contains(kindWord) ? .qa
                : SessionKind(rawValue: kindWord) ?? .general
            let projectPhrase = Range(m.range(at: 2), in: trimmed).map { String(trimmed[$0]) } ?? ""
            let project = projectPhrase.isEmpty ? "" : (catalog.match(projectPhrase)?.name ?? "")
            return Interpretation(action: "start_session", project: project, title: "", sessionKind: kind.rawValue,
                                  sessionTitle: "\(kind.label) \(Date().formatted(date: .abbreviated, time: .shortened))")
        }
        _ = range
        if case .openDashboard(let project)? = parser.command(in: text) {
            return Interpretation(action: "open_dashboard", project: project?.name ?? "", title: "")
        }
        let note = parser.parse(text)
        if note.cancelled { return Interpretation(action: "cancel", title: "") }
        let project: String
        switch note.destination {
        case .inbox: project = ""
        case .project(let p): project = p.name
        case .newProject(let name): project = name
        }
        // Long captures keep their first sentence as the title and the rest as the body.
        var title = note.body
        var body = ""
        if title.count > 110,
           let stop = sentenceEnd.matches(in: title, range: NSRange(title.startIndex..., in: title))
            .compactMap({ Range($0.range, in: title) })
            .first(where: { (12..<110).contains(title.distance(from: title.startIndex, to: $0.lowerBound)) }) {
            body = TextTools.trimLeadingSeparators(String(title[stop.upperBound...]))
            title = String(title[..<stop.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Interpretation(project: project, kind: note.kind.rawValue, title: title, body: body)
    }
}
