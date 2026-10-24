import AppKit
import Carbon

/// A system-wide shortcut via Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: (pressed: () -> Void, released: (() -> Void)?)] = [:]
    private static var nextID: UInt32 = 1
    private static var eventHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    /// "⌥⇧B"
    let display: String
    let keyEquivalent: String
    let modifierFlags: NSEvent.ModifierFlags

    /// `released` makes press-and-hold possible: it fires when the keys are let go.
    init?(spec: String, released: (() -> Void)? = nil, handler: @escaping () -> Void) {
        guard let parsed = Self.parse(spec) else { return nil }
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        display = parsed.display
        keyEquivalent = parsed.keyEquivalent
        modifierFlags = parsed.flags

        let hotKeyID = EventHotKeyID(signature: OSType(0x4252_534B), id: id)  // 'BRSK'
        let status = RegisterEventHotKey(parsed.keyCode, parsed.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = (handler, released)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !eventHandlerInstalled else { return }
        eventHandlerInstalled = true
        var kinds = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if status == noErr, let handler = HotKey.handlers[hotKeyID.id] {
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    if let released = handler.released { DispatchQueue.main.async(execute: released) }
                } else {
                    DispatchQueue.main.async(execute: handler.pressed)
                }
            }
            return noErr
        }, 2, &kinds, nil, nil)
    }

    struct Parsed {
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let flags: NSEvent.ModifierFlags
        let keyEquivalent: String
        let display: String
    }

    /// Parses "option+shift+b", "ctrl+opt+space", "cmd+shift+n".
    static func parse(_ spec: String) -> Parsed? {
        var carbon: UInt32 = 0
        var flags: NSEvent.ModifierFlags = []
        var key: (code: UInt32, name: String)?
        for raw in spec.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "cmd", "command": carbon |= UInt32(cmdKey); flags.insert(.command)
            case "opt", "option", "alt": carbon |= UInt32(optionKey); flags.insert(.option)
            case "shift": carbon |= UInt32(shiftKey); flags.insert(.shift)
            case "ctrl", "control": carbon |= UInt32(controlKey); flags.insert(.control)
            default:
                guard let code = keyCodes[part] else { return nil }
                key = (code, part)
            }
        }
        guard let key, carbon != 0 else { return nil }
        var symbols = ""
        if flags.contains(.control) { symbols += "⌃" }
        if flags.contains(.option) { symbols += "⌥" }
        if flags.contains(.shift) { symbols += "⇧" }
        if flags.contains(.command) { symbols += "⌘" }
        let isSpace = key.name == "space"
        return Parsed(
            keyCode: key.code, carbonModifiers: carbon, flags: flags,
            keyEquivalent: isSpace ? " " : key.name,
            display: symbols + (isSpace ? "Space" : key.name.uppercased())
        )
    }

    /// The config name for a key code, e.g. 11 → "b". Nil for keys a shortcut can't use.
    static func name(forKeyCode code: UInt32) -> String? {
        keyCodes.first { $0.value == code }?.key
    }

    /// "option+shift+b" from recorded modifiers and a key name.
    static func spec(modifiers: NSEvent.ModifierFlags, key: String) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("option") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    static let keyCodes: [String: UInt32] = {
        let table: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("space", kVK_Space),
        ]
        return Dictionary(uniqueKeysWithValues: table.map { ($0.0, UInt32($0.1)) })
    }()
}
