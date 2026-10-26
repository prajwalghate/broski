import Foundation
#if canImport(Combine)
import Combine

/// The private vault while you use it, on the Mac or the iPhone: made with a passphrase (and a recovery key shown
/// once), opened with the passphrase, Touch ID or Face ID after the first unlock, or the recovery key. Locks itself
/// after five idle minutes; the apps also lock it when its window closes, the device sleeps or the screen locks.
@MainActor
public final class VaultSession: ObservableObject {
    public enum State: Equatable, Sendable {
        case none, locked, open
    }

    @Published public private(set) var state: State = .none
    @Published public private(set) var items: [VaultItem] = []
    @Published public var selected: String?
    @Published public private(set) var busy = false
    @Published public var problem: String?
    /// Shown once, right after the vault is made.
    @Published public var recoveryKey: String?
    @Published public private(set) var touchIDSaved = false
    @Published public var useTouchID = true

    public let root: URL
    private var vault: Vault?
    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var pendingSave: Task<Void, Never>?
    /// "vault: …" from the conversation, waiting for the vault to open. Never written anywhere else.
    private var queued: String?
    public static let idleLimit: TimeInterval = 300

    public init(root: URL) {
        self.root = root
        refresh()
    }

    public var touchIDAvailable: Bool { VaultKeychain.biometryAvailable }

    /// Text for a new note, added as soon as the vault is open (now, if it is).
    public func queue(_ note: String) {
        queued = note
        if state == .open { addQueued() }
    }

    private func addQueued() {
        guard let text = queued, let vault else { return }
        queued = nil
        let title = String(text.split(separator: "\n").first ?? "").prefix(60)
        let item = VaultItem(title: String(title), body: text)
        try? vault.save(item)
        reload()
        selected = item.id
    }

    public func refresh() {
        if vault == nil { state = Vault.exists(root: root) ? .locked : .none }
        touchIDSaved = Vault.id(root: root).map { VaultKeychain.isSaved(vault: $0) } ?? false
    }

    // MARK: Making and opening

    public func create(passphrase: String, confirm: String) {
        guard passphrase == confirm else { return problem = "The two passphrases don't match." }
        run { [root] in try Vault.create(root: root, passphrase: passphrase) } done: { [weak self] made in
            guard let self else { return }
            self.recoveryKey = made.recoveryKey
            self.opened(made.vault)
        }
    }

    public func unlock(passphrase: String) {
        run { [root] in try Vault.unlock(root: root, passphrase: passphrase) } done: { [weak self] in self?.opened($0) }
    }

    public func unlock(recoveryKey: String) {
        run { [root] in try Vault.unlock(root: root, recoveryKey: recoveryKey) } done: { [weak self] in self?.opened($0) }
    }

    public func unlockWithTouchID() {
        guard let id = Vault.id(root: root) else { return }
        busy = true
        problem = nil
        Task {
            defer { busy = false }
            guard let key = await VaultKeychain.load(vault: id, reason: "open your private vault") else { return }
            do {
                opened(try Vault.unlock(root: root, key: key))
            } catch {
                // A key from before a passphrase change, or another vault: forget it, use the passphrase.
                VaultKeychain.remove(vault: id)
                touchIDSaved = false
                problem = (error as? LocalizedError)?.errorDescription
            }
        }
    }

    /// Key stretching takes a moment, so it runs off the main thread.
    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T, done: @escaping (T) -> Void) {
        busy = true
        problem = nil
        Task {
            let result = await Task.detached { Result { try work() } }.value
            busy = false
            switch result {
            case .success(let value): done(value)
            case .failure(let error): problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func opened(_ vault: Vault) {
        self.vault = vault
        state = .open
        reload()
        addQueued()
        // Touch ID after the first unlock, as you chose; never stored without it being on.
        if useTouchID, touchIDAvailable, !VaultKeychain.isSaved(vault: vault.id) {
            touchIDSaved = VaultKeychain.save(vault.keyData, vault: vault.id)
        }
        touched()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, Date().timeIntervalSince(self.lastActivity) > Self.idleLimit else { return }
                self.lock()
            }
        }
    }

    public func lock() {
        queued = nil
        flushSave()
        vault = nil
        items = []
        selected = nil
        recoveryKey = nil
        idleTimer?.invalidate()
        idleTimer = nil
        if state == .open { state = .locked }
    }

    public func touched() { lastActivity = Date() }

    public func setTouchID(_ on: Bool) {
        useTouchID = on
        guard let vault else { return }
        if on {
            touchIDSaved = VaultKeychain.save(vault.keyData, vault: vault.id)
        } else {
            VaultKeychain.remove(vault: vault.id)
            touchIDSaved = false
        }
    }

    public func changePassphrase(_ passphrase: String, confirm: String) -> Bool {
        guard passphrase == confirm else {
            problem = "The two passphrases don't match."
            return false
        }
        guard let vault else { return false }
        do {
            try vault.changePassphrase(to: passphrase)
            problem = nil
            return true
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    // MARK: Notes

    public func reload() {
        items = (try? vault?.items()) ?? []
        if selected == nil || !items.contains(where: { $0.id == selected }) { selected = items.first?.id }
    }

    public func newItem() {
        guard let vault else { return }
        let item = VaultItem(title: "Untitled", body: "")
        try? vault.save(item)
        reload()
        selected = item.id
        touched()
    }

    public func update(_ id: String, title: String? = nil, body: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[index].title = title }
        if let body { items[index].body = body }
        items[index].updated = Date()
        touched()
        // Saved a moment after you stop typing.
        let item = items[index]
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.write(item)
        }
    }

    private func write(_ item: VaultItem) {
        do {
            try vault?.save(item)
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func flushSave() {
        pendingSave?.cancel()
        pendingSave = nil
        if let selected, let item = items.first(where: { $0.id == selected }) { write(item) }
    }

    public func delete(_ id: String) {
        try? vault?.delete(id)
        if selected == id { selected = nil }
        reload()
        touched()
    }
}
#endif
