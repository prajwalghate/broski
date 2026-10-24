import Foundation

/// Some recognizer versions start a fresh transcript after a pause instead of extending
/// the old one. This keeps the earlier segments so a dictated note never loses its start.
public struct TranscriptAccumulator {
    private var committed: [String] = []
    private var current = ""

    public init() {}

    public mutating func feed(_ partial: String) {
        if Self.isRestart(previous: current, next: partial) {
            committed.append(current)
        }
        current = partial
    }

    public var text: String {
        (committed + [current]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Revisions rewrite a few words but keep the length; a restart drops to a fraction of it.
    static func isRestart(previous: String, next: String) -> Bool {
        let old = TextTools.tokens(in: previous).count
        let new = TextTools.tokens(in: next).count
        return old >= 3 && new * 2 <= old
    }
}
