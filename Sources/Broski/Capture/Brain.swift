import AppKit
import BroskiCore

/// Decides what a capture means, and gives the app's features their way to a model. Uses the model for fast work
/// when one is set up (any provider: see Settings › Models); otherwise (or if it can't be reached) Broski's built-in
/// phrase rules, so capturing never blocks on the network.
@MainActor
final class Brain: ObservableObject {
    /// Some role has a model that can answer now (a cloud provider with its key, a model on this Mac, Apple's).
    @Published private(set) var hasModel = false
    @Published private(set) var lastProblem: String?
    /// Projects whose notes never go to a cloud model.
    var localOnly: () -> Set<String> = { [] }
    /// The gateway every model call goes through (the app supplies it: settings from config.json, keys on this Mac).
    var makeGateway: () -> ModelGateway? = { nil } {
        didSet { refresh() }
    }

    /// The gateway, when there's a model to talk to.
    var gateway: ModelGateway? { hasModel ? makeGateway() : nil }

    /// Re-reads whether a model is ready (after a key, a provider or a role changes).
    func refresh() {
        guard let settings = makeGateway()?.settings else { return hasModel = false }
        hasModel = ModelSetup.ready(settings, hasKey: { Secrets.key(forProvider: $0) != nil }, appleAvailable: ModelsSettings.appleAvailable)
    }

    /// Saves a provider's key on this Mac (nil removes it). False when the secrets file couldn't be written.
    @discardableResult
    func setKey(_ key: String?, for provider: String) -> Bool {
        let saved = Secrets.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: Secrets.keyName(forProvider: provider))
        refresh()
        lastProblem = saved ? nil : "Couldn't save the key to \(Secrets.file.path). Check that folder's permissions."
        return saved
    }

    /// Nil when the provider answers; otherwise what went wrong, in words a person can act on.
    func check(_ providerID: String) async -> String? {
        guard let provider = makeGateway()?.settings.provider(providerID) else { return "That provider isn't set up." }
        do {
            _ = try await ProviderCheck.run(provider, key: Secrets.key(forProvider: providerID))
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
        if let gateway {
            let request = Interpreter.Request(
                // The model isn't told local-only projects exist, so it can't file anything into them.
                text: text, spoken: spoken, projects: catalog.projects.map(\.name).filter { !blocked.contains($0) },
                activeSession: activeSession.map { "\($0.kind.label) “\($0.title)” for \($0.project ?? "the inbox")" },
                context: context, attachmentCount: attachmentCount
            )
            do {
                var result = try await Interpreter.interpret(request, gateway: gateway)
                result.project = resolveProject(result.project, catalog: catalog)
                lastProblem = nil
                return Result(interpretation: result, usedAI: true)
            } catch where Self.isCancellation(error) {
                // You kept typing, so this guess is out of date. Not a problem with the model.
                return Result(interpretation: Self.rules(text, catalog: catalog, activeSession: activeSession), usedAI: false)
            } catch {
                lastProblem = error.localizedDescription
                Log.info("Model unavailable, using rules: \(error.localizedDescription)")
            }
        }
        return Result(interpretation: ruled, usedAI: false)
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        if let url = error as? URLError, url.code == .cancelled { return true }
        return (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
    }

    /// A model sometimes returns a slightly different spelling; snap it to the real project name.
    private func resolveProject(_ name: String, catalog: ProjectCatalog) -> String {
        guard !name.isEmpty else { return "" }
        return catalog.match(name)?.name ?? name
    }

    func report(for session: Session) async throws -> SessionReport {
        guard let gateway else { throw ModelFailure.unavailable("Choose a model in Settings › Models to write reports.") }
        var images: [String: (data: Data, mediaType: String)] = [:]
        for path in session.entries.flatMap(\.attachments).prefix(20) {
            if let image = NSImage(contentsOf: session.folder.appendingPathComponent(path)), let jpeg = image.jpegData(maxSide: 1568) {
                images[path] = (jpeg, "image/jpeg")
            }
        }
        // A local-only session's entries and screenshots go only to a model on this Mac (or nowhere).
        let local = session.project.map { localOnly().contains($0) } ?? false
        return try await ReportWriter.write(session, images: images, gateway: gateway, localOnly: local)
    }

    // MARK: Without AI

    static func rules(_ text: String, catalog: ProjectCatalog, activeSession: Session?) -> Interpretation {
        Rules.interpret(text, catalog: catalog, activeSession: activeSession)
    }
}
