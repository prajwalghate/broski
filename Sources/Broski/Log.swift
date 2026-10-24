import Foundation
import os

/// Event log: unified logging plus ~/Broski/.broski/broski.log.
/// Only events go here. Wake-mode transcripts (what the room says) are never logged.
enum Log {
    private static let logger = Logger(subsystem: "dev.broski.app", category: "app")
    private static let queue = DispatchQueue(label: "dev.broski.log")
    static var fileURL: URL?

    /// Waits for queued lines to reach the file.
    static func flush() { queue.sync {} }

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        guard let url = fileURL else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
