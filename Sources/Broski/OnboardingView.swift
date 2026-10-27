import AppKit
import BroskiCore
import SwiftUI

/// First run: what Broski is, how to call it, voice access, and where projects live.
struct OnboardingView: View {
    @ObservedObject var app: AppModel
    @StateObject private var check = VoiceCheck()
    @State private var step: Int
    @State private var roots: [RootChoice] = []
    @State private var projectNames: [String]?
    @State private var refresh = 0

    struct RootChoice: Identifiable {
        var id: String { path }
        let path: String
        var on: Bool
    }

    private let lastStep = 5

    init(app: AppModel, step: Int = 0) {
        self.app = app
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: howToCall
                case 2: voice
                case 3: ai
                case 4: projects
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 34)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0...lastStep, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Brand.purple : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 && step < lastStep {
                    Button("Back") { step -= 1 }
                }
                if step == 2 && !Permissions.voiceGranted {
                    Button("Skip, I'll type") { next() }
                }
                Button(step == lastStep ? "Start using Broski" : "Continue", action: next)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 560)
        .onAppear { if step == 4 { loadRoots() } }
    }

    private func next() {
        // A key pasted but not saved (Return goes to Continue) is saved, not lost.
        if !key.trimmingCharacters(in: .whitespaces).isEmpty { saveKey() }
        if step == 3 { loadRoots() }
        if step == 4 { saveRoots() }
        if step == lastStep {
            app.finishOnboarding()
        } else {
            step += 1
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(nsImage: BroskiArt.avatar(diameter: 104, crowned: true))
            Text("Hey, I'm Broski.")
                .font(.system(size: 32, weight: .bold))
            Text("Ideas show up at random. Tell me the moment you have one, by voice or by typing, and I'll file it into the right project before it evaporates.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "keyboard", text: "Press \(app.shortcutLabel) anywhere, or click Broski in the menu bar")
                Feature(symbol: "waveform", text: "Say “in the strado project, add a todo: …”, or just type it")
                Feature(symbol: "camera.viewfinder", text: "Press \(app.screenshotLabel) to grab a screenshot and talk over it")
                Feature(symbol: "record.circle", text: "“Start a QA session for strado”, test, then “wrap up” for a full report")
                Feature(symbol: "text.quote", text: "Highlight text anywhere and press ⌥⇧C to clip it, with its source")
                Feature(symbol: "square.stack", text: "See, tick off, and move every note in the dashboard")
                Feature(symbol: "lock", text: "Notes are plain markdown on your Mac. Nothing is uploaded.")
            }
            .padding(.top, 6)
        }
    }

    private var howToCall: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "How do you want to call me?", subtitle: "Pick any mix. You can change this later in Settings.")
            OptionCard(symbol: "keyboard", title: "Keyboard shortcut", badge: "Recommended",
                       detail: "Tap to open a note and type. Hold to talk, let go when you're done. Click to change it.") {
                ShortcutRecorder(app: app)
            }
            OptionCard(symbol: "globe", title: "Hold fn to talk", badge: nil,
                       detail: "Hold fn (🌐) anywhere, talk, let go. Nothing on screen; needs Accessibility.") {
                Toggle("", isOn: app.binding(\.fnHoldToTalk)).labelsHidden().toggleStyle(.switch)
            }
            OptionCard(symbol: "ear", title: "Wake word “broski”", badge: nil,
                       detail: "Hands-free, but the mic stays on: the orange dot stays lit and it uses more battery.") {
                Toggle("", isOn: app.binding(\.wakeWordEnabled)).labelsHidden().toggleStyle(.switch)
            }
            OptionCard(symbol: "person.crop.circle", title: "Floating Broski head", badge: nil,
                       detail: "A small head on screen: click it to type, hold it to talk. Off by default; Broski is always in the menu bar.") {
                Toggle("", isOn: app.binding(\.showFloatingButton)).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Let me hear you", subtitle: "Voice is optional: every note can be typed. When you talk, recognition runs on this Mac.")
            VStack(spacing: 12) {
                PermissionRows(refresh: $refresh)
                HStack(spacing: 10) {
                    Image(systemName: "keyboard").foregroundStyle(.secondary).font(.system(size: 15)).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictation")
                        Text("Apple's speech recognition needs Dictation turned on in System Settings › Keyboard.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            VoiceModelRow(transcription: app.transcription)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            VoiceCheckView(check: check, locale: app.config.locale)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }

    @State private var key = ""
    @State private var keyStatus: String?

    private func saveKey() {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        app.brain.setKey(key)
        key = ""
        keyStatus = "Checking…"
        Task { keyStatus = await app.brain.verifyKey() ?? "Working" }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Give me a brain (optional)",
                      subtitle: "With a Claude API key I tidy up rambles, file notes into the right project, follow commands like “start a QA session”, and write reports from your screenshots. Only text and session screenshots go to Anthropic, never audio.")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SecureField(app.brain.hasKey ? "Key saved on this Mac" : "Paste your key: sk-ant-…", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyStatus {
                    Text(keyStatus).font(.system(size: 12)).foregroundStyle(keyStatus == "Working" ? Color.green : keyStatus == "Checking…" ? Color.secondary : Color.red)
                }
                Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            Text("Skip this and Broski still works, using its built-in phrase rules. You can add a key later in Settings › AI.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Where do your projects live?",
                      subtitle: "Each folder inside these becomes a project you can name: “in the <folder> project, …”. Notes are saved in ~/Broski either way.")
            VStack(alignment: .leading, spacing: 8) {
                if roots.isEmpty {
                    Text("Nothing found automatically. Add the folder that holds your projects.")
                        .foregroundStyle(.secondary)
                }
                ForEach($roots) { $root in
                    Toggle(isOn: $root.on) {
                        Label(root.path, systemImage: "folder")
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: root.on) { _ in countProjects() }
                }
                Button("Add folder…") {
                    for path in FolderPicker.pick() where !roots.contains(where: { $0.path == path }) {
                        roots.append(RootChoice(path: path, on: true))
                    }
                    countProjects()
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
            if let names = projectNames {
                Text(names.isEmpty ? "No projects found yet." : "Found \(names.count): " + names.prefix(8).joined(separator: ", ") + (names.count > 8 ? "…" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: BroskiArt.avatar(diameter: 84, crowned: true))
            Text("You're all set").font(.system(size: 28, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                if app.config.showFloatingButton {
                    Feature(symbol: "person.crop.circle", text: "Click the Broski head on the right edge of your screen. Drag it wherever you like.")
                }
                Feature(symbol: "keyboard", text: "Press \(app.shortcutLabel) in any app")
                if app.config.wakeWordEnabled {
                    Feature(symbol: "ear", text: "Or just say “broski”")
                }
                Feature(symbol: "menubar.rectangle", text: "Broski also lives in the menu bar: settings and the dashboard are there.")
            }
            HStack(spacing: 10) {
                Button("Take a note now") {
                    app.finishOnboarding()
                    app.capture.trigger(.shortcut)
                }
                Button("Open the dashboard") {
                    app.finishOnboarding()
                    app.showDashboard()
                }
            }
            .padding(.top, 8)
        }
    }

    // MARK: Projects step

    private func loadRoots() {
        guard roots.isEmpty else { return }
        let current = app.config.projectRoots
        let suggested = BroskiConfig.suggestedProjectRoots()
        var seen = Set<String>()
        roots = (current + suggested).filter { seen.insert($0).inserted }.map {
            RootChoice(path: $0, on: current.isEmpty ? true : current.contains($0))
        }
        countProjects()
    }

    private func saveRoots() {
        let chosen = roots.filter(\.on).map(\.path)
        app.update { $0.projectRoots = chosen }
    }

    private func countProjects() {
        let urls = roots.filter(\.on).map { URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath, isDirectory: true) }
        let notesDir = app.store.projectsDir
        Task.detached(priority: .userInitiated) {
            let names = ProjectCatalog.discover(roots: urls, notesDir: notesDir).projects.filter { $0.folder != nil }.map(\.name)
            await MainActor.run { projectNames = names }
        }
    }
}

private struct StepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

private struct Feature: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Brand.purple)
                .frame(width: 20)
            Text(text).font(.system(size: 14))
        }
    }
}

private struct OptionCard<Trailing: View>: View {
    let symbol: String
    let title: String
    let badge: String?
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Brand.purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Brand.purple.opacity(0.12)))
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }
}
