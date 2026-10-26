import BroskiCore
import SwiftUI
import UniformTypeIdentifiers

/// The private vault on the iPhone: the same encrypted vault as the Mac's (through your Broski folder), opened with
/// your passphrase, Face ID after the first unlock, or the recovery key. Locks when Broski leaves the screen, and hides
/// its contents in the app switcher.
struct VaultScreen: View {
    @ObservedObject var session: VaultSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var recovery = ""
    @State private var usingRecovery = false
    @State private var savedKey = false
    @State private var confirmDelete: String?

    var body: some View {
        NavigationStack {
            Group {
                if let key = session.recoveryKey {
                    recoveryScreen(key)
                } else {
                    switch session.state {
                    case .none: createScreen
                    case .locked: lockedScreen
                    case .open: list
                    }
                }
            }
            .navigationTitle("Private vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { session.lock(); dismiss() } }
                if session.state == .open, session.recoveryKey == nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { session.lock() } label: { Image(systemName: "lock") }.accessibilityLabel("Lock")
                        Button { session.newItem() } label: { Image(systemName: "plus") }.accessibilityLabel("New note")
                    }
                }
            }
        }
        // Nothing from the vault in the app switcher, and it locks when Broski leaves the screen.
        .overlay { if phase != .active { Color(.systemBackground).ignoresSafeArea().overlay(Image(systemName: "lock.shield").font(.largeTitle)) } }
        .onChange(of: phase) { _, new in if new == .background { session.lock() } }
        .onAppear { session.refresh() }
    }

    // MARK: Make

    private var createScreen: some View {
        Form {
            Section {
                Label("Encrypted on your devices with a key only your passphrase opens.", systemImage: "checkmark.shield")
                Label("Never read by any model, search, memory or Claude Code.", systemImage: "checkmark.shield")
                Label("You'll get a recovery key once. Lose both, and nobody can open it.", systemImage: "checkmark.shield")
            }
            .font(.callout)
            Section {
                SecureField("Passphrase (\(Vault.minimumLength)+ characters)", text: $passphrase)
                SecureField("The same again", text: $confirm)
                if session.touchIDAvailable { Toggle("Open with Face ID after this", isOn: $session.useTouchID) }
            } footer: {
                if let problem = session.problem { Text(problem).foregroundStyle(.orange) }
            }
            Button {
                session.create(passphrase: passphrase, confirm: confirm)
                passphrase = ""
                confirm = ""
            } label: {
                HStack { Text("Create vault"); if session.busy { Spacer(); ProgressView() } }
            }
            .disabled(session.busy || passphrase.count < Vault.minimumLength || confirm.isEmpty)
        }
    }

    private func recoveryScreen(_ key: String) -> some View {
        Form {
            Section {
                Text(key).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                Button("Copy for one minute") {
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: key]],
                                                  options: [.expirationDate: Date().addingTimeInterval(60), .localOnly: true])
                }
            } header: {
                Text("Your recovery key")
            } footer: {
                Text("If you forget your passphrase, this opens the vault. It's shown only now and stored nowhere. Write it down or keep it in your password manager.")
            }
            Toggle("I've saved my recovery key", isOn: $savedKey)
            Button("Continue") { session.recoveryKey = nil }.disabled(!savedKey)
        }
    }

    // MARK: Open

    private var lockedScreen: some View {
        Form {
            if usingRecovery {
                Section {
                    TextField("Recovery key", text: $recovery).font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button("Open with recovery key") { session.unlock(recoveryKey: recovery); recovery = "" }
                        .disabled(recovery.isEmpty || session.busy)
                }
            } else {
                Section {
                    SecureField("Passphrase", text: $passphrase).onSubmit { unlock() }
                    Button("Unlock") { unlock() }.disabled(passphrase.isEmpty || session.busy)
                    if session.touchIDSaved {
                        Button { session.unlockWithTouchID() } label: { Label("Face ID", systemImage: "faceid") }.disabled(session.busy)
                    }
                }
            }
            Section {
                Button(usingRecovery ? "Use my passphrase" : "Forgot it? Use the recovery key") { usingRecovery.toggle() }
            } footer: {
                if let problem = session.problem { Text(problem).foregroundStyle(.orange) }
            }
        }
        .onAppear { if session.touchIDSaved { session.unlockWithTouchID() } }
    }

    private func unlock() {
        session.unlock(passphrase: passphrase)
        passphrase = ""
    }

    private var list: some View {
        List {
            if session.items.isEmpty {
                Text("Your vault is empty. Tap + for a note.").foregroundStyle(.secondary)
            }
            ForEach(session.items) { item in
                NavigationLink { editor(item.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.isEmpty ? "Untitled" : item.title).lineLimit(1)
                        Text(item.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in confirmDelete = offsets.first.map { session.items[$0].id } }
            Section {
                if session.touchIDAvailable {
                    Toggle("Open with Face ID", isOn: Binding(get: { session.touchIDSaved }, set: { session.setTouchID($0) }))
                }
            } footer: {
                Text("Locks after 5 minutes idle or when you leave Broski. Never read by any model, search, memory or Claude Code.")
            }
        }
        .alert("Delete this note from the vault?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let id = confirmDelete { session.delete(id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("It's gone for good: there's no copy anywhere.")
        }
        .simultaneousGesture(TapGesture().onEnded { session.touched() })
    }

    private func editor(_ id: String) -> some View {
        Form {
            if let item = session.items.first(where: { $0.id == id }) {
                TextField("Title", text: Binding(get: { item.title }, set: { session.update(id, title: $0) })).font(.headline)
                TextEditor(text: Binding(get: { item.body }, set: { session.update(id, body: $0) })).frame(minHeight: 280)
            }
        }
        .navigationTitle("Note")
    }
}
