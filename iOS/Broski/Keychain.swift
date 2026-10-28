import Foundation
import Security

/// Model providers' keys on the iPhone, in the Keychain (no password prompts on iOS). Keys never sync.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "broski"
    private static let account = "claude-api-key"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Where a provider's key is kept: Claude's under its first name, every other provider's as "model.<id>", as on the Mac.
    static func account(forProvider id: String) -> String { id == "claude" ? account : "model.\(id)" }

    static func key(forProvider id: String) -> String? { get(account(forProvider: id)) }

    /// Saves a provider's key (nil or empty removes it).
    static func setKey(_ key: String?, forProvider id: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account(forProvider: id)]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
