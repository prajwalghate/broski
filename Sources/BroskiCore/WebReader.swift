import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// A web page as Broski read it: its readable text, cut to a budget.
public struct WebPage: Equatable, Sendable {
    public var url: URL
    public var title: String
    public var text: String
    /// Cut to fit the budget.
    public var truncated: Bool
    public var fetched: Date

    public init(url: URL, title: String, text: String, truncated: Bool, fetched: Date) {
        self.url = url
        self.title = title
        self.text = text
        self.truncated = truncated
        self.fetched = fetched
    }

    public var words: Int { text.split { $0.isWhitespace }.count }
}

/// Links you share: Broski opens the page on this device (nothing goes through a model to fetch it), keeps its
/// readable text, and sends that with your message, fenced as data. A page that needs JavaScript is rendered in a
/// hidden browser that keeps no cookies. A whole site is read only when you ask, a few pages at most. Nothing behind
/// a login, never an address with a password in it.
public enum WebReader {
    public enum Failure: Error, Equatable, LocalizedError {
        case notWeb, credentials, http(Int), tooBig, unreadable, empty

        public var errorDescription: String? {
            switch self {
            case .notWeb: return "it isn't a web address"
            case .credentials: return "the address has a password in it"
            case .http(401), .http(403): return "it needs a login"
            case .http(404), .http(410): return "the page isn't there"
            case .http(let status): return "the site answered \(status)"
            case .tooBig: return "it's too large"
            case .unreadable: return "it couldn't be opened"
            case .empty: return "there's no readable text on it"
            }
        }
    }

    public struct Fetched: Sendable {
        public var url: URL
        public var status: Int
        public var contentType: String
        public var data: Data

        public init(url: URL, status: Int, contentType: String, data: Data) {
            self.url = url
            self.status = status
            self.contentType = contentType
            self.data = data
        }
    }

    public typealias Fetch = @Sendable (URL) async throws -> Fetched
    /// A rendered page's title, a blank line, then its visible text; nil when it couldn't be rendered.
    public typealias Render = @Sendable (URL) async -> String?

    public enum Result: Sendable {
        case page(WebPage)
        case pdf(URL, Data)
    }

    /// About 15,000 tokens for a page you share; 4,000 for each page of a site; ten pages at most.
    public static let pageTokens = 15_000
    public static let sitePageTokens = 4_000
    public static let sitePages = 10
    static let maxBytes = 30_000_000

    // MARK: Reading

    static func check(_ url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw Failure.notWeb }
        guard url.user == nil, url.password == nil else { throw Failure.credentials }
    }

    public static func read(_ url: URL, fetch: Fetch, render: Render?, tokens: Int = pageTokens, at date: Date = Date()) async throws -> Result {
        try check(url)
        let fetched: Fetched
        do { fetched = try await fetch(url) } catch let failure as Failure { throw failure } catch { throw Failure.unreadable }
        guard (200..<300).contains(fetched.status) else { throw Failure.http(fetched.status) }
        guard fetched.data.count <= maxBytes else { throw Failure.tooBig }
        if fetched.contentType.lowercased().contains("pdf") || fetched.data.starts(with: Data("%PDF".utf8)) {
            return .pdf(fetched.url, fetched.data)
        }
        let body = String(data: fetched.data, encoding: .utf8) ?? String(data: fetched.data, encoding: .isoLatin1) ?? ""
        var page = fetched.contentType.lowercased().hasPrefix("text/plain")
            ? plain(body, url: fetched.url, tokens: tokens, at: date)
            : extract(html: body, url: fetched.url, at: date, tokens: tokens)
        // An app shell (the text is drawn by JavaScript): render it.
        if page.words < 80, let render, let rendered = await render(fetched.url) {
            let parts = rendered.components(separatedBy: "\n\n")
            let title = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let renderedPage = plain(parts.dropFirst().joined(separator: "\n\n"), url: fetched.url, tokens: tokens, at: date,
                                     title: title.isEmpty ? page.title : title)
            if renderedPage.words > page.words { page = renderedPage }
        }
        guard !page.text.isEmpty else { throw Failure.empty }
        return .page(page)
    }

    /// The start page and the pages it links to in the same section of the site, breadth first, up to `pages`.
    public static func readSite(_ start: URL, fetch: Fetch, render: Render?, pages: Int = sitePages,
                                tokens: Int = sitePageTokens, at date: Date = Date()) async -> [WebPage] {
        guard (try? check(start)) != nil else { return [] }
        // "…/docs/" is a section: read within it. "…/docs/intro" is a page: read within its folder.
        let within = start.absoluteString.hasSuffix("/") ? start : start.deletingLastPathComponent()
        var queue = [start]
        var seen: Set<String> = [key(start)]
        var read: [WebPage] = []
        while !queue.isEmpty, read.count < pages {
            let url = queue.removeFirst()
            guard let fetched = try? await fetch(url), (200..<300).contains(fetched.status), fetched.data.count <= maxBytes,
                  !fetched.contentType.lowercased().contains("pdf"),
                  let html = String(data: fetched.data, encoding: .utf8) ?? String(data: fetched.data, encoding: .isoLatin1) else { continue }
            var page = extract(html: html, url: fetched.url, at: date, tokens: tokens)
            if page.words < 80, let render, let rendered = await render(fetched.url) {
                let parts = rendered.components(separatedBy: "\n\n")
                page = plain(parts.dropFirst().joined(separator: "\n\n"), url: fetched.url, tokens: tokens, at: date,
                             title: parts.first ?? page.title)
            }
            if !page.text.isEmpty { read.append(page) }
            for link in links(inHTML: html, base: fetched.url, within: within) where !seen.contains(key(link)) {
                seen.insert(key(link))
                queue.append(link)
            }
        }
        return withoutRepeats(read)
    }

    /// A site's menus and footers, sent once: lines that appear on most of its pages (three or more pages read) are
    /// dropped from every page after the first.
    static func withoutRepeats(_ pages: [WebPage]) -> [WebPage] {
        guard pages.count >= 3 else { return pages }
        var counts: [String: Int] = [:]
        for page in pages {
            for line in Set(page.text.components(separatedBy: "\n").filter { !$0.isEmpty }) { counts[line, default: 0] += 1 }
        }
        let repeated = Set(counts.filter { Double($0.value) >= Double(pages.count) * 0.6 }.keys)
        guard !repeated.isEmpty else { return pages }
        return pages.enumerated().map { index, page in
            guard index > 0 else { return page }
            var copy = page
            copy.text = page.text.components(separatedBy: "\n").filter { !repeated.contains($0) }.joined(separator: "\n")
                .replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
    }

    private static func key(_ url: URL) -> String {
        var text = url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }

    // MARK: Text from HTML

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns here are constants; a typo shows up in the tests.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let match = regex(pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The page's readable text: its article (or main part, or body) without scripts, styles, menus, headers,
    /// footers and forms; blocks on their own lines, list items as "- …", entities decoded.
    public static func extract(html: String, url: URL, at date: Date = Date(), tokens: Int = pageTokens) -> WebPage {
        let title = decode(first(#"<title[^>]*>(.*?)</title>"#, in: html)
            ?? first(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)["']"#, in: html) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var text = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head"] {
            text = replacing("<\(tag)\\b.*?</\(tag)\\s*>", in: text, with: " ")
        }
        text = replacing("<!--.*?-->", in: text, with: " ")
        let articles = regex(#"<article\b[^>]*>(.*?)</article\s*>"#).matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
        if let longest = articles.max(by: { $0.count < $1.count }) {
            text = longest
        } else if let main = first(#"<main\b[^>]*>(.*)</main\s*>"#, in: text) {
            text = main
        } else if let body = first(#"<body\b[^>]*>(.*)</body\s*>"#, in: text) {
            text = body
        }
        for tag in ["nav", "header", "footer", "aside", "form", "button", "select"] {
            text = replacing("<\(tag)\\b.*?</\(tag)\\s*>", in: text, with: "\n")
        }
        text = replacing(#"<li\b[^>]*>"#, in: text, with: "\n- ")
        text = replacing(#"<(br|hr)\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"</?(p|div|section|h[1-6]|ul|ol|tr|table|blockquote|pre|figure|figcaption|dl|dt|dd)\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"<[^>]+>"#, in: text, with: "")
        text = decode(text)
        return plain(text, url: url, tokens: tokens, at: date, title: title.isEmpty ? (url.host ?? url.absoluteString) : title)
    }

    /// Text as it is: lines trimmed, runs of spaces and blank lines collapsed, cut to the budget.
    static func plain(_ raw: String, url: URL, tokens: Int, at date: Date, title: String? = nil) -> WebPage {
        let lines = raw.components(separatedBy: .newlines).map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        var text = ""
        var blank = false
        for line in lines {
            if line.isEmpty || line == "-" {
                blank = !text.isEmpty
                continue
            }
            if !text.isEmpty { text += blank ? "\n\n" : "\n" }
            text += line
            blank = false
        }
        let limit = tokens * 4
        var truncated = false
        if text.count > limit {
            let cut = text.prefix(limit)
            text = String(cut[..<(cut.lastIndex(where: { $0 == "\n" || $0 == " " }) ?? cut.endIndex)])
            truncated = true
        }
        return WebPage(url: url, title: title ?? url.host ?? url.absoluteString, text: text, truncated: truncated, fetched: date)
    }

    static func decode(_ text: String) -> String {
        var out = text
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&mdash;", "—"),
                                ("&ndash;", "–"), ("&hellip;", "…"), ("&copy;", "©")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        let numeric = regex(#"&#(x?)([0-9a-f]+);"#)
        for match in numeric.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let whole = Range(match.range, in: out), let hexRange = Range(match.range(at: 1), in: out),
                  let digits = Range(match.range(at: 2), in: out),
                  let code = UInt32(out[digits], radix: out[hexRange].isEmpty ? 10 : 16), let scalar = Unicode.Scalar(code) else { continue }
            out.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Links

    private static let skippedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "css", "js", "zip", "dmg",
                                                         "mp4", "mov", "mp3", "woff", "woff2", "xml", "rss", "pdf"]
    private static let skippedWords = ["login", "logout", "signin", "sign-in", "signup", "sign-up", "register", "account", "cart", "checkout"]

    /// The page's links on the same site, in order, once each, without fragments, files or account pages; only those
    /// under `within` when given.
    public static func links(inHTML html: String, base: URL, within: URL?) -> [URL] {
        var seen: Set<String> = []
        return regex(#"<a\b[^>]*?href\s*=\s*["']([^"']+)["']"#).matches(in: html, range: NSRange(html.startIndex..., in: html))
            .compactMap { match -> URL? in
                guard let range = Range(match.range(at: 1), in: html),
                      let resolved = URL(string: decode(String(html[range])).trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
                      var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return nil }
                parts.fragment = nil
                guard let url = parts.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host?.lowercased() == base.host?.lowercased(), url.user == nil,
                      !skippedExtensions.contains(url.pathExtension.lowercased()),
                      !skippedWords.contains(where: { url.path.lowercased().contains($0) }) else { return nil }
                if let within, !url.absoluteString.lowercased().hasPrefix(within.absoluteString.lowercased()) { return nil }
                return seen.insert(key(url)).inserted ? url : nil
            }
    }

    /// You asked for more than the page: "read the docs at …", "go through …", "the whole site", "crawl …".
    public static func wantsSite(_ text: String) -> Bool {
        first(#"\b(go through|read (?:the|their|its) (?:docs|documentation|site|website|blog)|whole (?:site|website|docs)|all (?:the|of the|its) pages|crawl)\b"#,
              in: text) != nil
    }

    // MARK: A message's links

    public struct Note: Equatable, Sendable {
        /// "Read example.com: “Pricing” · 2,400 words"
        public var text: String
        /// Copies kept in the project's resources.
        public var files: [String]
    }

    public struct Outcome: Sendable {
        /// What the model reads with your message.
        public var parts: [ModelPart]
        /// A line in the conversation for each link.
        public var notes: [Note]
    }

    /// Reads each link in a message (a site's pages when you asked for the site), keeps copies with the project when
    /// `keep` (not in private mode), and says what happened to each.
    public static func readAll(_ urls: [URL], site: Bool, project: String?, root: URL, keep: Bool, fetch: Fetch = download,
                               render: Render?, progress: @Sendable (String) async -> Void = { _ in }) async -> Outcome {
        var outcome = Outcome(parts: [], notes: [])
        for url in urls {
            let host = url.host ?? url.absoluteString
            await progress("Reading \(host)…")
            if site {
                let pages = await readSite(url, fetch: fetch, render: render)
                guard !pages.isEmpty else {
                    outcome.parts.append(.text(couldNotRead(url, Failure.empty)))
                    outcome.notes.append(Note(text: "Couldn't read \(host): \(Failure.empty.errorDescription ?? "")", files: []))
                    continue
                }
                let files = keep ? pages.compactMap { try? save($0, project: project, root: root) } : []
                outcome.parts += pages.map(part)
                outcome.notes.append(Note(text: "Read \(pages.count) page\(pages.count == 1 ? "" : "s") of \(host) · \(count(pages.map(\.words).reduce(0, +))) words",
                                          files: files))
                continue
            }
            do {
                switch try await read(url, fetch: fetch, render: render) {
                case .page(let page):
                    let files = keep ? [try? save(page, project: project, root: root)].compactMap { $0 } : []
                    outcome.parts.append(part(page))
                    outcome.notes.append(Note(text: "Read \(host): “\(page.title)” · \(count(page.words)) words\(page.truncated ? ", the first part" : "")",
                                              files: files))
                case .pdf(let pdfURL, let data):
                    let name = pdfURL.lastPathComponent.lowercased().hasSuffix(".pdf") ? pdfURL.lastPathComponent : "\(host).pdf"
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                    let file = temporary.appendingPathComponent(name)
                    try data.write(to: file)
                    if keep, let path = try? Resources.add(file: file, project: project, root: root) {
                        outcome.parts += Resources.parts(for: [path], root: root)
                        outcome.notes.append(Note(text: "Read \(host): \(name)", files: [path]))
                    } else {
                        outcome.parts += Resources.parts(forFiles: [file])
                        outcome.notes.append(Note(text: "Read \(host): \(name)", files: []))
                    }
                }
            } catch {
                let failure = error as? Failure ?? .unreadable
                outcome.parts.append(.text(couldNotRead(url, failure)))
                outcome.notes.append(Note(text: "Couldn't read \(host): \(failure.errorDescription ?? "")", files: []))
            }
        }
        return outcome
    }

    static func couldNotRead(_ url: URL, _ failure: Failure) -> String {
        "(Broski couldn't open \(url.absoluteString): \(failure.errorDescription ?? "unknown error"). Don't guess what it says; say it couldn't be read.)"
    }

    private static func count(_ words: Int) -> String {
        let format = NumberFormatter()
        format.numberStyle = .decimal
        return format.string(from: NSNumber(value: words)) ?? "\(words)"
    }

    /// What the model reads: the page's text, fenced as data.
    public static func part(_ page: WebPage) -> ModelPart {
        let title = page.title.replacingOccurrences(of: "\"", with: "'")
        return .text("<web url=\"\(page.url.absoluteString)\" title=\"\(title)\">\n\(page.text)\(page.truncated ? "\n[The page goes on; this is the first part.]" : "")\n</web>")
    }

    /// Fetches a page the way a browser would ask for it, with no cookies.
    @Sendable
    public static func download(_ url: URL) async throws -> Fetched {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return Fetched(url: http?.url ?? url, status: http?.statusCode ?? 0,
                       contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "", data: data)
    }

    // MARK: Copies in the project's resources

    private static let stamp = ISO8601DateFormatter()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Saves the page as markdown with front matter (format 1) in the project's resources; returns its path.
    public static func save(_ page: WebPage, project: String?, root: URL) throws -> String {
        let folder = Resources.folder(root: root, project: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var host = (page.url.host ?? "page").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let slug = ProjectProposal.slugify(page.title.isEmpty ? page.url.lastPathComponent : page.title).prefix(40)
        let base = "\(dayFormat.string(from: page.fetched))-web-\(ProjectProposal.slugify(host))\(slug.isEmpty ? "" : "-\(slug)")"
        var name = "\(base).md"
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(base)-\(n).md"
            n += 1
        }
        let oneLine = { (text: String) in text.replacingOccurrences(of: "\n", with: " ") }
        let file = """
        ---
        format: 1
        url: \(page.url.absoluteString)
        title: \(oneLine(page.title))
        fetched: \(stamp.string(from: page.fetched))
        truncated: \(page.truncated)
        ---

        \(page.text)

        """
        try file.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        return "\(Resources.relative(project))/\(name)"
    }

    /// A saved page; nil when the file isn't one. Files written before the format line read as format 1.
    public static func load(_ path: String, root: URL) -> WebPage? {
        guard let raw = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), raw.hasPrefix("---\n"),
              let end = raw.range(of: "\n---\n", range: raw.index(raw.startIndex, offsetBy: 3)..<raw.endIndex) else { return nil }
        var fields: [String: String] = [:]
        for line in raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard (fields["format"].flatMap(Int.init) ?? 1) == 1, let url = fields["url"].flatMap(URL.init(string:)) else { return nil }
        return WebPage(url: url, title: fields["title"] ?? "", text: raw[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines),
                       truncated: fields["truncated"] == "true", fetched: fields["fetched"].flatMap(stamp.date(from:)) ?? .distantPast)
    }

    /// Every saved page in the Broski folder, with its path.
    public static func saved(root: URL) -> [(path: String, page: WebPage)] {
        let projects = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("projects").path)) ?? []
        return ([nil] + projects.map(Optional.some)).flatMap { project -> [(String, WebPage)] in
            let folder = Resources.folder(root: root, project: project)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
                let path = "\(Resources.relative(project))/\(name)"
                return load(path, root: root).map { (path, $0) }
            }
        }
    }
}

extension Recall {
    /// Pages you shared, as searchable refs ("web:<path>").
    public static func refs(webPages: [(path: String, page: WebPage)], root: URL) -> [NoteRef] {
        webPages.map { path, page in
            let parts = path.split(separator: "/")
            let project = parts.first == "projects" && parts.count > 1 ? String(parts[1]) : nil
            return NoteRef(id: "web:\(path)", project: project, kind: .note, title: page.title, body: page.text.prefix(4000) + "",
                           date: page.fetched, open: false, file: root.appendingPathComponent(path), source: "web")
        }
    }
}

#if canImport(WebKit)
/// Renders a page that draws its text with JavaScript, in a hidden browser that keeps no cookies or storage, and
/// returns its title, a blank line, and its visible text.
@MainActor
public final class WebRenderer: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?

    public static func render(_ url: URL, timeout: TimeInterval = 20) async -> String? {
        let renderer = WebRenderer()
        return await renderer.load(url, timeout: timeout)
    }

    private func load(_ url: URL, timeout: TimeInterval) async -> String? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 1600), configuration: configuration)
        view.navigationDelegate = self
        self.view = view
        return await withCheckedContinuation { done in
            continuation = done
            view.load(URLRequest(url: url, timeoutInterval: timeout))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(nil)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Give the page's scripts a moment to draw.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // The page's main part when it marks one, else everything visible.
            let script = "var m = document.querySelector('main, article, [role=main]'); "
                + "document.title + '\\n\\n' + ((m && m.innerText.length > 200) ? m.innerText : (document.body ? document.body.innerText : ''))"
            let text = try? await webView.evaluateJavaScript(script) as? String
            finish(text)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func finish(_ text: String?) {
        guard let continuation else { return }
        self.continuation = nil
        view?.stopLoading()
        view?.navigationDelegate = nil
        view = nil
        continuation.resume(returning: text)
    }
}
#endif
