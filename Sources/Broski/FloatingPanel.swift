import AppKit
import SwiftUI

/// A Spotlight-style panel: floats above other windows and full-screen apps, shows on
/// every Space, and can take keyboard focus without pulling you out of the app you're in.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onDropFiles: (([URL]) -> Void)? {
        get { (contentView as? DropEffectView)?.onDrop }
        set { (contentView as? DropEffectView)?.onDrop = newValue }
    }

    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: PanelView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow

        let effect = DropEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 18)

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// ⌘W closes it like Esc does (it has no close button, so the system would only beep).
    override func performClose(_ sender: Any?) {
        onCancel?()
    }

    /// Shows the panel beside `anchor` (the floating button) or near the top of the active screen.
    /// Only takes keyboard focus when asked, so a wake word never steals your typing.
    func present(focus: Bool, near anchor: NSRect?) {
        if !isVisible || anchor != nil { position(near: anchor) }
        if focus {
            makeKeyAndOrderFront(nil)
        } else {
            orderFrontRegardless()
        }
        invalidateShadow()
    }

    /// Changes the height, keeping the top edge where it is.
    func fit(height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var rect = frame
        rect.origin.y += rect.height - height
        rect.size.height = height
        if let area = screen?.visibleFrame, rect.minY < area.minY { rect.origin.y = area.minY }
        setFrame(rect, display: true, animate: isVisible)
        invalidateShadow()
    }

    func dismiss() {
        orderOut(nil)
    }

    private func position(near anchor: NSRect?) {
        let mouse = NSEvent.mouseLocation
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        guard let anchor else {
            setFrameOrigin(NSPoint(x: area.midX - frame.width / 2, y: area.maxY - frame.height - 28))
            return
        }
        // Prefer the side of the button with more room, centred on it vertically.
        let roomLeft = anchor.minX - area.minX
        let roomRight = area.maxX - anchor.maxX
        var x = roomLeft >= roomRight ? anchor.minX - frame.width - 10 : anchor.maxX + 10
        var y = anchor.midY - frame.height / 2
        x = min(max(x, area.minX + 8), area.maxX - frame.width - 8)
        y = min(max(y, area.minY + 8), area.maxY - frame.height - 8)
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The panel's background, which also accepts dropped files and images.
final class DropEffectView: NSVisualEffectView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDrop == nil ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        var urls = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty, let image = NSImage(pasteboard: board), let png = image.pngData() {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("broski-drop-\(UUID().uuidString).png")
            if (try? png.write(to: file)) != nil { urls = [file] }
        }
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
