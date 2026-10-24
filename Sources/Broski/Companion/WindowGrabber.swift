import AppKit
import ScreenCaptureKit

/// Takes a picture of the window you're working in (never Broski's own), for "Help with this".
enum WindowGrabber {
    enum Result {
        case image(jpeg: Data, png: Data)
        case needsPermission
        case failed(String)
    }

    @MainActor
    static func frontWindow() async -> Result {
        guard #available(macOS 14.0, *) else { return .failed("Needs macOS 14 or later") }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            return .needsPermission
        }
        let mine = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Front-to-back order from the window server, to pick the window actually on top.
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let candidates = content.windows.filter { window in
            window.windowLayer == 0 && window.frame.width > 120 && window.frame.height > 80
                && window.owningApplication?.processID != mine
        }
        let ranked = candidates.sorted { a, b in
            let aFront = a.owningApplication?.processID == front, bFront = b.owningApplication?.processID == front
            if aFront != bFront { return aFront }
            return (order.firstIndex(of: a.windowID) ?? .max) < (order.firstIndex(of: b.windowID) ?? .max)
        }
        guard let window = ranked.first else { return .failed("No window to look at") }
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            let ns = NSImage(cgImage: image, size: window.frame.size)
            guard let jpeg = ns.jpegData(maxSide: 1568), let png = ns.pngData() else { return .failed("Couldn't encode the picture") }
            return .image(jpeg: jpeg, png: png)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
