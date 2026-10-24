import AppKit
import BroskiCore
import UniformTypeIdentifiers
import WebKit

/// Something to send out of Broski: a note, a list of notes, a session, or a report.
struct Export {
    var title: String
    var markdown: String
    /// Screenshots and files that belong with it.
    var attachments: [URL]
    /// Folder that relative image paths in `markdown` are relative to.
    var baseFolder: URL?
    /// "owner/repo" when the project's folder is a GitHub checkout.
    var githubRepo: String?
}

enum ExportTarget: String, CaseIterable, Identifiable {
    case copy, claude, chatgpt, github, linear, slack, notion, pdf, markdownFile, share
    var id: String { rawValue }

    var label: String {
        switch self {
        case .copy: return "Copy as Markdown"
        case .claude: return "Ask Claude"
        case .chatgpt: return "Ask ChatGPT"
        case .github: return "GitHub issue"
        case .linear: return "Linear issue"
        case .slack: return "Post to Slack"
        case .notion: return "Notion"
        case .pdf: return "Save as PDF…"
        case .markdownFile: return "Save as Markdown…"
        case .share: return "Share…"
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .claude, .chatgpt: return "sparkles"
        case .github, .linear: return "exclamationmark.bubble"
        case .slack: return "number"
        case .notion: return "doc.richtext"
        case .pdf: return "doc.text"
        case .markdownFile: return "arrow.down.doc"
        case .share: return "square.and.arrow.up"
        }
    }
}

@MainActor
enum Exporter {
    // MARK: Building exports

    static func export(_ item: Item, githubRepo: String?) -> Export {
        Export(title: item.title, markdown: markdown(item), attachments: item.attachmentURLs, baseFolder: item.folder, githubRepo: githubRepo)
    }

    static func export(_ items: [Item], title: String, githubRepo: String?) -> Export {
        var md = "# \(title)\n\n"
        for item in items {
            let box = item.kind == .todo || item.kind == .bug ? (item.isDone ? "[x] " : "[ ] ") : ""
            md += "- \(box)**\(item.title)**"
            if item.kind != .note && item.kind != .todo { md += " _(\(item.kind.label.lowercased()))_" }
            if item.priority >= .high { md += " ‼︎" }
            md += "\n"
            if !item.body.isEmpty { md += item.body.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n") + "\n" }
        }
        return Export(title: title, markdown: md, attachments: items.flatMap(\.attachmentURLs), baseFolder: nil, githubRepo: githubRepo)
    }

    static func export(_ session: Session, githubRepo: String?) -> Export {
        let md = (try? String(contentsOf: session.reportFile, encoding: .utf8)) ?? ReportWriter.basic(session)
        let shots = session.entries.flatMap(\.attachments).map { session.folder.appendingPathComponent($0) }
        return Export(title: session.title, markdown: md, attachments: shots, baseFolder: session.folder, githubRepo: githubRepo)
    }

    static func markdown(_ item: Item) -> String {
        var md = "# \(item.title)\n\n"
        var facts = ["**Type:** \(item.kind.label)", "**Status:** \(item.status.label)"]
        if item.priority != .normal { facts.append("**Priority:** \(item.priority.rawValue)") }
        if let project = item.project { facts.append("**Project:** \(project)") }
        md += facts.joined(separator: " · ") + "\n\n"
        if !item.body.isEmpty { md += item.body + "\n\n" }
        if !item.context.isEmpty {
            md += "**Context:** \(item.context.summary)"
            if let url = item.context.url { md += " — \(url)" }
            md += "\n\n"
            if let selection = item.context.selection {
                md += selection.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            }
        }
        for path in item.attachments { md += "![](\(path))\n" }
        return md
    }

    /// The text sent to Claude or ChatGPT: the content plus a sensible ask.
    static func prompt(for export: Export) -> String {
        """
        I captured this with Broski while working. Help me with it: tighten it up, point out anything missing, \
        and suggest concrete next steps.

        \(export.markdown)
        """
    }

    // MARK: Sending

    /// Returns a short status line for the dashboard banner.
    static func send(_ export: Export, to target: ExportTarget) async -> String {
        switch target {
        case .copy:
            copy(export.markdown)
            return "Copied as Markdown"
        case .claude:
            return openPrompt(prompt(for: export), base: "https://claude.ai/new", name: "Claude")
        case .chatgpt:
            return openPrompt(prompt(for: export), base: "https://chatgpt.com/", name: "ChatGPT")
        case .github:
            guard let repo = export.githubRepo else {
                copy(export.markdown)
                open("https://github.com/issues")
                return "This project's folder isn't a GitHub repo, so the text was copied. Paste it into a new issue."
            }
            return openIssue(export, url: "https://github.com/\(repo)/issues/new", titleKey: "title", bodyKey: "body", name: "GitHub")
        case .linear:
            return openIssue(export, url: "https://linear.new", titleKey: "title", bodyKey: "description", name: "Linear")
        case .slack:
            if let hook = Secrets.get(Secrets.slackWebhook), let url = URL(string: hook) {
                return await postToSlack(export, webhook: url)
            }
            copy(export.markdown)
            open("slack://open")
            return "Copied. Paste it in Slack (add a webhook in Settings › Connections to post directly)."
        case .notion:
            copy(export.markdown)
            if !open("notion://") { open("https://www.notion.so") }
            return "Copied as Markdown. Paste into a Notion page and it keeps the formatting."
        case .pdf:
            return await savePDF(export)
        case .markdownFile:
            return saveMarkdown(export)
        case .share:
            share(export)
            return ""
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @discardableResult
    private static func open(_ address: String) -> Bool {
        guard let url = URL(string: address) else { return false }
        return NSWorkspace.shared.open(url)
    }

    private static func openPrompt(_ prompt: String, base: String, name: String) -> String {
        copy(prompt)
        var components = URLComponents(string: base)!
        if prompt.count <= 6000 { components.queryItems = [URLQueryItem(name: "q", value: prompt)] }
        NSWorkspace.shared.open(components.url!)
        return prompt.count <= 6000 ? "Opened \(name) with the prompt (also copied)" : "Prompt copied. Paste it into \(name)."
    }

    private static func openIssue(_ export: Export, url: String, titleKey: String, bodyKey: String, name: String) -> String {
        // Image paths mean nothing on the web; put the first screenshot on the clipboard to paste in.
        var body = export.markdown.components(separatedBy: "\n").filter { !$0.hasPrefix("![") }.joined(separator: "\n")
        let truncated = body.count > 5500
        if truncated { body = String(body.prefix(5500)) + "\n\n…(full text copied to the clipboard)" }
        var components = URLComponents(string: url)!
        components.queryItems = [URLQueryItem(name: titleKey, value: export.title), URLQueryItem(name: bodyKey, value: body)]
        if let image = export.attachments.first.flatMap({ NSImage(contentsOf: $0) }) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        } else if truncated {
            copy(export.markdown)
        }
        NSWorkspace.shared.open(components.url!)
        return export.attachments.isEmpty ? "Opened a new \(name) issue" : "Opened a new \(name) issue. The screenshot is on the clipboard: paste it in."
    }

    private static func postToSlack(_ export: Export, webhook: URL) async -> String {
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let text = export.markdown
            .replacingOccurrences(of: "**", with: "*")
            .components(separatedBy: "\n").filter { !$0.hasPrefix("![") }.joined(separator: "\n")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            return ok ? "Posted to Slack" : "Slack didn't accept it. Check the webhook in Settings."
        } catch {
            return "Couldn't reach Slack: \(error.localizedDescription)"
        }
    }

    private static func saveMarkdown(_ export: Export) -> String {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = TextTools.slugify(export.title) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        var md = export.markdown
        if let base = export.baseFolder {
            // Point image links at the real files so the saved copy shows them.
            md = md.replacingOccurrences(of: "](attachments/", with: "](\(base.appendingPathComponent("attachments").path)/")
                .replacingOccurrences(of: "](shots/", with: "](\(base.appendingPathComponent("shots").path)/")
        }
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
            return "Saved \(url.lastPathComponent)"
        } catch {
            return "Couldn't save: \(error.localizedDescription)"
        }
    }

    private static func share(_ export: Export) {
        let items: [Any] = [export.markdown] + export.attachments
        let picker = NSSharingServicePicker(items: items)
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }

    // MARK: PDF

    private static var pdfView: WKWebView?
    private static var pdfDelegate: PDFLoadDelegate?

    private static func savePDF(_ export: Export) async -> String {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = TextTools.slugify(export.title) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return "" }
        let html = MarkdownHTML.document(title: export.title, markdown: export.markdown, baseFolder: export.baseFolder)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100))
        let delegate = PDFLoadDelegate()
        pdfView = view
        pdfDelegate = delegate
        view.navigationDelegate = delegate
        view.loadHTMLString(html, baseURL: nil)
        await delegate.loaded()
        defer { pdfView = nil; pdfDelegate = nil }
        do {
            let data = try await view.pdf(configuration: WKPDFConfiguration())
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return "Saved \(url.lastPathComponent)"
        } catch {
            return "Couldn't make the PDF: \(error.localizedDescription)"
        }
    }
}

private final class PDFLoadDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var done = false

    func loaded() async {
        if done { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFinish: navigation)
    }
}

/// Just enough markdown → HTML for Broski's own notes and reports: headings, lists, checkboxes,
/// emphasis, code, links, tables, quotes, and images (embedded so the PDF is self-contained).
enum MarkdownHTML {
    static func document(title: String, markdown: String, baseFolder: URL?) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font: 13px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; color: #1d1d1f; margin: 36px 44px; }
        h1 { font-size: 24px; margin: 0 0 12px; } h2 { font-size: 18px; margin: 22px 0 8px; } h3 { font-size: 15px; margin: 18px 0 6px; }
        img { max-width: 100%; border: 1px solid #ddd; border-radius: 6px; margin: 8px 0; }
        table { border-collapse: collapse; margin: 10px 0; } td, th { border: 1px solid #ddd; padding: 5px 9px; text-align: left; }
        th { background: #f5f5f7; } code { background: #f2f2f4; padding: 1px 4px; border-radius: 4px; font-size: 12px; }
        pre { background: #f2f2f4; padding: 10px; border-radius: 6px; overflow-x: auto; } blockquote { color: #555; border-left: 3px solid #7d4dff; margin: 8px 0; padding-left: 12px; }
        ul { padding-left: 22px; } .done { color: #888; text-decoration: line-through; }
        .footer { margin-top: 32px; color: #999; font-size: 11px; }
        </style></head><body>
        \(body(markdown, baseFolder: baseFolder))
        <div class="footer">Captured with Broski</div>
        </body></html>
        """
    }

    static func body(_ markdown: String, baseFolder: URL?) -> String {
        var html = ""
        var inList = false, inCode = false, inTable = false
        func closeBlocks() {
            if inList { html += "</ul>\n"; inList = false }
            if inTable { html += "</table>\n"; inTable = false }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                closeBlocks()
                html += inCode ? "</pre>\n" : "<pre>"
                inCode.toggle()
                continue
            }
            if inCode { html += escape(raw) + "\n"; continue }
            if line.isEmpty { closeBlocks(); continue }
            if line.hasPrefix("|") {
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { continue }
                if !inTable { closeBlocks(); html += "<table>\n<tr>" + cells.map { "<th>\(inline($0, baseFolder))</th>" }.joined() + "</tr>\n"; inTable = true; continue }
                html += "<tr>" + cells.map { "<td>\(inline($0, baseFolder))</td>" }.joined() + "</tr>\n"
                continue
            }
            if let level = line.prefix(while: { $0 == "#" }).count as Int?, level > 0, level <= 6, line.dropFirst(level).hasPrefix(" ") {
                closeBlocks()
                html += "<h\(level)>\(inline(String(line.dropFirst(level + 1)), baseFolder))</h\(level)>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                if !inList { closeBlocks(); html += "<ul>\n"; inList = true }
                var text = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line
                var cls = ""
                if text.hasPrefix("[ ] ") { text = "☐ " + text.dropFirst(4) }
                if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { text = "☑︎ " + text.dropFirst(4); cls = " class=\"done\"" }
                html += "<li\(cls)>\(inline(text, baseFolder))</li>\n"
            } else if line.hasPrefix("> ") {
                closeBlocks()
                html += "<blockquote>\(inline(String(line.dropFirst(2)), baseFolder))</blockquote>\n"
            } else {
                closeBlocks()
                html += "<p>\(inline(line, baseFolder))</p>\n"
            }
        }
        closeBlocks()
        if inCode { html += "</pre>" }
        return html
    }

    static func inline(_ text: String, _ baseFolder: URL?) -> String {
        var s = escape(text)
        s = replace(#"!\[([^\]]*)\]\(([^)]+)\)"#, in: s) { groups in
            let path = groups[2]
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseFolder?.appendingPathComponent(path)
            guard let url, let data = try? Data(contentsOf: url) else { return "" }
            let type = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg" ? "jpeg" : "png"
            return "<img src=\"data:image/\(type);base64,\(data.base64EncodedString())\" alt=\"\(groups[1])\">"
        }
        s = replace(#"\[([^\]]+)\]\(([^)]+)\)"#, in: s) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        s = replace(#"\*\*([^*]+)\*\*"#, in: s) { "<strong>\($0[1])</strong>" }
        s = replace(#"(?<![*\w])_([^_]+)_(?!\w)"#, in: s) { "<em>\($0[1])</em>" }
        s = replace(#"`([^`]+)`"#, in: s) { "<code>\($0[1])</code>" }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replace(_ pattern: String, in s: String, with build: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        var result = s
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let groups = (0..<match.numberOfRanges).map { i -> String in
                guard let r = Range(match.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
            if let r = Range(match.range, in: result) { result.replaceSubrange(r, with: build(groups)) }
        }
        return result
    }
}
