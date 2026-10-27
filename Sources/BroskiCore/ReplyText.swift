import Foundation

/// How a message reads on screen. Replies are markdown, but a SwiftUI Text renders only inline markdown: headings,
/// quotes, list markers and code fences would show as "##", ">", "-" and "```". Those become what they mean, and web
/// addresses become links.
public enum ReplyText {
    /// A reply, an answer or a note body. `atLineStart: false` for a piece that continues a line (after a citation).
    public static func rendered(_ markdown: String, atLineStart: Bool = true) -> AttributedString {
        var shown: [AttributedString] = []
        var inFence = false
        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let startsLine = index > 0 || atLineStart
            // A code fence isn't shown; the lines inside it are, exactly as written.
            if startsLine, raw.range(of: #"^\s{0,3}```"#, options: .regularExpression) != nil {
                inFence.toggle()
                continue
            }
            if inFence {
                var code = AttributedString(raw)
                code.inlinePresentationIntent = .code
                shown.append(code)
                continue
            }
            var line = raw
            var heading = false
            if startsLine {
                if let range = line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) {
                    line.removeSubrange(range)
                    heading = true
                } else if let range = line.range(of: #"^\s{0,3}>\s?"#, options: .regularExpression) {
                    line.removeSubrange(range)
                } else if let range = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
                    let indent = line[range].prefix { $0 == " " || $0 == "\t" }
                    line.replaceSubrange(range, with: indent + "• ")
                }
            }
            var piece = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            if heading {
                for run in piece.runs {
                    piece[run.range].inlinePresentationIntent = (run.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                }
            }
            shown.append(piece)
        }
        var out = AttributedString()
        for (index, line) in shown.enumerated() {
            if index > 0 { out += AttributedString("\n") }
            out += line
        }
        return linked(out)
    }

    /// Your own words: nothing is interpreted (a*b*c keeps its stars), but web addresses are links.
    public static func plain(_ text: String) -> AttributedString {
        linked(AttributedString(text))
    }

    /// Bare web addresses become links; text markdown already linked keeps its link.
    static func linked(_ text: AttributedString) -> AttributedString {
        let string = String(text.characters)
        guard string.contains("."), let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        var out = text
        for match in detector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard let url = match.url, url.scheme == "http" || url.scheme == "https",
                  let range = Range(match.range, in: string) else { continue }
            let start = out.characters.index(out.startIndex, offsetBy: string.distance(from: string.startIndex, to: range.lowerBound))
            let end = out.characters.index(start, offsetBy: string.distance(from: range.lowerBound, to: range.upperBound))
            guard !out[start..<end].runs.contains(where: { $0.link != nil }) else { continue }
            out[start..<end].link = url
        }
        return out
    }
}
