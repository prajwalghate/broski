import AppKit
import BroskiCore
import SwiftUI

/// `Broski --chat-check <report>`: the chat's basics in the real views, off screen, in a throwaway Broski folder.
/// It presses keys in the message box (Return, Shift-Return, Up, Esc), pastes, and scrolls the conversation the way
/// you would, then checks what happened. No model is called and nothing real is touched. Exits 1 if anything failed.
@MainActor
enum ChatCheck {
    static func run(report: URL) -> Bool {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var lines: [String] = []
        var failed = 0
        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "PASS  " : "FAIL  ") + what)
            if !ok { failed += 1 }
            try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        composer(check)
        conversation(check)
        lines.append(failed == 0 ? "all passed" : "\(failed) failed")
        try? (lines.joined(separator: "\n") + "\n").write(to: report, atomically: true, encoding: .utf8)
        return failed == 0
    }

    // MARK: The message box

    private static func composer(_ check: (Bool, String) -> Void) {
        let box = Harness()
        let window = host(ComposerHarness(box: box).frame(width: 420), size: NSSize(width: 420, height: 160))
        defer { window.orderOut(nil) }
        guard let text = find(ComposerTextView.self, in: window.contentView) else { return check(false, "the message box is on screen") }
        let scroll = text.enclosingScrollView
        let oneLine = scroll?.frame.height ?? 0

        text.insertText("first line", replacementRange: text.selectedRange())
        text.keyDown(with: key(36, "\r", [.shift]))
        text.insertText("second line", replacementRange: text.selectedRange())
        settle()
        check(box.text == "first line\nsecond line" && box.sends == 0, "Shift-Return starts a new line instead of sending")
        check((scroll?.frame.height ?? 0) > oneLine + 8, "the box grows with a second line (\(Int(oneLine)) → \(Int(scroll?.frame.height ?? 0)) points)")

        text.keyDown(with: key(36, "\r", [.option]))
        check(box.text.hasSuffix("\n") && box.sends == 0, "Option-Return starts a new line too")

        text.keyDown(with: key(36, "\r", []))
        settle()
        check(box.sends == 1, "Return sends")
        check(text.string.isEmpty && box.text.isEmpty, "the box is empty after sending")

        text.keyDown(with: key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.function, .numericPad]))
        settle()
        check(text.string == Harness.lastSaid && box.text == Harness.lastSaid, "Up in an empty box brings back your last message")
        text.keyDown(with: key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.function, .numericPad]))
        check(text.string == Harness.lastSaid, "Up with text in the box only moves the cursor")

        text.keyDown(with: key(36, "\r", [.command]))
        check(box.sends == 2, "Command-Return sends")

        text.keyDown(with: key(53, "\u{1b}", []))
        check(box.escapes == 1, "Esc goes to the window (stop listening, stop the reply)")

        text.insertText("draft", replacementRange: text.selectedRange())
        box.text = "set from outside"
        settle()
        check(text.string == "set from outside", "text set from outside (a chip, dictation) shows in the box")

        // Pasting: a file or an image is attached; text is text.
        let board = NSPasteboard(name: NSPasteboard.Name("broski-chat-check-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chat-check.txt")
        try? "x".write(to: file, atomically: true, encoding: .utf8)
        board.clearContents()
        board.writeObjects([file as NSURL])
        check(ComposerTextView.files(on: board) == [file], "a copied file is attached, not pasted as its name")
        board.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        board.writeObjects([image])
        check(ComposerTextView.files(on: board)?.first?.pathExtension == "png", "a copied image (a screenshot) is attached")
        board.clearContents()
        board.setString("just words", forType: .string)
        check(ComposerTextView.files(on: board) == nil, "copied text is pasted as text")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: The conversation

    private static func conversation(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broski-chat-check-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(root: root, device: "mac")
        let start = Date().addingTimeInterval(-3600)
        for i in 0..<40 {
            let you = i % 2 == 0
            let text = you ? "Question \(i): what should I do about the launch checklist and the pricing page?"
                : (0..<(1 + i % 4)).map { "Line \($0) of reply \(i): the checklist, then pricing, then the launch email." }.joined(separator: "\n")
            try? store.append(Turn(at: start.addingTimeInterval(Double(i) * 20), device: "mac", speaker: you ? .you : .broski, text: text))
        }
        let app = AppModel(root: root)
        let home = app.homeModel
        home.draft = ""
        home.reload()
        let window = host(HomeView(model: home, voice: app.voice, openDashboard: {}, openMemory: {}), size: NSSize(width: 560, height: 700))
        defer { window.orderOut(nil) }
        settle(1.0)
        let scrolls = all(NSScrollView.self, in: window.contentView).filter { !($0.documentView is ComposerTextView) }
        guard let chat = scrolls.max(by: { $0.frame.height < $1.frame.height }) else { return check(false, "the conversation is on screen") }

        check(fromBottom(chat) < 30, "opens at the latest message (\(Int(fromBottom(chat))) points from the end)")

        scrollToTop(chat)
        settle()
        let reading = fromBottom(chat)
        check(reading > 300, "you can scroll up to read (\(Int(reading)) points from the end)")

        home.add(Turn(device: "mac", speaker: .broski, text: "A reply that arrives while you're reading older messages."))
        settle()
        check(abs(fromBottom(chat) - reading) < 200 && fromBottom(chat) > 300, "a new reply doesn't pull you away from what you're reading")

        home.add(Turn(device: "mac", speaker: .you, text: "Something you said"))
        settle()
        check(fromBottom(chat) < 30, "what you say scrolls into view, even from up there")

        home.add(Turn(device: "mac", speaker: .broski, text: (0..<8).map { "Line \($0) of a long reply." }.joined(separator: "\n")))
        settle()
        check(fromBottom(chat) < 30, "a reply follows you at the bottom")

        home.problem = "Couldn't reach the model."
        settle()
        check(fromBottom(chat) < 30, "a problem at the end is scrolled into view")

        home.draft = "one\ntwo\nthree\nfour"
        settle()
        check(fromBottom(chat) < 30, "the box growing keeps the latest in view")

        scrollToTop(chat)
        settle()
        home.objectWillChange.send()
        settle()
        check(fromBottom(chat) > 300, "staying scrolled up stays put")
        home.draft = ""
    }

    // MARK: Helpers

    private static func host<V: View>(_ view: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -40000, y: -40000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        settle()
        return window
    }

    static func settle(_ seconds: Double = 0.5) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? { all(type, in: view).first }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// How far the visible part is from the conversation's end, in points.
    private static func fromBottom(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        let visible = scroll.contentView.bounds
        return document.isFlipped ? document.frame.height - visible.maxY : visible.minY
    }

    private static func scrollToTop(_ scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let top = document.isFlipped ? 0 : document.frame.height - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

private final class Harness: ObservableObject {
    static let lastSaid = "the last thing you said"
    @Published var text = ""
    var sends = 0
    var escapes = 0
}

private struct ComposerHarness: View {
    @ObservedObject var box: Harness

    var body: some View {
        ComposerField(text: $box.text, placeholder: "Talk to Broski",
                      onSend: { box.sends += 1; box.text = "" }, onRecall: { Harness.lastSaid },
                      onFiles: { _ in }, onEscape: { box.escapes += 1 })
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
