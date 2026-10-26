import Foundation
import Testing
@testable import BroskiCore

/// The private vault: notes encrypted on the device with a key only your passphrase (or your recovery key) opens.
/// Nothing that opens it is written down, nothing in it is readable on disk, and nothing else in Broski reads it.
@Suite("Private vault")
struct VaultTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broski-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fast key stretching for tests; the real vault uses Vault.iterations.
    private let fast = 1_000
    private let day = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z")!

    @Test("creating a vault gives a recovery key once; what's saved can't be read without the passphrase")
    func createAndEncrypt() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!Vault.exists(root: root))
        let (vault, recovery) = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        #expect(Vault.exists(root: root))
        #expect(recovery.count == 39 && recovery.split(separator: "-").count == 8, "eight groups of four, easy to write down")
        let item = VaultItem(title: "Bank PIN hint", body: "The one from the old flat, backwards.", created: day, updated: day)
        try vault.save(item)

        var everything = Data()
        for file in FileManager.default.enumerator(at: Vault.folder(root), includingPropertiesForKeys: nil)!.compactMap({ $0 as? URL })
        where !file.hasDirectoryPath {
            everything += try Data(contentsOf: file)
        }
        let text = String(decoding: everything, as: UTF8.self)
        #expect(!text.contains("Bank PIN") && !text.contains("old flat") && !text.contains("correct horse"))
        #expect(!text.contains(recovery.replacingOccurrences(of: "-", with: "")))
        #expect(try vault.items() == [item])
    }

    @Test("the wrong passphrase opens nothing; the passphrase or the recovery key (any case, any spacing) opens it")
    func unlock() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (vault, recovery) = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        try vault.save(VaultItem(title: "A", body: "B", created: day, updated: day))
        #expect(throws: Vault.Failure.wrongPassphrase) { try Vault.unlock(root: root, passphrase: "correct horse battery stapler") }
        #expect(try Vault.unlock(root: root, passphrase: "correct horse battery staple").items().count == 1)
        let typed = recovery.lowercased().replacingOccurrences(of: "-", with: " ")
        #expect(try Vault.unlock(root: root, recoveryKey: typed).items().count == 1)
        #expect(throws: Vault.Failure.wrongRecoveryKey) { try Vault.unlock(root: root, recoveryKey: "AAAA-BBBB") }
    }

    @Test("a short passphrase is refused, and a vault is never created over another")
    func refusals() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Vault.Failure.weakPassphrase) { try Vault.create(root: root, passphrase: "short", iterations: fast) }
        _ = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        #expect(throws: Vault.Failure.exists) { try Vault.create(root: root, passphrase: "another long passphrase", iterations: fast) }
    }

    @Test("changing the passphrase keeps every note; the old one stops working; the recovery key still works")
    func changePassphrase() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (vault, recovery) = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        try vault.save(VaultItem(title: "A", body: "B", created: day, updated: day))
        try vault.changePassphrase(to: "a brand new long passphrase")
        #expect(throws: Vault.Failure.wrongPassphrase) { try Vault.unlock(root: root, passphrase: "correct horse battery staple") }
        #expect(try Vault.unlock(root: root, passphrase: "a brand new long passphrase").items().count == 1)
        #expect(try Vault.unlock(root: root, recoveryKey: recovery).items().count == 1)
    }

    @Test("editing, deleting, and a damaged file that's skipped rather than breaking the vault")
    func items() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (vault, _) = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        var first = VaultItem(title: "First", body: "one", created: day, updated: day)
        let second = VaultItem(title: "Second", body: "two", created: day, updated: day.addingTimeInterval(60))
        try vault.save(first)
        try vault.save(second)
        first.body = "one, edited"
        first.updated = day.addingTimeInterval(120)
        try vault.save(first)
        #expect(try vault.items().map(\.title) == ["First", "Second"], "most recently changed first")
        #expect(try vault.items().first?.body == "one, edited")
        try vault.delete(second.id)
        try Data("not a vault entry".utf8).write(to: Vault.folder(root).appendingPathComponent("items/broken.vault"))
        #expect(try vault.items().map(\.title) == ["First"])
    }

    @Test("Touch ID's stored key opens the vault; any other key doesn't")
    func storedKey() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (vault, _) = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        try vault.save(VaultItem(title: "A", body: "B", created: day, updated: day))
        #expect(try Vault.unlock(root: root, key: vault.keyData).items().count == 1)
        #expect(throws: Vault.Failure.wrongKey) { try Vault.unlock(root: root, key: Data(repeating: 7, count: 32)) }
    }

    @Test("“vault: …” goes straight to the vault, never to a model; “open my vault” opens it")
    func commands() {
        #expect(ConversationCommand.parse("vault: the spare key is under the blue pot", catalog: nil) == .toVault("the spare key is under the blue pot"))
        #expect(ConversationCommand.parse("Open my vault", catalog: nil) == .openVault)
        #expect(ConversationCommand.parse("open the vault.", catalog: nil) == .openVault)
        #expect(ConversationCommand.parse("what's a vault in banking?", catalog: nil) == nil)
    }

    @Test("the vault is never a project, a note, or anything else Broski reads")
    func isolated() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let (vault, _) = try Vault.create(root: root, passphrase: "correct horse battery staple", iterations: fast)
        try vault.save(VaultItem(title: "Secret", body: "secret", created: day, updated: day))
        let store = ItemStore(root: root)
        #expect(!store.projectNames().contains("vault") && store.allItems().isEmpty)
        #expect(WebReader.saved(root: root).isEmpty && Resources.list(root: root, project: nil).isEmpty)
        #expect(try store.migrateLegacyNotes() == 0)
        #expect(Vault.exists(root: root))
    }
}
