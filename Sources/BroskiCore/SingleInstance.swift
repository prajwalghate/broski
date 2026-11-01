import Foundation

/// One Broski at a time. Opening it again while it runs (Spotlight finding a build or a kept copy, a second click)
/// hands over to the one already running instead of starting a second, which would hold the mic and the shortcuts
/// twice, show two menu-bar icons and write the same files.
public enum SingleInstance {
    /// A running copy of Broski, as the system lists it.
    public struct Running: Equatable, Sendable {
        public var pid: Int32
        public var path: String
        public var terminated: Bool

        public init(pid: Int32, path: String, terminated: Bool) {
            self.pid = pid
            self.path = path
            self.terminated = terminated
        }
    }

    public enum Decision: Equatable, Sendable {
        /// No other Broski runs: start.
        case run
        /// Show the one already running and don't start.
        case handOver(Int32)
        /// This is the installed copy and a build or a kept copy got there first: quit that one, then start.
        case replace(Int32)
    }

    /// What a starting Broski does, given every running copy (itself included). The installed copy stays; otherwise
    /// the one that was there first does.
    public static func decide(_ running: [Running], me: Int32, installed: String) -> Decision {
        guard let other = running.first(where: { $0.pid != me && !$0.terminated }) else { return .run }
        let mine = running.first { $0.pid == me }?.path
        if mine == installed, other.path != installed { return .replace(other.pid) }
        return .handOver(other.pid)
    }
}
