import AppKit

/// A native menu popped up at the pointer. SwiftUI's `Menu` drops custom label styling on macOS,
/// so styled chips use a plain button that calls this instead.
@MainActor
enum PopupMenu {
    static func show(_ items: [NSMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
