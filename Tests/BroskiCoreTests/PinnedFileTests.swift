import CryptoKit
import Foundation
import Testing
@testable import BroskiCore

/// A downloaded model is kept only when it is exactly the file that was measured: its pinned size and SHA-256.
/// Anything else is deleted before it can load, and the person is told why.
@Suite("Pinned downloads")
struct PinnedFileTests {
    /// "abc", whose SHA-256 is the standard's own test vector (FIPS 180-2).
    private let abc = PinnedFile(name: "model.bin", size: 3, sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

    private func download(_ bytes: Data) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broski-pinned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("model.bin.part")
        try bytes.write(to: url)
        return url
    }

    @Test("a download with its pinned hash is kept")
    func matchingKept() throws {
        let url = try download(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try abc.accept(url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a download with one byte changed is deleted, with an error that says why")
    func changedByteDeleted() throws {
        let url = try download(Data("abd".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: PinnedFile.Mismatch.checksum("model.bin")) { try abc.accept(url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let message = PinnedFile.Mismatch.checksum("model.bin").localizedDescription
        #expect(message.contains("model.bin") && message.contains("SHA-256") && message.contains("deleted"))
    }

    @Test("a download of the wrong size is deleted too")
    func wrongSizeDeleted() throws {
        let url = try download(Data("abcd".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: PinnedFile.Mismatch.size("model.bin", expected: 3, got: 4)) { try abc.accept(url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a download that isn't there is refused")
    func missingRefused() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-pinned-\(UUID().uuidString).part")
        #expect(throws: PinnedFile.Mismatch.unreadable("model.bin")) { try abc.accept(url) }
    }

    @Test("a download that passes replaces what was at the model's place")
    func installReplaces() throws {
        let staged = try download(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        let target = staged.deletingLastPathComponent().appendingPathComponent("model.bin")
        try Data("cut short".utf8).write(to: target)
        try abc.install(staged, at: target)
        #expect(try Data(contentsOf: target) == Data("abc".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    @Test("a download that fails the check never reaches the model's place, and nothing is left of it")
    func refusedNeverInstalled() throws {
        let staged = try download(Data("abd".utf8))
        let folder = staged.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("model.bin")
        #expect(throws: PinnedFile.Mismatch.checksum("model.bin")) { try abc.install(staged, at: target) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test("a model counts as downloaded only at its pinned size")
    func inPlaceBySize() throws {
        let url = try download(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(abc.isInPlace(at: url))
        try Data("ab".utf8).write(to: url)
        #expect(!abc.isInPlace(at: url))
        #expect(!abc.isInPlace(at: url.deletingLastPathComponent().appendingPathComponent("missing.bin")))
    }

    @Test("a file read in pieces hashes the same as read whole")
    func piecesMatchWhole() throws {
        let bytes = Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = try download(bytes)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let whole = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(PinnedFile.sha256(of: url, pieceSize: 7) == whole)
        #expect(PinnedFile.sha256(of: url) == whole)
    }
}
