import Foundation

/// The decision behind "hold fn to talk", without the keyboard: fn alone, held past a moment with no other key,
/// is a hold; a tap, fn+key and fn with another modifier are not. The app feeds it key events and a timer.
public struct FnHold: Equatable {
    public enum Event: Equatable {
        /// fn went down; `withModifiers` when ⌘, ⌥, ⌃ or ⇧ were already held.
        case fnDown(withModifiers: Bool)
        case fnUp
        /// Another modifier changed while fn is down.
        case otherModifier
        /// A key was pressed while fn is down (fn+arrow, fn+delete, fn+F-key).
        case keyDown
    }

    public enum Action: Equatable { case none, startTimer, cancelTimer, startTalking, stopTalking }

    public private(set) var down = false
    public private(set) var holding = false
    private var armed = false

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch event {
        case .fnDown(let withModifiers):
            guard !down else { return .none }
            down = true
            armed = !withModifiers
            return armed ? .startTimer : .none
        case .fnUp:
            down = false
            let wasArmed = armed
            armed = false
            if holding {
                holding = false
                return .stopTalking
            }
            return wasArmed ? .cancelTimer : .none
        case .otherModifier, .keyDown:
            // Before the hold: a shortcut or fn+key, so never a hold. After it: talking carries on.
            guard down, armed, !holding else { return .none }
            armed = false
            return .cancelTimer
        }
    }

    /// The hold delay passed: talk if fn is still down on its own.
    public mutating func timerFired() -> Action {
        guard down, armed, !holding else { return .none }
        holding = true
        return .startTalking
    }
}
