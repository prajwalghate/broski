import AppKit
import BroskiCore
import SwiftUI

struct VaultView: View {
    @ObservedObject var model: VaultSession
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var recovery = ""
    @State private var usingRecovery = false
    @State private var savedKey = false
    @State private var changing = false
    @State private var confirmDelete: String?

    var body: some View {
        Group {
            if let key = model.recoveryKey {
                recoveryScreen(key)
            } else {
                switch model.state {
                case .none: createScreen
                case .locked: lockedScreen
                case .open: openScreen
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.refresh() }
    }

    // MARK: Make

    private var createScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Private vault", systemImage: "lock.shield").font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                bullet("Notes here are encrypted on this device with a key only your passphrase opens.")
                bullet("Nothing in it goes to any model, search, memory or Claude Code, and nothing that opens it is stored.")
                bullet("It syncs to your iPhone through your Broski folder; iCloud only ever sees scrambled data.")
                bullet("You'll get a recovery key once. Lose both it and your passphrase, and nobody can open the vault.")
            }
            SecureField("Passphrase (at least \(Vault.minimumLength) characters; a few unrelated words works well)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            SecureField("The same passphrase again", text: $confirm)
                .textFieldStyle(.roundedBorder)
                .onSubmit { create() }
            if model.touchIDAvailable {
                Toggle("Open it with Touch ID after the first unlock", isOn: $model.useTouchID)
            }
            HStack {
                problemText
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Create vault") { create() }
                    .buttonStyle(.borderedProminent).tint(Brand.purple)
                    .disabled(model.busy || passphrase.count < Vault.minimumLength || confirm.isEmpty)
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
    }

    private func create() {
        model.create(passphrase: passphrase, confirm: confirm)
        passphrase = ""
        confirm = ""
    }

    private func recoveryScreen(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your recovery key", systemImage: "key").font(.system(size: 20, weight: .semibold))
            Text("If you forget your passphrase, this key opens the vault. It's shown only now and stored nowhere. Write it down or keep it in your password manager.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(key)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Brand.purple.opacity(0.1)))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    // Don't leave it on the clipboard.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                        if NSPasteboard.general.string(forType: .string) == key { NSPasteboard.general.clearContents() }
                    }
                }
                .help("Copies it for a minute, then clears the clipboard")
                Spacer()
                Toggle("I've saved my recovery key", isOn: $savedKey)
                Button("Continue") { model.recoveryKey = nil }
                    .buttonStyle(.borderedProminent).tint(Brand.purple)
                    .disabled(!savedKey)
            }
        }
        .padding(28)
        .frame(maxWidth: 600)
    }

    // MARK: Open

    private var lockedScreen: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(Brand.purple)
            Text("Private vault").font(.system(size: 18, weight: .semibold))
            if usingRecovery {
                TextField("Recovery key", text: $recovery)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .frame(width: 360)
                    .onSubmit { model.unlock(recoveryKey: recovery); recovery = "" }
                Button("Open with recovery key") { model.unlock(recoveryKey: recovery); recovery = "" }
                    .buttonStyle(.borderedProminent).tint(Brand.purple).disabled(recovery.isEmpty || model.busy)
            } else {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder).frame(width: 320)
                    .onSubmit { unlock() }
                HStack {
                    Button("Unlock") { unlock() }
                        .buttonStyle(.borderedProminent).tint(Brand.purple).disabled(passphrase.isEmpty || model.busy)
                    if model.touchIDSaved {
                        Button { model.unlockWithTouchID() } label: { Label("Touch ID", systemImage: "touchid") }
                            .disabled(model.busy)
                    }
                }
            }
            if model.busy { ProgressView().controlSize(.small) }
            problemText
            Button(usingRecovery ? "Use my passphrase" : "Forgot it? Use the recovery key") { usingRecovery.toggle() }
                .buttonStyle(.borderless).font(.system(size: 12))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if model.touchIDSaved { model.unlockWithTouchID() } }
    }

    private func unlock() {
        model.unlock(passphrase: passphrase)
        passphrase = ""
    }

    private var openScreen: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selected) {
                    ForEach(model.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? "Untitled" : item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(item.updated.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .tag(item.id)
                    }
                }
                Divider()
                HStack {
                    Button { model.newItem() } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(.borderless).help("A new note in the vault")
                    Spacer()
                    Menu {
                        if model.touchIDAvailable {
                            Toggle("Open with Touch ID", isOn: Binding(get: { model.touchIDSaved }, set: { model.setTouchID($0) }))
                        }
                        Button("Change passphrase…") { changing = true }
                    } label: { Image(systemName: "gearshape") }
                    .menuStyle(.borderlessButton).fixedSize().help("Touch ID and passphrase")
                    Button { model.lock() } label: { Label("Lock", systemImage: "lock") }
                        .buttonStyle(.borderless).help("Lock the vault now")
                }
                .padding(10)
            }
            .frame(width: 230)
            Divider()
            editor
        }
        .sheet(isPresented: $changing) { changeSheet }
        .alert("Delete this note from the vault?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) { if let id = confirmDelete { model.delete(id) }; confirmDelete = nil }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("It's gone for good: there's no copy anywhere.")
        }
    }

    @ViewBuilder private var editor: some View {
        if let id = model.selected, let item = model.items.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Title", text: Binding(get: { item.title }, set: { model.update(id, title: $0) }))
                        .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                    Button { confirmDelete = id } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete this note")
                }
                TextEditor(text: Binding(get: { item.body }, set: { model.update(id, body: $0) }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                Text("Encrypted on this Mac. Locks after 5 minutes idle. Never read by Broski's models, search, memory or Claude Code.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(18)
        } else {
            VStack(spacing: 8) {
                Text(model.items.isEmpty ? "Your vault is empty." : "Pick a note.").foregroundStyle(.secondary)
                Button("New note") { model.newItem() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var changeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change passphrase").font(.headline)
            Text("Your notes and your recovery key stay the same.").font(.system(size: 12)).foregroundStyle(.secondary)
            SecureField("New passphrase", text: $passphrase).textFieldStyle(.roundedBorder)
            SecureField("The same again", text: $confirm).textFieldStyle(.roundedBorder)
            problemText
            HStack {
                Spacer()
                Button("Cancel") { changing = false; passphrase = ""; confirm = "" }
                Button("Change") {
                    if model.changePassphrase(passphrase, confirm: confirm) { changing = false }
                    passphrase = ""
                    confirm = ""
                }
                .buttonStyle(.borderedProminent).tint(Brand.purple).disabled(passphrase.count < Vault.minimumLength)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    // MARK: Bits

    @ViewBuilder private var problemText: some View {
        if let problem = model.problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.shield").foregroundStyle(Brand.purple).font(.system(size: 12))
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
