import AppKit
import BroskiCore
import SwiftUI

/// A floating panel for the companion (the top pill, Ask, help cards). Floats over everything, on every Space,
/// sizes itself to its SwiftUI content, takes clicks without activating Broski, and only takes keyboard focus
/// when it has a text field that needs it.
final class CompanionPanel: NSPanel {
    enum Placement {
        /// Just under the menu bar, centered: the pill and its cards.
        case top
        /// A little above the middle of the screen: Ask.
        case center
    }

    var placement: Placement
    var onClose: (() -> Void)?
    private let focusable: Bool

    init<Content: View>(placement: Placement, focusable: Bool, width: CGFloat, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.focusable = focusable
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = !focusable
        animationBehavior = .utilityWindow
        let root = content()
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: PanelSizeKey.self, value: proxy.size) })
            .onPreferenceChange(PanelSizeKey.self) { [weak self] size in
                MainActor.assumeIsolated { self?.fit(size) }
            }
        contentView = FirstMouseHostingView(rootView: AnyView(root))
    }

    override var canBecomeKey: Bool { focusable }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// Resizes to the content, keeping the top edge where it is.
    /// The pointer came onto or left the panel, whether or not Broski is the active app.
    var onHover: ((Bool) -> Void)?

    func fit(_ size: CGSize) {
        guard size.height > 1 else { return }
        var rect = frame
        let top = rect.maxY
        rect.size = NSSize(width: size.width, height: ceil(size.height))
        rect.origin.y = top - rect.height
        if !isVisible { rect = placed(rect) }
        setFrame(rect, display: true)
        invalidateShadow()
    }

    func show(focus: Bool) {
        if !isVisible { setFrame(placed(frame), display: false) }
        if focus && focusable {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
    }

    private func placed(_ rect: NSRect) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return rect }
        var out = rect
        out.origin.x = area.midX - rect.width / 2
        switch placement {
        case .top: out.origin.y = area.maxY - rect.height - 6
        case .center: out.origin.y = area.maxY - area.height * 0.22 - rect.height
        }
        return out
    }
}

private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Buttons work on the first click, even while another app is active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // SwiftUI's hover only fires while Broski is the active app, which it almost never is; this fires always.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["broski"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["broski": true]))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        (window as? CompanionPanel)?.onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        (window as? CompanionPanel)?.onHover?(false)
    }
}

/// The frosted card look shared by the companion's panels.
struct CompanionCard<Content: View>: View {
    var corner: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(Color.primary.opacity(0.08)))
            .padding(10) // room for the shadow
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Speech for Ask and riff: the same mic and Whisper pipeline as notes, one phrase at a time.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcribing = false
    @Published var problem: String?
    private let capture: CaptureController

    init(capture: CaptureController) {
        self.capture = capture
    }

    var available: Bool { capture.transcription.isReady || Permissions.speech == .granted }

    func start() {
        guard !listening, !transcribing else { return }
        guard !capture.isCapturing else { return problem = "Finish the open note first." }
        guard Permissions.microphone == .granted else { return problem = "Allow the microphone in System Settings to talk to Broski." }
        do {
            try capture.engine.beginDictation(replay: 0, live: false)
            listening = true
            problem = nil
        } catch {
            problem = "Mic unavailable: \(error.localizedDescription)"
        }
    }

    /// Stops and returns what was said ("" for nothing).
    func stop(vocabulary: [String]) async -> String {
        guard listening else { return "" }
        listening = false
        let audio = capture.engine.takeRecording()
        capture.engine.resumeIdle()
        guard capture.transcription.isReady else {
            problem = "Download the voice model in Settings › Voice to talk here."
            return ""
        }
        transcribing = true
        defer { transcribing = false }
        do {
            return try await capture.transcription.transcribe(audio, language: Transcription.language(for: capture.config.locale), vocabulary: vocabulary)
        } catch {
            problem = "Couldn't transcribe: \(error.localizedDescription)"
            return ""
        }
    }
}
