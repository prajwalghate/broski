import Foundation

/// What a key does in the message box, as in every chat app: Return sends, Shift-, Option- or Control-Return starts a
/// new line, Command-Return sends too. While an input method is composing, its keys are its own. Up in an empty box
/// brings back your last message to edit.
public enum ComposerKey: Equatable, Sendable {
    case send, newLine, recallLast, normal

    public enum Press: Sendable { case returnKey, up, other }

    public static func action(_ press: Press, shift: Bool = false, option: Bool = false, control: Bool = false,
                              command: Bool = false, composing: Bool = false, empty: Bool = false) -> ComposerKey {
        guard !composing else { return .normal }
        switch press {
        case .returnKey:
            if command { return .send }
            return shift || option || control ? .newLine : .send
        case .up:
            return empty && !shift && !option && !control && !command ? .recallLast : .normal
        case .other:
            return .normal
        }
    }
}

/// Keeping the conversation at its latest line without pulling you away from something you scrolled up to read.
public enum ChatScroll {
    public enum Change: Sendable {
        /// You sent something.
        case yourMessage
        /// A reply, a card, a note or a problem arrived.
        case newContent
        /// Another thread, private mode, or the window opened.
        case switchedView
    }

    /// The conversation's end (`endY`, in the visible area's coordinates) is in view, give or take `tolerance` points.
    public static func atBottom(endY: Double, viewport: Double, tolerance: Double = 60) -> Bool {
        endY <= viewport + tolerance
    }

    /// What the view does once a layout lands.
    public enum Landing: Equatable, Sendable {
        /// At the latest, or on its way there.
        case following
        /// Following, but the latest is out of view and nothing scrolled: scroll to it.
        case catchUp
        /// You scrolled up to read: stay put, show "jump to latest".
        case reading
    }

    /// Where the conversation's top was when the view last saw it scroll. Only scrolling moves the top: a reply laid
    /// out below or a shorter window doesn't, so they never count as you scrolling away, even on a slow Mac where that
    /// layout lands before the view follows it.
    public struct Anchor: Sendable {
        private var top: Double?

        public init() {}

        /// `ownScroll`: the view is scrolling itself to the latest, so moving on the way there isn't you.
        public mutating func landed(top: Double, end: Double, viewport: Double, pinned: Bool, ownScroll: Bool = false) -> Landing {
            let atBottom = ChatScroll.atBottom(endY: end, viewport: viewport)
            if ownScroll && !atBottom {
                self.top = top
                return pinned ? .following : .reading
            }
            // Measured from where it last scrolled, so a slow scroll's half-point steps add up.
            if let last = self.top, abs(top - last) < 1 {
                if atBottom { return .following }
                return pinned ? .catchUp : .reading
            }
            self.top = top
            return atBottom ? .following : .reading
        }
    }

    /// Scroll to the latest: always for what you said and a new view; for new content only if you were already there
    /// (scrolled up to read, you get a "jump to latest" button instead).
    public static func follows(_ change: Change, pinned: Bool) -> Bool {
        switch change {
        case .yourMessage, .switchedView: return true
        case .newContent: return pinned
        }
    }
}
