import AppKit
import BroskiCore

/// Hold fn (🌐) to talk. Watches modifier changes in every app (macOS delivers them only with Accessibility,
/// the same permission ⌥⇧C uses) and reports a hold once fn has been down a moment with nothing else pressed,
/// so a quick tap, fn+arrow, fn+F-keys and ⌃/⌥/⌘/⇧+fn shortcuts all do nothing.
@MainActor
final class FnKeyMonitor {
    static let fnKeyCode: UInt16 = 63
    /// Long enough that a tap or an fn+key combination never starts the mic.
    static let holdDelay: TimeInterval = 0.35

    private let onHold: () -> Void
    private let onRelease: () -> Void
    private var monitors: [Any] = []
    private var pending: Task<Void, Never>?
    private var state = FnHold()

    init(onHold: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onHold = onHold
        self.onRelease = onRelease
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        // Broski's own windows don't reach the global monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        pending?.cancel()
        if state.holding { onRelease() }
        state = FnHold()
    }

    private func handle(_ event: NSEvent) {
        let input: FnHold.Event
        switch event.type {
        case .flagsChanged where event.keyCode == Self.fnKeyCode:
            // Arrow and F-keys carry the .function flag too, so fn itself is told apart by its key code.
            input = event.modifierFlags.contains(.function)
                ? .fnDown(withModifiers: !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty)
                : .fnUp
        case .flagsChanged:
            input = .otherModifier
        case .keyDown:
            input = .keyDown
        default:
            return
        }
        perform(state.handle(input))
    }

    private func perform(_ action: FnHold.Action) {
        switch action {
        case .none:
            break
        case .startTimer:
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.holdDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.perform(self.state.timerFired())
            }
        case .cancelTimer:
            pending?.cancel()
        case .startTalking:
            onHold()
        case .stopTalking:
            pending?.cancel()
            onRelease()
        }
    }

    /// What macOS does when the 🌐/fn key is pressed on its own ("Press 🌐 key to" in Keyboard settings):
    /// 0 do nothing, 1 change input source, 2 show emoji and symbols, 3 start dictation. Nil when never changed.
    static var systemFnAction: Int? {
        CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
    }
}
