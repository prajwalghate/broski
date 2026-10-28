import Foundation
import Testing
@testable import BroskiCore

/// The everyday behaviour of a chat box and a conversation, as in every chat app.
@Suite("Chat basics")
struct ChatBasicsTests {
    @Test("Return sends; Shift, Option or Control with Return starts a new line; Command-Return sends too")
    func returnKey() {
        #expect(ComposerKey.action(.returnKey) == .send)
        #expect(ComposerKey.action(.returnKey, shift: true) == .newLine)
        #expect(ComposerKey.action(.returnKey, option: true) == .newLine)
        #expect(ComposerKey.action(.returnKey, control: true) == .newLine)
        #expect(ComposerKey.action(.returnKey, command: true) == .send)
        #expect(ComposerKey.action(.returnKey, shift: true, command: true) == .send)
    }

    @Test("while an input method is composing, Return and Up belong to it")
    func composing() {
        #expect(ComposerKey.action(.returnKey, composing: true) == .normal)
        #expect(ComposerKey.action(.returnKey, shift: true, composing: true) == .normal)
        #expect(ComposerKey.action(.up, composing: true, empty: true) == .normal)
    }

    @Test("Up in an empty box brings back your last message; with text it moves the cursor as usual")
    func upArrow() {
        #expect(ComposerKey.action(.up, empty: true) == .recallLast)
        #expect(ComposerKey.action(.up, empty: false) == .normal)
        #expect(ComposerKey.action(.up, shift: true, empty: true) == .normal)
        #expect(ComposerKey.action(.other, empty: true) == .normal)
    }

    @Test("at the bottom means the conversation's end is in view, give or take a little")
    func atBottom() {
        #expect(ChatScroll.atBottom(endY: 500, viewport: 500))
        #expect(ChatScroll.atBottom(endY: 540, viewport: 500))
        #expect(!ChatScroll.atBottom(endY: 900, viewport: 500))
        // Shorter than the window: always at the bottom.
        #expect(ChatScroll.atBottom(endY: 120, viewport: 500))
    }

    /// A view following at the latest: the conversation's top at -1500 in a 500-point window, its end at the bottom.
    private func atTheLatest() -> ChatScroll.Anchor {
        var anchor = ChatScroll.Anchor()
        _ = anchor.landed(top: -1500, end: 500, viewport: 500, pinned: true)
        return anchor
    }

    // On a slow Mac the new reply can be laid out (its end below the window) before the view gets to follow it.
    @Test("a reply laid out below you before the view follows it is still followed")
    func contentGrowingKeepsFollowing() {
        var anchor = atTheLatest()
        // A 140-point reply lands below; nobody scrolled.
        #expect(anchor.landed(top: -1500, end: 640, viewport: 500, pinned: true) == .catchUp)
        // The box grew and the window got shorter; still nobody scrolled.
        anchor = atTheLatest()
        #expect(anchor.landed(top: -1500, end: 560, viewport: 440, pinned: true) == .catchUp)
        // Scrolled up to read: replies arriving below leave you there.
        anchor = atTheLatest()
        _ = anchor.landed(top: -400, end: 1600, viewport: 500, pinned: true)
        #expect(anchor.landed(top: -400, end: 1800, viewport: 500, pinned: false) == .reading)
    }

    @Test("scrolling up stops following; scrolling back to the end follows again")
    func scrollingDecides() {
        var anchor = atTheLatest()
        #expect(anchor.landed(top: -1000, end: 1000, viewport: 500, pinned: true) == .reading)
        #expect(anchor.landed(top: -1500, end: 500, viewport: 500, pinned: false) == .following)
        // Shorter than the window: always at the bottom.
        var short = ChatScroll.Anchor()
        #expect(short.landed(top: 0, end: 120, viewport: 500, pinned: false) == .following)
    }

    @Test("a slow scroll up, half a point at a time, stops following")
    func slowScrollUp() {
        var anchor = atTheLatest()
        var top = -1500.0, landing = ChatScroll.Landing.following
        for _ in 0..<400 {
            top += 0.5
            landing = anchor.landed(top: top, end: top + 2000, viewport: 500, pinned: landing != .reading)
        }
        #expect(landing == .reading)
    }

    @Test("the view's own scroll to the latest isn't you scrolling up")
    func ownScroll() {
        var anchor = ChatScroll.Anchor()
        _ = anchor.landed(top: 16, end: 2500, viewport: 500, pinned: true)
        // On its way down from the top, and slower than the follow window on a starved Mac.
        #expect(anchor.landed(top: -900, end: 1600, viewport: 500, pinned: true, ownScroll: true) == .following)
        #expect(anchor.landed(top: -1984, end: 516, viewport: 500, pinned: true, ownScroll: false) == .following)
    }

    @Test("what you say and a new view always scroll to the latest; replies only if you were already there")
    func following() {
        #expect(ChatScroll.follows(.yourMessage, pinned: false))
        #expect(ChatScroll.follows(.switchedView, pinned: false))
        #expect(ChatScroll.follows(.newContent, pinned: true))
        #expect(!ChatScroll.follows(.newContent, pinned: false))
    }
}

/// Replies are markdown, but a Text only renders inline markdown: headings, quotes and lists would show as "##", ">"
/// and "-". Web addresses are links, in replies and in what you said.
@Suite("Reply text")
struct ReplyTextTests {
    private func string(_ text: AttributedString) -> String { String(text.characters) }

    private func isBold(_ text: AttributedString, _ word: String) -> Bool {
        guard let range = text.range(of: word) else { return false }
        return text[range].runs.allSatisfy { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
    }

    private func link(_ text: AttributedString, _ word: String) -> URL? {
        guard let range = text.range(of: word) else { return nil }
        return text[range].runs.first?.link
    }

    @Test("headings read as bold lines, quotes and list markers as what they mean")
    func blocks() {
        let text = ReplyText.rendered("## Plan\n**Ship** it today\n- first\n  * nested\n> a quote\n1. numbered")
        #expect(string(text) == "Plan\nShip it today\n• first\n  • nested\na quote\n1. numbered")
        #expect(isBold(text, "Plan") && isBold(text, "Ship"))
        #expect(!isBold(text, "today"))
    }

    @Test("code blocks keep their characters; stars inside aren't emphasis")
    func codeBlocks() {
        let text = ReplyText.rendered("Run this:\n```\nlet a = b * c * d\n```\nDone.")
        #expect(string(text) == "Run this:\nlet a = b * c * d\nDone.")
    }

    @Test("bare web addresses become links; markdown links keep theirs")
    func links() {
        let reply = ReplyText.rendered("See https://example.com/docs. Or [the guide](https://example.org/guide).")
        #expect(link(reply, "https://example.com/docs") == URL(string: "https://example.com/docs"))
        #expect(link(reply, "the guide") == URL(string: "https://example.org/guide"))
        #expect(string(reply) == "See https://example.com/docs. Or the guide.")
    }

    @Test("what you said isn't read as markdown, but its links work")
    func yourWords() {
        let said = ReplyText.plain("a*b*c and _this_ at https://example.com")
        #expect(string(said) == "a*b*c and _this_ at https://example.com")
        #expect(link(said, "https://example.com") == URL(string: "https://example.com"))
    }

    @Test("a piece that starts mid-line (after a citation) isn't taken for a list or heading")
    func midLine() {
        #expect(string(ReplyText.rendered("- after a citation", atLineStart: false)) == "- after a citation")
        #expect(string(ReplyText.rendered(" - and then\n- a list", atLineStart: false)) == " - and then\n• a list")
    }
}
