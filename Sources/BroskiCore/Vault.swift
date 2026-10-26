import CommonCrypto
import CryptoKit
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// One note in the private vault. Stored only encrypted.
public struct VaultItem: Codable, Equatable, Identifiable, Sendable {
    public var format = 1
    public var id: String
    public var title: String
    public var body: String
    public var created: Date
    public var updated: Date

    public init(id: String = UUID().uuidString, title: String, body: String, created: Date = Date(), updated: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.created = created
        self.updated = updated
    }
}

/// The private vault: notes encrypted on the device (AES-256-GCM) with a random vault key, which is itself kept only
/// encrypted, once under your passphrase and once under a recovery key shown when the vault is made. Passphrases are
/// stretched with PBKDF2-SHA256 (600,000 rounds). Nothing that opens the vault is written down; titles are encrypted
/// too; nothing else in Broski reads `vault/` (no search, recall, memory, reflection, MCP or model ever sees it).
/// Files sync through the Broski folder, so iCloud only ever holds ciphertext.
public struct Vault: Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        case exists, missing, weakPassphrase, wrongPassphrase, wrongRecoveryKey, wrongKey, damaged

        public var errorDescription: String? {
            switch self {
            case .exists: return "There's already a vault here."
            case .missing: return "There's no vault yet (or it hasn't finished syncing to this device)."
            case .weakPassphrase: return "Use at least \(Vault.minimumLength) characters. A few unrelated words works well."
            case .wrongPassphrase: return "That passphrase doesn't open the vault."
            case .wrongRecoveryKey: return "That recovery key doesn't open the vault."
            case .wrongKey: return "The saved key no longer opens the vault. Unlock with your passphrase."
            case .damaged: return "The vault's key file can't be read."
            }
        }
    }

    public static let iterations = 600_000
    public static let minimumLength = 10

    struct Wrap: Codable {
        var salt: Data
        /// The vault key, sealed with the key stretched from the secret.
        var sealed: Data
    }

    struct Header: Codable {
        var format = 1
        var id: String
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var passphrase: Wrap
        var recovery: Wrap
        /// A known value sealed with the vault key, to tell a stale saved key from the right one.
        var check: Data
    }

    public let root: URL
    let key: SymmetricKey
    /// Which vault this is (the Keychain entry for Touch ID is per vault).
    public let id: String

    public static func folder(_ root: URL) -> URL { root.appendingPathComponent("vault", isDirectory: true) }
    static func headerURL(_ root: URL) -> URL { folder(root).appendingPathComponent("vault.json") }
    static func itemsFolder(_ root: URL) -> URL { folder(root).appendingPathComponent("items", isDirectory: true) }

    /// A vault is here, or is still on its way from iCloud (never offer to make a second one over it).
    public static func exists(root: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: headerURL(root).path) || fm.fileExists(atPath: folder(root).appendingPathComponent(".vault.json.icloud").path)
    }

    /// The vault key, for keeping behind Touch ID or Face ID.
    public var keyData: Data { key.withUnsafeBytes { Data($0) } }

    // MARK: Making and opening

    /// Makes the vault and returns it with its recovery key, which is shown once and never stored.
    public static func create(root: URL, passphrase: String, iterations: Int = iterations) throws -> (vault: Vault, recoveryKey: String) {
        guard !exists(root: root) else { throw Failure.exists }
        guard passphrase.count >= minimumLength else { throw Failure.weakPassphrase }
        let key = SymmetricKey(size: .bits256)
        let recovery = recoveryKey(from: random(20))
        let header = Header(id: UUID().uuidString, iterations: iterations,
                            passphrase: try wrap(key, secret: Data(passphrase.utf8), iterations: iterations),
                            recovery: try wrap(key, secret: Data(normalized(recovery).utf8), iterations: iterations),
                            check: try AES.GCM.seal(Data("broski-vault".utf8), using: key).combined ?? Data())
        try FileManager.default.createDirectory(at: itemsFolder(root), withIntermediateDirectories: true)
        try write(header, root: root)
        return (Vault(root: root, key: key, id: header.id), recovery)
    }

    public static func unlock(root: URL, passphrase: String) throws -> Vault {
        let header = try load(root)
        guard let key = unwrap(header.passphrase, secret: Data(passphrase.utf8), iterations: header.iterations) else { throw Failure.wrongPassphrase }
        return Vault(root: root, key: key, id: header.id)
    }

    public static func unlock(root: URL, recoveryKey: String) throws -> Vault {
        let header = try load(root)
        let secret = normalized(recoveryKey)
        guard !secret.isEmpty, let key = unwrap(header.recovery, secret: Data(secret.utf8), iterations: header.iterations) else {
            throw Failure.wrongRecoveryKey
        }
        return Vault(root: root, key: key, id: header.id)
    }

    /// With the key Touch ID or Face ID handed back.
    public static func unlock(root: URL, key data: Data) throws -> Vault {
        let header = try load(root)
        let key = SymmetricKey(data: data)
        guard let box = try? AES.GCM.SealedBox(combined: header.check), (try? AES.GCM.open(box, using: key)) != nil else { throw Failure.wrongKey }
        return Vault(root: root, key: key, id: header.id)
    }

    /// The vault's id without opening it (for its Touch ID entry).
    public static func id(root: URL) -> String? { try? load(root).id }

    public func changePassphrase(to passphrase: String) throws {
        guard passphrase.count >= Self.minimumLength else { throw Failure.weakPassphrase }
        var header = try Self.load(root)
        header.passphrase = try Self.wrap(key, secret: Data(passphrase.utf8), iterations: header.iterations)
        try Self.write(header, root: root)
    }

    // MARK: Notes

    /// Every note, most recently changed first. A file that doesn't open (damaged, or half-synced) is skipped.
    public func items() throws -> [VaultItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.itemsFolder(root), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "vault" }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key) else { return nil }
            return try? JSONLines.decoder.decode(VaultItem.self, from: plain)
        }
        .sorted { $0.updated == $1.updated ? $0.title < $1.title : $0.updated > $1.updated }
    }

    public func save(_ item: VaultItem) throws {
        let sealed = try AES.GCM.seal(try JSONLines.encoder.encode(item), using: key)
        guard let combined = sealed.combined else { throw Failure.damaged }
        try FileManager.default.createDirectory(at: Self.itemsFolder(root), withIntermediateDirectories: true)
        try combined.write(to: Self.itemsFolder(root).appendingPathComponent("\(Self.fileName(item.id)).vault"), options: [.atomic, .completeFileProtection])
    }

    public func delete(_ id: String) throws {
        let file = Self.itemsFolder(root).appendingPathComponent("\(Self.fileName(id)).vault")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    /// Item ids are UUIDs; anything else can't become a path.
    static func fileName(_ id: String) -> String { id.filter { $0.isLetter || $0.isNumber || $0 == "-" } }

    // MARK: Keys

    static func load(_ root: URL) throws -> Header {
        guard let data = try? Data(contentsOf: headerURL(root)) else { throw Failure.missing }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.format == 1 else { throw Failure.damaged }
        return header
    }

    static func write(_ header: Header, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(header).write(to: headerURL(root), options: .atomic)
    }

    static func wrap(_ key: SymmetricKey, secret: Data, iterations: Int) throws -> Wrap {
        let salt = random(16)
        let sealed = try AES.GCM.seal(key.withUnsafeBytes { Data($0) }, using: stretch(secret, salt: salt, iterations: iterations))
        guard let combined = sealed.combined else { throw Failure.damaged }
        return Wrap(salt: salt, sealed: combined)
    }

    static func unwrap(_ wrap: Wrap, secret: Data, iterations: Int) -> SymmetricKey? {
        guard !secret.isEmpty, let box = try? AES.GCM.SealedBox(combined: wrap.sealed),
              let raw = try? AES.GCM.open(box, using: stretch(secret, salt: wrap.salt, iterations: iterations)) else { return nil }
        return SymmetricKey(data: raw)
    }

    /// PBKDF2-HMAC-SHA256 to a 256-bit key.
    static func stretch(_ secret: Data, salt: Data, iterations: Int) -> SymmetricKey {
        var out = Data(count: 32)
        out.withUnsafeMutableBytes { outBytes in
            secret.withUnsafeBytes { secretBytes in
                salt.withUnsafeBytes { saltBytes in
                    _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                             secretBytes.baseAddress?.assumingMemoryBound(to: Int8.self), secret.count,
                                             saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                             CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                             outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        return SymmetricKey(data: out)
    }

    static func random(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: Recovery keys

    /// Crockford base32: no I, L, O or U, so it's hard to misread or mistype.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 160 random bits as eight groups of four: "7K3M-Q9XD-…".
    static func recoveryKey(from bytes: Data) -> String {
        var bits = 0, value = 0
        var chars: [Character] = []
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                chars.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: "-")
    }

    /// As typed: any case, spaces or dashes, and the letters people mix up with digits.
    static func normalized(_ typed: String) -> String {
        String(typed.uppercased().compactMap { char -> Character? in
            switch char {
            case "O": return "0"
            case "I", "L": return "1"
            default: return alphabet.contains(char) ? char : nil
            }
        })
    }
}

#if canImport(LocalAuthentication)
/// The vault key behind Touch ID or Face ID, so after the first unlock a touch opens the vault. On the iPhone the
/// Keychain item itself needs Face ID; on the Mac it's in the login Keychain for Broski alone, and Broski asks for
/// Touch ID before reading it. Other apps can't read it without your permission. Turning it off deletes it.
public enum VaultKeychain {
    private static let service = "Broski Vault"

    private static func query(_ vault: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: vault]
    }

    public static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    @discardableResult
    public static func save(_ key: Data, vault: String) -> Bool {
        remove(vault: vault)
        var item = query(vault)
        item[kSecValueData as String] = key
        #if os(iOS)
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, nil) else { return false }
        item[kSecAttrAccessControl as String] = access
        #endif
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func isSaved(vault: String) -> Bool {
        var item = query(vault)
        #if os(iOS)
        // Ask whether it's there without showing Face ID.
        let context = LAContext()
        context.interactionNotAllowed = true
        item[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(item as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
        #else
        item[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(item as CFDictionary, nil) == errSecSuccess
        #endif
    }

    /// The key after Touch ID or Face ID; nil if you cancel or it isn't there.
    public static func load(vault: String, reason: String) async -> Data? {
        let context = LAContext()
        #if os(macOS)
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true else { return nil }
        #else
        context.localizedReason = reason
        #endif
        var item = query(vault)
        item[kSecReturnData as String] = true
        item[kSecUseAuthenticationContext as String] = context
        return await Task.detached {
            var result: AnyObject?
            guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }.value
    }

    @discardableResult
    public static func remove(vault: String) -> Bool {
        SecItemDelete(query(vault) as CFDictionary) == errSecSuccess
    }
}
#endif
