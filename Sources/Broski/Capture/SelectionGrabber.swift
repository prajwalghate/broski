import AppKit
import ApplicationServices
import BroskiCore

/// Gets the text you've highlighted in whatever app you're in.
/// Accessibility first (instant, leaves the clipboard alone); apps that don't expose it, like
/// Chrome and Electron apps, get a quick ⌘C with the clipboard put back right after.
@MainActor
enum SelectionGrabber {
    enum Result {
        case text(String)
        case nothing
        case needsAccessibility
    }

    /// Puts the clipboard back if the app answers ⌘C after grab() has given up.
    private static var lateCopyWatch: Task<Void, Never>?
    /// What that watch would put back, so a retry can put it back itself instead of saving the late copy as your clipboard.
    private static var pendingRestore: (before: Int, saved: [[NSPasteboard.PasteboardType: Data]])?

    static func grab(_ context: ItemContext) async -> Result {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "?"
        // A retry right after a late copy: your clipboard goes back before anything else reads it.
        settleLateCopy(NSPasteboard.general, stopWatching: false)
        // Testing switch: `defaults write dev.broski.app BroskiClipForceCopy -bool true` takes the browser path everywhere.
        let forceCopy = UserDefaults.standard.bool(forKey: "BroskiClipForceCopy")
        if !forceCopy, let text = context.selection?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            Log.info("Clip: \(text.count) characters from \(name) via Accessibility")
            return .text(text)
        }
        guard AXIsProcessTrusted() else {
            Log.info("Clip: Accessibility not allowed")
            return .needsAccessibility
        }
        if !forceCopy, let app, let text = focusedSelection(in: app) {
            Log.info("Clip: \(text.count) characters from \(name) via the focused element")
            return .text(text)
        }
        // Browsers and Electron apps don't share selected text with Accessibility, so copy it.
        // Wait until you've let go of the shortcut's ⌥⇧, or the app would see ⌘⌥⇧C.
        let released = Date().addingTimeInterval(0.8)
        while !CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: [.maskAlternate, .maskShift, .maskControl, .maskCommand]),
              Date() < released {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let board = NSPasteboard.general
        // A new copy would look like the old watch's late copy, so the old watch stops here.
        settleLateCopy(board, stopWatching: true)
        let saved = snapshot(board)
        let before = board.changeCount
        let pressed = Date()
        guard pressCopy() else {
            Log.info("Clip: couldn't send ⌘C to \(name)")
            return .needsAccessibility
        }
        // Busy Electron apps can take most of a second; a normal copy still ends the wait at once.
        let deadline = Date().addingTimeInterval(1.2)
        while board.changeCount == before && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard board.changeCount != before else {
            Log.info("Clip: \(name) didn't copy anything (nothing highlighted?)")
            watchForLateCopy(since: before, at: pressed, saved: saved, board: board, app: app)
            return .nothing
        }
        let copied = board.string(forType: .string)
        restore(saved, to: board)
        guard let text = copied?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            Log.info("Clip: \(name) copied something that isn't text")
            return .nothing
        }
        Log.info("Clip: \(text.count) characters from \(name) via copy")
        return .text(String(text.prefix(20_000)))
    }

    /// Watches only briefly and only undoes a change the size of one copy, made before you've clicked, typed
    /// or switched apps, so a copy you make yourself afterwards stays.
    private static func watchForLateCopy(since before: Int, at pressed: Date, saved: [[NSPasteboard.PasteboardType: Data]],
                                         board: NSPasteboard, app: NSRunningApplication?) {
        let name = app?.localizedName ?? "?"
        pendingRestore = (before: before, saved: saved)
        lateCopyWatch = Task {
            let deadline = Date().addingTimeInterval(1.5)
            while board.changeCount == before && Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // Let an app that clears and then writes finish before measuring.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            lateCopyWatch = nil
            pendingRestore = nil
            let changes = board.changeCount - before
            guard changes > 0, changes <= 2 else { return }
            // Once you've clicked, typed or moved to another app, the change may be your own copy (or Broski's), so it stays.
            guard !userActed(since: pressed), NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier else {
                Log.info("Clip: clipboard changed after you moved on; left it alone")
                return
            }
            restore(saved, to: board)
            Log.info("Clip: \(name) copied late; put the clipboard back")
        }
    }

    /// Ends the late-copy watch early once the late copy has landed (or always, with stopWatching),
    /// putting your clipboard back first so the next snapshot isn't the highlighted text.
    private static func settleLateCopy(_ board: NSPasteboard, stopWatching: Bool) {
        guard let pending = pendingRestore else { return }
        let changes = board.changeCount - pending.before
        guard changes > 0 || stopWatching else { return }
        lateCopyWatch?.cancel()
        lateCopyWatch = nil
        pendingRestore = nil
        guard changes > 0, changes <= 2 else { return }
        restore(pending.saved, to: board)
        Log.info("Clip: the app copied late; put the clipboard back")
    }

    /// A real key press or click since `time`. The slack skips Broski's own ⌘C, posted right at `time`.
    private static func userActed(since time: Date) -> Bool {
        let quiet = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
        return quiet < Date().timeIntervalSince(time) - 0.2
    }

    /// The app's own focused element, which some apps answer for when the system-wide query doesn't.
    private static func focusedSelection(in app: NSRunningApplication) -> String? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var selected: AnyObject?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(20_000))
    }

    /// Sends ⌘C to the frontmost app. False when macOS won't let Broski post key events.
    private static func pressCopy() -> Bool {
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
            return false
        }
        let source = CGEventSource(stateID: .hidSystemState)
        let c: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: c, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { types[type] = data } }
            return types
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(items)
    }
}

/// Right-click › Services › "Add to Broski", in any app, for highlighted text or images.
/// Works without Accessibility access.
@MainActor
final class BroskiServices: NSObject {
    var onText: ((String, ItemContext) -> Void)?
    var onImages: (([URL], ItemContext) -> Void)?

    @objc func addToBroski(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        // The app you highlighted in is still frontmost while the service runs.
        let context = ContextCapture.snapshot(includeBrowser: true, includeAccessibility: false)
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter { NSImage(contentsOf: $0) != nil }
            if !images.isEmpty { return onImages?(images, context) ?? () }
        }
        if let text = board.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return onText?(text, context) ?? ()
        }
        if let image = NSImage(pasteboard: board), let png = image.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-service-\(UUID().uuidString).png")
            if (try? png.write(to: url)) != nil { return onImages?([url], context) ?? () }
        }
        error.pointee = "Broski couldn't read what you sent." as NSString
    }
}
