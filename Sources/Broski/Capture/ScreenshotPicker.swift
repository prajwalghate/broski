import AppKit
import ScreenCaptureKit

/// Broski's screenshot picker: the screen dims, the window under the pointer lights up with
/// "Screenshot of <App>", a click captures that window, a drag captures an area, Esc cancels.
@available(macOS 14.0, *)
@MainActor
final class ScreenshotPicker {
    enum Outcome {
        case image(URL)
        case cancelled
        case needsPermission
        case failed(String)
    }

    static let shared = ScreenshotPicker()

    struct Target {
        let id: CGWindowID
        let app: String
        /// Global coordinates, top-left origin (CoreGraphics).
        let frame: CGRect
    }

    private var overlays: [PickerWindow] = []
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var content: SCShareableContent?
    private(set) var targets: [Target] = []
    private var keyMonitor: Any?
    /// Set for the whole of pick(), including the permission await, so a second press can't start another pick.
    private var isPicking = false
    /// The app you were in; the picker activates Broski for the crosshair, so focus goes back here after.
    private var previousApp: NSRunningApplication?

    func pick() async -> Outcome {
        guard !isPicking, continuation == nil else { return .cancelled }
        isPicking = true
        defer { isPicking = false }
        // Ask ScreenCaptureKit directly: the preflight check can stay "no" until Broski restarts,
        // even after you've allowed it.
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.info("Screenshot needs Screen Recording permission (\(error.localizedDescription))")
            if !UserDefaults.standard.bool(forKey: "BroskiAskedScreenRecording") {
                UserDefaults.standard.set(true, forKey: "BroskiAskedScreenRecording")
                CGRequestScreenCaptureAccess()
            }
            return .needsPermission
        }
        targets = Self.windowsFrontToBack()
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        return await withCheckedContinuation { done in
            continuation = done
            showOverlays()
        }
    }

    /// On-screen app windows in z-order, frontmost first, without Broski's own.
    private static func windowsFrontToBack() -> [Target] {
        let me = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 40, frame.height > 40 else { return nil }
            return Target(id: id, app: w[kCGWindowOwnerName as String] as? String ?? "window", frame: frame)
        }
    }

    // MARK: Overlay

    private func showOverlays() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let window = PickerWindow(screen: screen, picker: self)
            overlays.append(window)
            window.orderFrontRegardless()
        }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.pickerView.screenRef.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only while picking, so a stray monitor can never swallow Esc in Broski's other windows.
            guard event.keyCode == 53, let self, self.continuation != nil else { return event }
            self.finish(.cancelled)
            return nil
        }
        NSCursor.crosshair.push()
    }

    func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        let app = previousApp
        previousApp = nil
        // Skip if you switched apps yourself meanwhile.
        guard let previous = app, !previous.isTerminated, NSApp.isActive else {
            return continuation.resume(returning: outcome)
        }
        // Give focus back before the caller shows its panel: activation is asynchronous, and a
        // deactivation landing after the panel takes key would pull focus away from it.
        previous.activate()
        Task {
            let deadline = Date().addingTimeInterval(0.5)
            while NSApp.isActive && Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            continuation.resume(returning: outcome)
        }
    }

    /// Topmost window under a global (CoreGraphics) point.
    func target(at point: CGPoint) -> Target? {
        targets.first { $0.frame.contains(point) }
    }

    // MARK: Capturing

    func capture(window target: Target) {
        Task {
            guard let window = content?.windows.first(where: { $0.windowID == target.id }) else {
                return finish(.failed("That window went away"))
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = NSScreen.screens.first { $0.frame.intersects(Self.appKitRect(target.frame)) }?.backingScaleFactor ?? 2
            config.width = Int(target.frame.width * scale)
            config.height = Int(target.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            await save(filter: filter, config: config, label: "window of \(target.app)")
        }
    }

    /// `rect` in global AppKit coordinates (bottom-left origin).
    func capture(area rect: CGRect, on screen: NSScreen) {
        Task {
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content?.displays.first(where: { $0.displayID == displayID }) else {
                return finish(.failed("Couldn't find that display"))
            }
            let mine = content?.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } ?? []
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            // sourceRect is in the display's points, top-left origin.
            let local = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            config.sourceRect = local
            config.width = Int(local.width * screen.backingScaleFactor)
            config.height = Int(local.height * screen.backingScaleFactor)
            config.showsCursor = false
            await save(filter: filter, config: config, label: "area \(Int(rect.width))×\(Int(rect.height))")
        }
    }

    private func save(filter: SCContentFilter, config: SCStreamConfiguration, label: String) async {
        overlays.forEach { $0.alphaValue = 0 }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-shot-\(UUID().uuidString).png")
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return finish(.failed("Couldn't encode the screenshot"))
            }
            try png.write(to: url)
            Log.info("Screenshot: \(label)")
            NSSound(named: "Grab")?.play()
            finish(.image(url))
        } catch {
            Log.info("Screenshot failed: \(error.localizedDescription)")
            finish(.failed(error.localizedDescription))
        }
    }

    // MARK: Coordinates

    private static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// CoreGraphics global rect (top-left origin) → AppKit global rect (bottom-left origin).
    static func appKitRect(_ cg: CGRect) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    static func cgPoint(_ appKit: CGPoint) -> CGPoint {
        CGPoint(x: appKit.x, y: primaryHeight - appKit.y)
    }
}

/// One dimmed, full-screen overlay per display.
@available(macOS 14.0, *)
private final class PickerWindow: NSPanel {
    let pickerView: PickerView

    init(screen: NSScreen, picker: ScreenshotPicker) {
        pickerView = PickerView(screen: screen, picker: picker)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = pickerView
    }

    override var canBecomeKey: Bool { true }
}

@available(macOS 14.0, *)
private final class PickerView: NSView {
    let screenRef: NSScreen
    weak var picker: ScreenshotPicker?
    private var hovered: ScreenshotPicker.Target?
    private var dragStart: CGPoint?
    private var dragNow: CGPoint?
    private var mouse: CGPoint = .zero

    init(screen: NSScreen, picker: ScreenshotPicker) {
        screenRef = screen
        self.picker = picker
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
        updateHover(NSEvent.mouseLocation)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    /// Global AppKit point → this view's coordinates.
    private func local(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - screenRef.frame.minX, y: global.y - screenRef.frame.minY)
    }

    private func localRect(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screenRef.frame.minX, dy: -screenRef.frame.minY)
    }

    private var selection: CGRect? {
        guard let a = dragStart, let b = dragNow, hypot(a.x - b.x, a.y - b.y) > 6 else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func updateHover(_ global: CGPoint) {
        mouse = local(global)
        hovered = picker?.target(at: ScreenshotPicker.cgPoint(global))
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) { updateHover(NSEvent.mouseLocation) }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        dragNow = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        dragNow = NSEvent.mouseLocation
        mouse = local(NSEvent.mouseLocation)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragNow = nil }
        if let area = selection {
            picker?.capture(area: area, on: screenRef)
        } else if let target = hovered {
            picker?.capture(window: target)
        } else {
            picker?.capture(area: screenRef.frame, on: screenRef)
        }
    }

    override func rightMouseDown(with event: NSEvent) { picker?.finish(.cancelled) }

    override func draw(_ dirtyRect: NSRect) {
        let accent = BroskiArt.Palette.purple
        let hole: CGRect? = selection.map(localRect) ?? hovered.map { localRect(ScreenshotPicker.appKitRect($0.frame)) }

        // Dim everything except the window or area that will be captured.
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.append(NSBezierPath(roundedRect: hole, xRadius: selection == nil ? 10 : 0, yRadius: selection == nil ? 10 : 0).reversed) }
        NSColor.black.withAlphaComponent(0.32).setFill()
        dim.fill()

        if let hole {
            let border = NSBezierPath(roundedRect: hole.insetBy(dx: 1, dy: 1), xRadius: selection == nil ? 10 : 0, yRadius: selection == nil ? 10 : 0)
            border.lineWidth = 2
            accent.setStroke()
            border.stroke()
        }

        if let area = selection {
            pill("\(Int(area.width)) × \(Int(area.height))", at: CGPoint(x: localRect(area).midX, y: localRect(area).minY - 18), center: true)
        } else if let target = hovered {
            let frame = localRect(ScreenshotPicker.appKitRect(target.frame))
            pill("Screenshot of \(target.app)", at: CGPoint(x: frame.minX + 12, y: frame.maxY - 30), center: false, strong: true)
            pill("Click to capture · drag to take an area", at: CGPoint(x: mouse.x + 16, y: mouse.y - 34), center: false)
        } else {
            pill("Click to capture this screen · drag to take an area", at: CGPoint(x: mouse.x + 16, y: mouse.y - 34), center: false)
        }
        pill("esc to cancel", at: CGPoint(x: bounds.midX, y: bounds.maxY - 54), center: true)
    }

    private func pill(_ text: String, at point: CGPoint, center: Bool, strong: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: strong ? .semibold : .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var origin = center ? CGPoint(x: point.x - size.width / 2 - 10, y: point.y) : point
        origin.x = min(max(origin.x, 8), bounds.maxX - size.width - 28)
        origin.y = min(max(origin.y, 8), bounds.maxY - size.height - 16)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 20, height: size.height + 8)
        (strong ? BroskiArt.Palette.purple : NSColor.black.withAlphaComponent(0.75)).setFill()
        NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        string.draw(at: CGPoint(x: box.minX + 10, y: box.minY + 4))
    }
}
