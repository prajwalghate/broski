import Foundation

/// A piece of text you highlighted somewhere, kept with where it came from.
public struct Clip: Equatable, Identifiable {
    public let id: UUID
    public var text: String
    public var source: ItemContext

    public init(text: String, source: ItemContext, id: UUID = UUID()) {
        self.id = id
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = ItemContext(app: source.app, window: source.window, url: source.url)
    }

    /// "Stripe Docs · Safari", linked when there's an address.
    public var sourceLine: String {
        let name = [source.window, source.app].compactMap { $0 }.filter { !$0.isEmpty }.first ?? "somewhere"
        let app = (source.window?.isEmpty == false) ? source.app.map { " · \($0)" } ?? "" : ""
        if let url = source.url, !url.isEmpty { return "[\(name)](\(url))\(app)" }
        return name + app
    }

    /// A markdown blockquote with the source underneath.
    public var markdown: String {
        // Any line break: "\r\n" is one Character and Word uses "\r", so splitting on "\n" left later lines unquoted.
        let quoted = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.isEmpty ? ">" : "> " + $0 }
        return (quoted + [">", "> — " + sourceLine]).joined(separator: "\n")
    }

    public static func markdown(_ clips: [Clip]) -> String {
        clips.map(\.markdown).joined(separator: "\n\n")
    }

    /// A title for a note that's only clips: the start of the first one.
    public static func title(for clips: [Clip]) -> String {
        guard let first = clips.first else { return "" }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
        let short = line.count > 80 ? String(line.prefix(78)).trimmingCharacters(in: .whitespaces) + "…" : line
        return short
    }
}

extension TextTools {
    /// Joins phrases transcribed one pause at a time, so "…the password," + "Also check…"
    /// reads "…the password, also check…".
    public static func joinPhrase(_ previous: String, _ next: String) -> String {
        let a = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        var b = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        let ended = ".!?:\n".contains(a.last!)
        if !ended, let first = b.first, first.isUppercase {
            let word = b.prefix { $0.isLetter || $0 == "'" }
            let keep = word == "I" || word.hasPrefix("I'") || (word.count > 1 && word.allSatisfy(\.isUppercase))
                || (word.count > 1 && word.dropFirst().contains(where: \.isUppercase))
            if !keep { b = first.lowercased() + b.dropFirst() }
        }
        return a + " " + b
    }
}
