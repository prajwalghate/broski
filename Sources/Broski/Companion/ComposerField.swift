import AppKit
import BroskiCore
import SwiftUI

/// The message box, behaving like every chat app's: it grows with what you type (up to `maxLines`, then scrolls),
/// Return sends, Shift-Return starts a new line, Up in an empty box brings back your last message, pasting or dropping
/// a file or an image attaches it, and Esc goes to the window (stop listening, stop the reply).
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat = 14
    var maxLines = 6
    var onSend: () -> Void
    var onRecall: () -> String? = { nil }
    /// Pasted or dropped files and images; nil pastes their names as text.
    var onFiles: (([URL]) -> Void)?
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Message to Broski")
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        textView.placeholder = placeholder
        textView.setAccessibilityPlaceholderValue(placeholder)
        textView.onSend = onSend
        textView.onRecall = { [weak textView] in
            guard let textView, let last = onRecall() else { return }
            context.coordinator.replace(with: last, in: textView)
        }
        textView.onFiles = onFiles
        textView.onEscape = onEscape
        // Set from outside (a chip, dictation, Send clearing it). Not while an input method is composing.
        if textView.string != text, !textView.hasMarkedText() {
            context.coordinator.replace(with: text, in: textView)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView, let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: textView.fittingHeight(width: width, maxLines: maxLines))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        weak var textView: ComposerTextView?
        /// The box's own undo history, so text set from outside (Send clears it) can't be "undone" into a mess.
        private let undo = UndoManager()

        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func replace(with value: String, in textView: NSTextView) {
            textView.string = value
            textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
            undo.removeAllActions()
            if parent.text != value { parent.text = value }
            textView.needsDisplay = true
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        /// Tab leaves the box instead of typing a tab.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(nil)
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            return false
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var onSend: () -> Void = {}
    var onRecall: () -> Void = {}
    var onFiles: (([URL]) -> Void)?
    var onEscape: () -> Void = {}
    private var keyObserver: NSObjectProtocol?

    override func keyDown(with event: NSEvent) {
        let press: ComposerKey.Press
        switch event.keyCode {
        case 36, 76: press = .returnKey  // Return, keypad Enter
        case 126: press = .up
        default: press = .other
        }
        let flags = event.modifierFlags
        switch ComposerKey.action(press, shift: flags.contains(.shift), option: flags.contains(.option),
                                  control: flags.contains(.control), command: flags.contains(.command),
                                  composing: hasMarkedText(), empty: string.isEmpty) {
        case .send: onSend()
        case .newLine: insertText("\n", replacementRange: selectedRange())
        case .recallLast: onRecall()
        case .normal: super.keyDown(with: event)
        }
    }

    /// Esc: stop listening, stop the reply, stop reading aloud (NSTextView would offer word completions instead).
    override func cancelOperation(_ sender: Any?) { onEscape() }

    // MARK: Files and images

    /// A copied file or image (a screenshot on the clipboard, "Copy Image" in a browser) is attached, not typed in.
    override func paste(_ sender: Any?) {
        if let onFiles, let files = Self.files(on: .general) { return onFiles(files) }
        pasteAsPlainText(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        onFiles == nil ? [.string] : [.fileURL, .URL, .tiff, .png, .string]
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let onFiles, let files = Self.files(on: sender.draggingPasteboard) {
            onFiles(files)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Files on the pasteboard, or an image (without text) saved as a PNG to attach. Nil: it's text.
    static func files(on board: NSPasteboard) -> [URL]? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls
        }
        guard board.string(forType: .string) == nil, let image = NSImage(pasteboard: board), let png = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted image \(UUID().uuidString.prefix(6)).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return [url]
    }

    // MARK: Size, placeholder, focus

    func fittingHeight(width: CGFloat, maxLines: Int) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer, let font else { return 22 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let line = layout.defaultLineHeight(for: font)
        let used = string.isEmpty ? line : layout.usedRect(for: container).height
        let inset = textContainerInset.height * 2
        return min(max(used, line), line * CGFloat(maxLines)) + inset
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    /// Ready to type when the window opens or comes back, unless you were in another field.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in self?.focusIfIdle() }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.focusIfIdle()
        }
    }

    private func focusIfIdle() {
        guard let window else { return }
        let responder = window.firstResponder
        if responder == nil || responder === window || responder === window.contentView || !(responder is NSText) {
            window.makeFirstResponder(self)
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }
}
