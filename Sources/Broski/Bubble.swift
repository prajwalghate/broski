import AppKit
import QuartzCore

/// The floating Broski head. Click it to take a note, drag it anywhere, right-click for options.
/// It never takes keyboard focus, and it remembers where you left it.
@MainActor
final class BubbleController {
    private let window: BubbleWindow
    private let view: BubbleView
    private static let positionKey = "BroskiBubbleOrigin"

    var onClick: ((NSRect) -> Void)?
    /// Press and hold the head to talk; let go to file it.
    var onHoldStart: ((NSRect) -> Void)?
    var onHoldEnd: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    init() {
        view = BubbleView(frame: NSRect(x: 0, y: 0, width: BubbleView.size, height: BubbleView.size))
        window = BubbleWindow(view: view)
        view.onClick = { [weak self] in
            guard let self else { return }
            self.onClick?(self.window.frame)
        }
        view.onHoldStart = { [weak self] in
            guard let self else { return }
            self.onHoldStart?(self.window.frame)
        }
        view.onHoldEnd = { [weak self] in self?.onHoldEnd?() }
        view.onRightClick = { [weak self] event in
            guard let self, let menu = self.menuProvider?() else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self.view)
        }
        view.onMoved = { [weak self] in self?.settle() }
        restorePosition()
    }

    var frame: NSRect { window.frame }

    func setVisible(_ visible: Bool) {
        if visible {
            restorePosition()
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    func show(_ activity: CaptureController.Activity) {
        view.activity = activity
    }

    /// Keep the button on screen after a drag, and remember the spot.
    private func settle() {
        var origin = window.frame.origin
        if let area = (window.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, area.minX + 4), area.maxX - window.frame.width - 4)
            origin.y = min(max(origin.y, area.minY + 4), area.maxY - window.frame.height - 4)
            window.setFrameOrigin(origin)
        }
        UserDefaults.standard.set("\(Int(origin.x)),\(Int(origin.y))", forKey: Self.positionKey)
    }

    private func restorePosition() {
        let screens = NSScreen.screens
        if let saved = UserDefaults.standard.string(forKey: Self.positionKey) {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let origin = NSPoint(x: parts[0], y: parts[1])
                let rect = NSRect(origin: origin, size: window.frame.size)
                if screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                    window.setFrameOrigin(origin)
                    return
                }
            }
        }
        // First run: right edge, a little above the middle.
        guard let area = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: area.maxX - window.frame.width - 16, y: area.minY + area.height * 0.58))
    }
}

final class BubbleWindow: NSPanel {
    init(view: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BubbleView.size, height: BubbleView.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BubbleView: NSView {
    static let size: CGFloat = 66

    var activity: CaptureController.Activity = .idle {
        didSet { if activity != oldValue { updateRing() } }
    }
    var onClick: (() -> Void)?
    var onHoldStart: (() -> Void)?
    var onHoldEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onMoved: (() -> Void)?
    private var holdTimer: Timer?
    private var holding = false

    private let ring = CAShapeLayer()
    private let avatar = BroskiArt.avatar(diameter: 52, crowned: false)
    private let crownedAvatar = BroskiArt.avatar(diameter: 52, crowned: true)
    private var hovering = false {
        didSet { needsDisplay = true; updateRing() }
    }
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 3
        ring.strokeColor = BroskiArt.Palette.purple.cgColor
        ring.opacity = 0
        layer?.addSublayer(ring)
        toolTip = "Click for hands-free · hold to talk · drag to move · right-click for options"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var disc: NSRect { bounds.insetBy(dx: 7, dy: 7) }

    override func layout() {
        super.layout()
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 3, dy: 3), transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        BroskiArt.Palette.paper.setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSGraphicsContext.restoreGraphicsState()
        (activity == .saved ? crownedAvatar : avatar).draw(in: disc)
    }

    private func updateRing() {
        ring.removeAllAnimations()
        let color: NSColor
        switch activity {
        case .idle: color = BroskiArt.Palette.purple
        case .listening: color = .systemRed
        case .typing: color = BroskiArt.Palette.purple
        case .saving: color = .systemOrange
        case .saved: color = .systemGreen
        }
        ring.strokeColor = color.cgColor
        switch activity {
        case .idle:
            ring.opacity = hovering ? 0.6 : 0
        case .listening:
            ring.opacity = 1
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            ring.add(pulse, forKey: "pulse")
        case .typing, .saving, .saved:
            ring.opacity = 1
        }
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        dragged = false
        holding = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self, !self.dragged, self.dragStart != nil else { return }
            self.holding = true
            self.onHoldStart?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        if holding { return }
        holdTimer?.invalidate()
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        if holding {
            onHoldEnd?()
        } else if dragged {
            onMoved?()
        } else {
            onClick?()
        }
        holding = false
        dragStart = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}
