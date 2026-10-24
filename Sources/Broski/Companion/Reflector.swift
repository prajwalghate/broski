import AppKit
import BroskiCore
import CoreGraphics

/// Runs reflection when the Mac has been idle a while: checks every ten minutes, never more than once every six hours,
/// never while one is running, and never on turns that touch a local-only project.
@MainActor
final class Reflector {
    private let root: URL
    private let library: Library
    private let config: () -> BroskiConfig
    private let gateway: () -> ModelGateway?
    private var timer: Timer?
    private(set) var running = false
    /// After a run, whatever changed (MemoryView reloads).
    var onChange: (() -> Void)?

    init(root: URL, library: Library, config: @escaping () -> BroskiConfig, gateway: @escaping () -> ModelGateway?) {
        self.root = root
        self.library = library
        self.config = config
        self.gateway = gateway
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// Seconds since the last keypress, click or mouse move.
    private var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private var hidden: Set<String> { Set(config().localOnlyProjects) }

    private func keep(_ turn: Turn) -> Bool {
        !LocalOnly.touches(turn.text, projects: [turn.project], localOnly: hidden, catalog: library.catalog)
    }

    private func check() async {
        guard config().reflection, !running else { return }
        let pending = Reflection.newTurns(root: root, hidden: hidden, keep: keep).count
        guard Reflection.due(lastRun: Reflection.loadState(root: root).lastRun, newTurns: pending, idleSeconds: idleSeconds) else { return }
        _ = await run()
    }

    /// One run now. Returns a line for the person: what changed, or why nothing did.
    func run() async -> String {
        guard !running else { return "Already reflecting." }
        guard let gateway = gateway() else { return "" }
        running = true
        defer { running = false }
        do {
            let proposal = try await Reflection.run(gateway: gateway, root: root, device: "mac", hidden: hidden, keep: keep)
            onChange?()
            Log.info("Reflection: remembered \(proposal.remember.count), forgot \(proposal.forget.count)")
            if proposal.isEmpty { return "Nothing new to remember." }
            var parts: [String] = []
            if !proposal.remember.isEmpty { parts.append("remembered \(proposal.remember.count)") }
            if !proposal.forget.isEmpty { parts.append("forgot \(proposal.forget.count)") }
            return parts.joined(separator: ", ").capitalizedFirst + "."
        } catch {
            Log.info("Reflection failed: \(error.localizedDescription)")
            return "Couldn't reflect: \(error.localizedDescription)"
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
