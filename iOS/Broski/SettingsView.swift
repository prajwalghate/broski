import BroskiBark
import BroskiCore
import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var store: PhoneStore
    @State private var picking = false
    @State private var key = ""
    @State private var hasKey = Keychain.claudeKey != nil
    @State private var keyStatus: String?
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

                Section {
                    if hasKey {
                        LabeledContent("Claude", value: "Key saved")
                        Button("Remove key", role: .destructive) {
                            Keychain.setClaudeKey(nil)
                            hasKey = false
                        }
                    } else {
                        SecureField("sk-ant-…", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Save key") {
                            Keychain.setClaudeKey(key)
                            key = ""
                            hasKey = Keychain.claudeKey != nil
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if hasKey {
                        Button("Test the key") { Task { await test() } }
                        if let keyStatus { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                    }
                } header: {
                    Text("Claude (optional)")
                } footer: {
                    Text("With a key, Claude tidies notes and picks the project, type and priority, like on the Mac. Without one, Broski's built-in rules do it. The key stays in this iPhone's Keychain.")
                }

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

    private func test() async {
        guard let key = Keychain.claudeKey else { return }
        keyStatus = "Checking…"
        do {
            try await ClaudeClient(apiKey: key).verify()
            keyStatus = "Works."
        } catch {
            keyStatus = "Didn't work: \(error.localizedDescription)"
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
