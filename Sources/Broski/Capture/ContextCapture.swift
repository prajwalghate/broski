import AppKit
import ApplicationServices
import BroskiCore

/// Notes what you were looking at when a capture starts, so a note still makes sense later.
/// - App name: always (no permission needed).
/// - Browser address and page title: via AppleScript; macOS asks once per browser.
/// - Window title and selected text: via Accessibility, only once you've allowed it.
enum ContextCapture {
    static let browsers: [String: String] = [
        "com.apple.Safari": "Safari",
        "com.google.Chrome": "Google Chrome",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    /// Call before Broski's panel appears, while your app is still frontmost.
    static func snapshot(includeBrowser: Bool, includeAccessibility: Bool) -> ItemContext {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return ItemContext() }
        var context = ItemContext(app: app.localizedName)
        if includeAccessibility, AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.3)
            if let window = attribute(element, kAXFocusedWindowAttribute) {
                context.window = string(window as! AXUIElement, kAXTitleAttribute)
            }
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(systemWide, 0.3)
            if let focused = attribute(systemWide, kAXFocusedUIElementAttribute) {
                let selected = string(focused as! AXUIElement, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let selected, !selected.isEmpty { context.selection = String(selected.prefix(4000)) }
            }
        }
        if includeBrowser, let id = app.bundleIdentifier, let name = browsers[id] {
            let (url, title) = browserPage(name: name, safari: id == "com.apple.Safari")
            context.url = url
            if context.window == nil { context.window = title }
        }
        return context
    }

    static var accessibilityAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends you to Privacy & Security › Accessibility.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Privacy & Security › Accessibility, for when the prompt has been dismissed before.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func browserPage(name: String, safari: Bool) -> (String?, String?) {
        let source = safari
            ? "tell application \"\(name)\" to return (URL of front document) & \"\\n\" & (name of front document)"
            : "tell application \"\(name)\" to return (URL of active tab of front window) & \"\\n\" & (title of active tab of front window)"
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return (nil, nil) }
        let parts = output.components(separatedBy: "\n")
        return (parts.first.flatMap { $0.isEmpty ? nil : $0 }, parts.count > 1 ? parts[1] : nil)
    }
}

/// Screenshots: Broski's own picker (click a window or drag an area) on macOS 14+,
/// macOS's `screencapture` crosshair before that.
enum Screenshot {
    enum Result {
        case image(URL)
        case cancelled
        case needsPermission
        case failed(String)
    }

    @MainActor
    static func capture() async -> Result {
        if #available(macOS 14.0, *) {
            switch await ScreenshotPicker.shared.pick() {
            case .image(let url): return .image(url)
            case .cancelled: return .cancelled
            case .needsPermission: return .needsPermission
            case .failed(let message): return .failed(message)
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-shot-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", "-o", url.path]
        let saved: Bool = await withCheckedContinuation { done in
            process.terminationHandler = { _ in done.resume(returning: FileManager.default.fileExists(atPath: url.path)) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
        return saved ? .image(url) : .cancelled
    }

    /// Quits and reopens Broski, which macOS needs before a new Screen Recording grant takes effect.
    static func relaunchBroski() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// An image on the clipboard, saved to a temporary PNG.
    static func fromClipboard() -> URL? {
        guard let image = NSImage(pasteboard: .general), let png = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-paste-\(UUID().uuidString).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// JPEG no larger than `maxSide` pixels, for sending screenshots to Claude.
    func jpegData(maxSide: CGFloat, quality: CGFloat = 0.8) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
