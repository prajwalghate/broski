import AppKit
import BroskiCore

/// Decides what a capture means. Uses Claude when an API key is set; otherwise (or if Claude
/// can't be reached) falls back to Broski's built-in phrase rules, so capturing never blocks on the network.
@MainActor
final class Brain: ObservableObject {
    @Published private(set) var hasKey = Secrets.get(Secrets.claudeKey)?.isEmpty == false
    @Published private(set) var lastProblem: String?
    /// Projects whose notes never go to Claude.
    var localOnly: () -> Set<String> = { [] }

    var client: ClaudeClient? {
        guard let key = Secrets.get(Secrets.claudeKey), !key.isEmpty else { return nil }
        return ClaudeClient(apiKey: key)
    }

    func setKey(_ key: String?) {
        let saved = Secrets.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: Secrets.claudeKey)
        hasKey = client != nil
        lastProblem = saved ? nil : "Couldn't save the key to \(Secrets.file.path). Check that folder's permissions."
    }

    /// Nil when the key works; otherwise what went wrong.
    func verifyKey() async -> String? {
        guard let client else { return "No key saved" }
        do {
            try await client.verify()
            lastProblem = nil
            return nil
        } catch {
            lastProblem = error.localizedDescription
            return error.localizedDescription
        }
    }

    struct Result {
        var interpretation: Interpretation
        var usedAI: Bool
    }

    /// `pinned`: the project picked in the panel, if any.
    func interpret(_ text: String, spoken: Bool, catalog: ProjectCatalog, activeSession: Session?,
                   context: ItemContext, attachmentCount: Int, pinned: String? = nil) async -> Result {
        let ruled = Self.rules(text, catalog: catalog, activeSession: activeSession)
        // A note headed for a local-only project is filed by the rules, so its text never leaves the Mac:
        // named in the text, picked in the panel, or captured during that project's session.
        // The window you captured in counts too: "Xcode · strado — Login.swift" is strado's even if you didn't say so.
        let blocked = localOnly()
        let seen = [text, context.window, context.url].compactMap { $0 }.joined(separator: "\n")
        if LocalOnly.touches(seen, projects: [ruled.project, pinned, activeSession?.project], localOnly: blocked, catalog: catalog) {
            return Result(interpretation: ruled, usedAI: false)
        }
        if let client {
            let request = Interpreter.Request(
                // Claude isn't told local-only projects exist, so it can't file anything into them.
                text: text, spoken: spoken, projects: catalog.projects.map(\.name).filter { !blocked.contains($0) },
                activeSession: activeSession.map { "\($0.kind.label) “\($0.title)” for \($0.project ?? "the inbox")" },
                context: context, attachmentCount: attachmentCount
            )
            do {
                var result = try await Interpreter.interpret(request, with: client)
                result.project = resolveProject(result.project, catalog: catalog)
                lastProblem = nil
                return Result(interpretation: result, usedAI: true)
            } catch where Self.isCancellation(error) {
                // You kept typing, so this guess is out of date. Not a problem with Claude.
                return Result(interpretation: Self.rules(text, catalog: catalog, activeSession: activeSession), usedAI: false)
            } catch {
                lastProblem = error.localizedDescription
                Log.info("Claude unavailable, using rules: \(error.localizedDescription)")
            }
        }
        return Result(interpretation: ruled, usedAI: false)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    /// Claude sometimes returns a slightly different spelling; snap it to the real project name.
    private func resolveProject(_ name: String, catalog: ProjectCatalog) -> String {
        guard !name.isEmpty else { return "" }
        return catalog.match(name)?.name ?? name
    }

    func report(for session: Session) async throws -> SessionReport {
        guard let client else { throw ClaudeClient.Failure.http(401, "no key") }
        // A second guard behind Library.writeReport: a local-only session's entries and screenshots stay here.
        if let project = session.project, localOnly().contains(project) {
            throw ClaudeClient.Failure.http(403, "\(project) is local only")
        }
        var images: [String: (data: Data, mediaType: String)] = [:]
        for path in session.entries.flatMap(\.attachments).prefix(20) {
            if let image = NSImage(contentsOf: session.folder.appendingPathComponent(path)), let jpeg = image.jpegData(maxSide: 1568) {
                images[path] = (jpeg, "image/jpeg")
            }
        }
        return try await ReportWriter.write(session, images: images, with: client)
    }

    // MARK: Without AI

    static func rules(_ text: String, catalog: ProjectCatalog, activeSession: Session?) -> Interpretation {
        Rules.interpret(text, catalog: catalog, activeSession: activeSession)
    }
}
