import CryptoKit
import Foundation

/// A file Broski downloads (a speech model), pinned to its size and SHA-256 so what runs is what was measured.
/// A download that isn't exactly that file is deleted, never loaded.
public struct PinnedFile: Sendable, Equatable {
    public let name: String
    public let size: Int64
    /// Lowercase hex.
    public let sha256: String

    public init(name: String, size: Int64, sha256: String) {
        self.name = name
        self.size = size
        self.sha256 = sha256
    }

    public enum Mismatch: LocalizedError, Equatable {
        case unreadable(String)
        case size(String, expected: Int64, got: Int64)
        case checksum(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name): return "\(name) couldn't be read, so it was deleted."
            case .size(let name, let expected, let got): return "\(name) is \(got) bytes, not \(expected), so it was deleted."
            case .checksum(let name): return "\(name) didn't match its pinned SHA-256, so it was deleted."
            }
        }
    }

    /// Keeps the file at `url` only when it is exactly this one; otherwise deletes it and throws why.
    public func accept(_ url: URL) throws {
        let found = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        let mismatch: Mismatch
        if let found, found != size {
            mismatch = .size(name, expected: size, got: found)
        } else if found != nil, let hash = Self.sha256(of: url) {
            guard hash != sha256 else { return }
            mismatch = .checksum(name)
        } else {
            mismatch = .unreadable(name)
        }
        try? FileManager.default.removeItem(at: url)
        throw mismatch
    }

    /// Puts a finished download at `target`, replacing what's there, only when it is exactly this file;
    /// otherwise deletes it, leaves `target` alone and throws why.
    public func install(_ staged: URL, at target: URL) throws {
        try accept(staged)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: staged, to: target)
    }

    /// A file is at `url` with this one's size: cheap, for telling it's downloaded. (The hash is checked when it lands.)
    public func isInPlace(at url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 == size
    }

    /// The SHA-256 of a file as lowercase hex, read in pieces (a model is hundreds of MB); nil when it can't be read.
    public static func sha256(of url: URL, pieceSize: Int = 4 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let piece = try handle.read(upToCount: pieceSize), !piece.isEmpty { hash.update(data: piece) }
        } catch {
            return nil
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
