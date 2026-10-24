import Foundation
import Security

/// Secrets (the Claude API key, a Slack webhook), stored in a file only your user can read:
/// ~/Library/Application Support/Broski/secrets.json (mode 600), cached in memory after the first read.
///
/// Not the keychain: ad-hoc-signed beta builds get a new code signature on every build, and the
/// keychain asks for your login password each time such an app touches an item.
enum Secrets {
    static let claudeKey = "anthropic-api-key"
    static let slackWebhook = "slack-webhook"

    private static var cache: [String: String]?
    private static let lock = NSLock()

    static var file: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Broski", isDirectory: true)
            .appendingPathComponent("secrets.json")
    }

    static func get(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[name]
    }

    /// Saves the value, or removes it when empty.
    @discardableResult
    static func set(_ value: String?, for name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var all = load()
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        all[name] = trimmed.isEmpty ? nil : trimmed
        // Only what's on disk counts: a failed write mustn't look saved now and vanish (or come back) on restart.
        guard write(all) else { return false }
        cache = all
        return true
    }

    /// The saved names starting with `prefix`, without it ("webhook." → ["team", "alerts"]).
    static func names(withPrefix prefix: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return load().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }

    private static func load() -> [String: String] {
        if let cache { return cache }
        var all = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        // The keychain copies go only once the file holds them.
        if !UserDefaults.standard.bool(forKey: migratedKey), !migrateFromKeychain(into: &all) || write(all) {
            finishMigration()
        }
        cache = all
        return all
    }

    private static func write(_ all: [String: String]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(all)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            Log.info("Couldn't save secrets: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: One-time move from the keychain (0.3 builds stored secrets there)

    private static let migratedKey = "BroskiSecretsMovedFromKeychain"

    private static func keychainItem(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.broski.app", kSecAttrAccount as String: name]
    }

    /// Copies keys the 0.3 builds kept in the keychain into `all`. May show one last keychain prompt.
    private static func migrateFromKeychain(into all: inout [String: String]) -> Bool {
        var changed = false
        for name in [claudeKey, slackWebhook] where all[name] == nil {
            var query = keychainItem(name)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, let value = String(data: data, encoding: .utf8), !value.isEmpty {
                all[name] = value
                changed = true
            }
        }
        if changed { Log.info("Moved saved keys out of the keychain") }
        return changed
    }

    /// After this the keychain is never touched again.
    private static func finishMigration() {
        for name in [claudeKey, slackWebhook] { SecItemDelete(keychainItem(name) as CFDictionary) }
        UserDefaults.standard.set(true, forKey: migratedKey)
    }
}
