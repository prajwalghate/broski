import BroskiBark
import BroskiCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var store: PhoneStore
    @State private var picking = false
    @State private var checkIn = CheckInSchedule.enabled
    @State private var checkInTime = Calendar.current.date(from: CheckInSchedule.time) ?? Date()
    @State private var notificationsOff = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Notes folder", value: store.sharedFolderName.map { "iCloud Drive › \($0)" } ?? "On this iPhone")
                    Button(store.isShared ? "Pick a different folder" : "Use my Mac's Broski folder") { picking = true }
                    if store.isShared {
                        // The shared notes don't come along: they stay in iCloud Drive, where the Mac keeps using them.
                        Button("Stop sharing (shared notes stay in iCloud Drive)", role: .destructive) { store.useLocal() }
                    }
                    if store.downloading > 0 {
                        Label("Fetching \(store.downloading) files from iCloud…", systemImage: "icloud.and.arrow.down")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let problem = store.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Sync with your Mac")
                } footer: {
                    Text("On your Mac, open Broski Settings › General › Sync with iPhone. That moves your notes into iCloud Drive. Then tap above and pick iCloud Drive › Broski. Both devices then read and write the same notes.")
                }

                BarkSection()

                ProviderKeysSection(store: store)

                Section {
                    Toggle("Morning check-in", isOn: Binding(get: { checkIn }, set: { on in
                        Task {
                            if on, !(await CheckInSchedule.requestPermission()) {
                                // Without this the toggle just snaps back, and there's no way to tell why.
                                notificationsOff = await CheckInSchedule.permissionDenied()
                                return
                            }
                            notificationsOff = false
                            UserDefaults.standard.set(on, forKey: CheckInSchedule.enabledKey)
                            checkIn = on
                            await CheckInSchedule.refresh(items: store.items)
                        }
                    }))
                    if notificationsOff {
                        Label("Notifications are off for Broski", systemImage: "bell.slash").font(.footnote).foregroundStyle(.orange)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Turn them on in Settings", destination: url)
                        }
                    }
                    if checkIn {
                        DatePicker("At", selection: Binding(get: { checkInTime }, set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            UserDefaults.standard.set((parts.hour ?? 9) * 60 + (parts.minute ?? 30), forKey: CheckInSchedule.timeKey)
                            checkInTime = date
                            Task { await CheckInSchedule.refresh(items: store.items) }
                        }), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Companion")
                } footer: {
                    Text("A notification once a day with what's open across your projects. Off unless you turn it on. For one-tap capture, add “Talk to Broski” to Control Center or the Action Button, or say “Talk to Broski” to Siri.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    LabeledContent("Notes", value: "\(store.items.count) in \(store.projects.count) projects")
                }
            }
            .navigationTitle("Settings")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { store.useFolder(url) }
            }
        }
    }
}

/// Keys on this iPhone for the providers your Mac chose (its Settings › Models syncs in config.json). Keys never sync.
private struct ProviderKeysSection: View {
    @ObservedObject var store: PhoneStore
    @State private var drafts: [String: String] = [:]
    @State private var status: [String: String] = [:]
    @State private var changed = 0

    /// The providers some role uses.
    private var providers: [ModelProvider] {
        let settings = store.models ?? .defaults
        let used = Set((Array(settings.roles.values) + Array(settings.localRoles.values)).map(\.provider))
        return settings.providers.filter { used.contains($0.id) }
    }

    var body: some View {
        Section {
            ForEach(providers) { provider in row(provider) }
        } header: {
            Text("Models")
        } footer: {
            Text("Your Mac's Settings › Models chooses which model does what, and that syncs here. Keys never sync: paste each one here, and it stays in this iPhone's Keychain. A model running on your Mac can't be reached from the iPhone.")
        }
        .id(changed)
    }

    @ViewBuilder private func row(_ provider: ModelProvider) -> some View {
        if provider.kind == .appleOnDevice {
            LabeledContent(provider.displayName, value: PhoneHome.appleAvailable ? "On this iPhone" : "Not on this iPhone")
        } else if !provider.needsKey {
            LabeledContent(provider.displayName, value: provider.isLocal ? "On your Mac only" : "No key needed")
        } else if Keychain.key(forProvider: provider.id) != nil && drafts[provider.id] == nil {
            LabeledContent(provider.displayName, value: "Key saved")
            HStack {
                Button("Test") { test(provider) }
                Spacer()
                Button("Change") { drafts[provider.id] = "" }
                Button("Remove", role: .destructive) {
                    Keychain.setKey(nil, forProvider: provider.id)
                    status[provider.id] = nil
                    changed += 1
                }
            }
            .buttonStyle(.borderless)
            if let line = status[provider.id] { Text(line).font(.footnote).foregroundStyle(.secondary) }
        } else {
            SecureField("\(provider.displayName) key", text: Binding(get: { drafts[provider.id] ?? "" }, set: { drafts[provider.id] = $0 }))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Save \(provider.displayName) key") {
                Keychain.setKey(drafts[provider.id], forProvider: provider.id)
                drafts[provider.id] = nil
                test(provider)
            }
            .disabled((drafts[provider.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            if let link = ProviderPreset.of(provider)?.keyURL.flatMap(URL.init(string:)) {
                Link("Get your \(provider.displayName) key", destination: link).font(.footnote)
            }
        }
    }

    private func test(_ provider: ModelProvider) {
        status[provider.id] = "Checking…"
        Task {
            do {
                let result = try await ProviderCheck.run(provider, key: Keychain.key(forProvider: provider.id))
                status[provider.id] = "Works (\(result.tested))."
            } catch {
                status[provider.id] = error.localizedDescription
            }
        }
    }
}

/// Bark, the on-device speech model that writes your English notes: download, the first-time preparation, the switch.
private struct BarkSection: View {
    @ObservedObject private var bark = PhoneBark.shared

    var body: some View {
        Section {
            switch bark.state {
            case .unsupported:
                Label("Needs iOS 18. Apple's recognizer writes your notes.", systemImage: "info.circle").foregroundStyle(.secondary)
            case .missing:
                Button("Download Bark (202 MB)") { bark.startDownload() }
            case .downloading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction) { Text("Downloading Bark… \(Int(fraction * 100))%") }
                    Button("Cancel", role: .cancel) { bark.cancelDownload() }.font(.footnote)
                }
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing Bark for this iPhone. The first time takes a few minutes; keep Broski open.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .onAppear { bark.warmUp() }
            case .ready:
                Toggle("Bark writes my notes", isOn: $bark.enabled)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                Button("Download Bark again") { bark.startDownload() }
            }
        } header: {
            Text("Voice")
        } footer: {
            Text("Bark turns what you say into text on this iPhone, more accurately than Apple's recognizer, and knows your project names. English only; you still see Apple's words while you talk. \(BarkModel.attribution)")
        }
    }
}
