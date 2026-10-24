import AppKit
import BroskiBark
import BroskiCore
import Speech
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, projects, voice, ai, models, companion, connections, about
}

struct SettingsView: View {
    @ObservedObject var app: AppModel
    @State private var tab: SettingsTab

    init(app: AppModel, tab: SettingsTab = .general) {
        self.app = app
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 600)
            .padding(.top, 12)
            .padding(.bottom, 4)
            switch tab {
            case .general: GeneralSettings(app: app)
            case .projects: ProjectSettings(app: app)
            case .voice: VoiceSettings(app: app)
            case .ai: AISettings(app: app, brain: app.brain)
            case .models: ModelsSettings(app: app)
            case .companion: CompanionSettings(app: app)
            case .connections: ConnectionSettings(app: app)
            case .about: AboutSettings(app: app)
            }
        }
        .frame(width: 640, height: 520)
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .ai: return "AI"
        case .models: return "Models"
        case .companion: return "Companion"
        case .connections: return "Connections"
        case .general: return "General"
        case .projects: return "Projects"
        case .voice: return "Voice"
        case .about: return "About"
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var app: AppModel
    @State private var confirmMove = false

    /// Any folder: local, Dropbox, a Git repo. An empty folder gets your notes moved in; one that already has
    /// Broski notes (from another Mac, or iCloud) is used as it is. Broski restarts there.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Pick a folder for your Broski notes. An empty folder gets your notes moved into it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.useNotesFolder(url)
    }

    private var fnDetail: String {
        if app.config.fnHoldToTalk, !ContextCapture.accessibilityAllowed {
            return "Needs Accessibility (the same permission clipping uses) to see the fn key in other apps."
        }
        let note = "Hold fn (🌐) anywhere, talk, let go. A quick tap and fn+key shortcuts do nothing."
        // If macOS also acts on the 🌐 key, letting go can open the emoji picker or Dictation as well.
        return FnKeyMonitor.systemFnAction == 0 ? note : note + " If the emoji picker or Dictation opens when you let go, set System Settings › Keyboard › “Press 🌐 key to” to Do Nothing."
    }

    var body: some View {
        Form {
            Section("Call Broski") {
                Toggle(isOn: app.binding(\.showFloatingButton)) {
                    Text("Floating Broski head")
                    Text("A small head on screen: click it to take a note, hold it to talk. Broski is always in the menu bar either way.")
                }
                Toggle(isOn: app.binding(\.fnHoldToTalk)) {
                    Text("Hold fn to talk")
                    Text(fnDetail)
                        .foregroundStyle(app.config.fnHoldToTalk && !ContextCapture.accessibilityAllowed ? Color.orange : Color.secondary)
                }
                if app.config.fnHoldToTalk, !ContextCapture.accessibilityAllowed {
                    Button("Allow Accessibility…") { ContextCapture.requestAccessibility() }
                }
                LabeledContent {
                    ShortcutRecorder(app: app)
                } label: {
                    Text("Keyboard shortcut")
                    Text(app.shortcutProblem ?? "Tap to open a note and type. Hold it down to talk; let go when you're done.")
                        .foregroundStyle(app.shortcutProblem == nil ? Color.secondary : Color.red)
                }
                Toggle(isOn: app.binding(\.wakeWordEnabled)) {
                    Text("Wake word “\(app.config.wakeWords.first ?? "broski")”")
                    Text("Hands-free, but the microphone stays on: the orange mic dot stays lit and it uses more battery. Listening runs on this Mac only.")
                }
            }
            Section("Screenshots and highlights") {
                LabeledContent {
                    ShortcutRecorder(app: app, keyPath: \.screenshotHotkey)
                } label: {
                    Text("Screenshot shortcut")
                    Text("Grab part of the screen, then say or type what it's about. During a session it's added to the report.")
                }
                LabeledContent {
                    ShortcutRecorder(app: app, keyPath: \.clipHotkey)
                } label: {
                    Text("Clip shortcut")
                    Text("Highlight text in any app and press it: Broski quotes it with where it came from. Press again on more highlights to collect them. Also in right-click › Services › Add to Broski.")
                }
                if !ContextCapture.accessibilityAllowed {
                    Button("Allow Accessibility so clipping works everywhere…") { ContextCapture.requestAccessibility(); ContextCapture.openAccessibilitySettings() }
                }
            }
            Section("Remember what I was looking at") {
                Toggle(isOn: app.binding(\.captureBrowserPage)) {
                    Text("Browser page")
                    Text("The address and title of the tab you're on. macOS asks once per browser.")
                }
                Toggle(isOn: app.binding(\.captureWindowDetails)) {
                    Text("Window title and selected text")
                    Text(ContextCapture.accessibilityAllowed ? "Allowed." : "Needs Accessibility access.")
                }
                if app.config.captureWindowDetails && !ContextCapture.accessibilityAllowed {
                    Button("Allow Accessibility access…") { ContextCapture.requestAccessibility(); ContextCapture.openAccessibilitySettings() }
                }
            }
            Section("Taking a note") {
                Toggle(isOn: app.binding(\.startMicOnOpen)) {
                    Text("Turn the mic on when a note opens")
                    Text("Off (recommended): notes open ready for typing. Hold the shortcut or the head to talk, or click the mic.")
                }
                Toggle(isOn: app.binding(\.autoSave)) {
                    Text("Save automatically when I stop talking")
                    Text("Off: you see the transcript and where it's going, can edit or add screenshots, then press ⌘Return.")
                }
                Toggle("Play sounds", isOn: app.binding(\.playSounds))
            }
            Section {
                LabeledContent {
                    Button("Choose…") { chooseFolder() }
                } label: {
                    Text("Notes folder")
                    Text((app.root.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                }
                if app.syncsWithPhone {
                    LabeledContent("Notes folder", value: "iCloud Drive › Broski")
                    Text("Your iPhone sees the same notes: in the Broski app, Settings › Use my Mac's Broski folder › iCloud Drive › Broski.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent {
                        Button("Sync with iPhone…") { confirmMove = true }
                            .disabled(!app.iCloudDriveAvailable)
                    } label: {
                        Text("Notes folder: ~/Broski")
                        Text(app.iCloudDriveAvailable
                             ? "Moves your notes into iCloud Drive so the Broski iPhone app can use the same ones. Broski restarts."
                             : "Turn on iCloud Drive in System Settings › Apple Account › iCloud to sync with your iPhone.")
                    }
                }
            } header: {
                Text("iPhone")
            }
            .confirmationDialog("Move your notes into iCloud Drive?", isPresented: $confirmMove) {
                Button("Move and restart Broski") { app.moveNotesToICloud() }
            } message: {
                Text("~/Broski moves to iCloud Drive › Broski. Nothing is deleted. Broski restarts in the new place.")
            }
            Section {
                Toggle("Open Broski at login", isOn: Binding(get: { app.launchesAtLogin }, set: { app.setLaunchesAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new key combination. Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var app: AppModel
    var keyPath: WritableKeyPath<BroskiConfig, String> = \.hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : (HotKey.parse(app.config[keyPath: keyPath])?.display ?? app.config[keyPath: keyPath])) {
            recording ? stop() : start()
        }
        .frame(minWidth: 96)
        .help(recording ? "Press the new shortcut, or esc to cancel" : "Click to change")
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        app.suspendHotKey(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !modifiers.isEmpty, let key = HotKey.name(forKeyCode: UInt32(event.keyCode)) else {
                NSSound.beep()
                return nil
            }
            app.update { $0[keyPath: keyPath] = HotKey.spec(modifiers: modifiers, key: key) }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            app.suspendHotKey(false)
        }
    }
}

// MARK: Projects

private struct ProjectSettings: View {
    @ObservedObject var app: AppModel
    @ObservedObject var library: Library

    init(app: AppModel) {
        self.app = app
        library = app.library
    }

    var body: some View {
        Form {
            Section {
                if app.config.projectRoots.isEmpty {
                    Text("No folders yet. Add the folder where your projects live, like ~/Developer.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.config.projectRoots, id: \.self) { root in
                    HStack {
                        Label(root, systemImage: "folder")
                        Spacer()
                        Button {
                            app.update { $0.projectRoots.removeAll { $0 == root } }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Stop using this folder")
                    }
                }
                Button("Add folder…") {
                    let picked = FolderPicker.pick()
                    app.update { config in
                        for path in picked where !config.projectRoots.contains(path) { config.projectRoots.append(path) }
                    }
                }
            } header: {
                Text("Project folders")
            } footer: {
                Text("Each folder inside these becomes a project you can name: “in the <folder> project, …”. \(library.projects.filter { $0.folder != nil }.count) found.")
            }
            Section("Notes") {
                LabeledContent("Saved in") {
                    HStack {
                        Text((app.root.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.open(app.root) }
                    }
                }
                Toggle(isOn: app.binding(\.mirrorToProjectFolder)) {
                    Text("Also write notes to IDEAS.md in each project's folder")
                    Text("Handy if you want Claude Code or your editor to see them inside the repo.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum FolderPicker {
    /// Folders chosen in an open panel, as "~/…" paths when they're inside the home folder.
    @MainActor
    static func pick() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Use folder"
        panel.message = "Choose the folder that contains your projects"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { ($0.path as NSString).abbreviatingWithTildeInPath }
    }
}

// MARK: Voice

private struct VoiceSettings: View {
    @ObservedObject var app: AppModel
    @StateObject private var check = VoiceCheck()
    @State private var refresh = 0

    private static let languages: [(id: String, name: String)] = SFSpeechRecognizer.supportedLocales()
        .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
        .sorted { $0.name < $1.name }

    var body: some View {
        Form {
            Section("Access") {
                PermissionRows(refresh: $refresh)
                LabeledContent {
                    Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                } label: {
                    Text("Dictation")
                    Text("Apple's speech recognition only runs while Dictation is turned on, even on-device.")
                }
                if let problem = app.capture.speechProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Recognition") {
                Picker("Language", selection: app.binding(\.locale)) {
                    Text("System (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))").tag("auto")
                    Divider()
                    ForEach(Self.languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                LabeledContent("Pause before saving") {
                    HStack {
                        Slider(value: app.binding(\.silenceSeconds), in: 1...4, step: 0.5).frame(width: 180)
                        Text(String(format: "%.1fs", app.config.silenceSeconds)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Section("Voice model") {
                BarkModelRow(transcription: app.transcription)
                VoiceModelRow(transcription: app.transcription)
                Picker(selection: app.binding(\.speechEngine)) {
                    Text("Automatic").tag("auto")
                    Text("Bark").tag("bark")
                    Text("Whisper").tag("whisper")
                } label: {
                    Text("Speech engine")
                    Text("Automatic uses Bark for English once it's downloaded, and Whisper for other languages or when Bark can't run.")
                }
                Toggle(isOn: app.binding(\.voiceIsolation)) {
                    Text("Voice isolation")
                    Text("Echo cancellation and noise suppression, so videos and music playing on this Mac aren't picked up. Turns itself off on device setups that don't support it.")
                }
                Toggle(isOn: app.binding(\.livePreview)) {
                    Text("Live preview while talking")
                    Text("Shows Apple's quick transcript as you speak; Whisper writes the final text.")
                }
            }
            Section("Check") {
                VoiceCheckView(check: check, locale: app.config.locale)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh += 1 }
    }
}

struct PermissionRows: View {
    @Binding var refresh: Int

    var body: some View {
        let _ = refresh
        PermissionRow(title: "Microphone", detail: "Only while you're taking a note, unless the wake word is on.", state: Permissions.microphone,
                      request: request, openSettings: Permissions.openMicrophoneSettings)
        PermissionRow(title: "Speech recognition", detail: "Turns what you say into text.", state: Permissions.speech,
                      request: request, openSettings: Permissions.openSpeechSettings)
    }

    private func request() {
        Task {
            _ = await Permissions.requestVoice()
            refresh += 1
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let state: Permissions.State
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : state == .denied ? "xmark.circle.fill" : "circle.dashed")
                .foregroundStyle(state == .granted ? Color.green : state == .denied ? Color.red : Color.secondary)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted: Text("Allowed").foregroundStyle(.secondary)
            case .notAsked: Button("Allow", action: request)
            case .denied: Button("Open Settings", action: openSettings)
            }
        }
    }
}

struct VoiceCheckView: View {
    @ObservedObject var check: VoiceCheck
    let locale: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    check.start(locale: locale)
                } label: {
                    Label(check.state == .listening ? "Listening…" : "Test my voice", systemImage: "mic.fill")
                }
                .disabled(check.state == .listening)
                if check.state == .listening { LevelBars(level: check.level, color: Brand.purple) }
                Spacer()
            }
            switch check.state {
            case .idle:
                Text("Say something like “in the strado project, add a todo: test”.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            case .listening:
                Text("Say a sentence, then pause.").font(.system(size: 11)).foregroundStyle(.secondary)
            case .heard(let text):
                Label("Heard: “\(text)”", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message, let needsDictation):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if needsDictation {
                        Button("Open Keyboard settings") { Permissions.openKeyboardSettings() }
                    }
                }
            }
        }
    }
}

// MARK: About

private struct AboutSettings: View {
    @ObservedObject var app: AppModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(nsImage: BroskiArt.avatar(diameter: 88, crowned: true))
            Text("Broski").font(.system(size: 24, weight: .bold))
            Text("Version \(app.version) · beta").foregroundStyle(.secondary)
            Text("Your ideas, filed before they evaporate. Notes are plain markdown files in ~/Broski: yours to keep, sync, or open anywhere.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button("Open notes folder") { NSWorkspace.shared.open(app.root) }
                Button("Open config file") { NSWorkspace.shared.open(app.configURL) }
                Button("Show welcome again") { app.showOnboarding() }
            }
            Button(copied ? "Copied" : "Copy diagnostics for feedback") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.diagnostics(), forType: .string)
                copied = true
            }
            .help("Version, settings, and recent events. Nothing you said is included.")
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Bark 3.0: English, on the Neural Engine. Its license (CC BY 4.0) asks for the credit line shown here.
struct BarkModelRow: View {
    @ObservedObject var transcription: Transcription

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transcription.barkState == .ready ? "checkmark.circle.fill" : "waveform.circle")
                .foregroundStyle(transcription.barkState == .ready ? Color.green : Brand.purple)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Bark 3.0 (English)")
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(BarkModel.attribution).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            switch transcription.barkState {
            case .missing:
                Button("Download (\(BarkModel.totalBytes / 1_000_000) MB)") { transcription.downloadBark() }
            case .failed:
                if Transcription.barkSupported { Button("Try again") { transcription.downloadBark() } }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Button("Cancel") { transcription.cancelBarkDownload() }
            case .preparing:
                ProgressView().controlSize(.small)
            case .ready:
                Text("Ready").foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        switch transcription.barkState {
        case .missing: return "Faster and cooler than Whisper on the Neural Engine, and more accurate on meetings. English only."
        case .downloading(let f): return "Downloading… \(Int(f * 100))%"
        case .preparing: return "Preparing it for this Mac. A few minutes, once."
        case .ready: return "Installed. Your voice never leaves this Mac."
        case .failed(let message): return message
        }
    }
}

struct VoiceModelRow: View {
    @ObservedObject var transcription: Transcription

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: transcription.state == .ready ? "checkmark.circle.fill" : "waveform.circle")
                .foregroundStyle(transcription.state == .ready ? Color.green : Brand.purple)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper \(transcription.model.displayName)")
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            switch transcription.state {
            case .missing, .failed:
                Button("Download (\(transcription.model.approximateSizeMB) MB)") { transcription.downloadModel() }
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 120)
                Button("Cancel") { transcription.cancelDownload() }
            case .ready:
                Text("Ready").foregroundStyle(.secondary)
            case .preparing:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var detail: String {
        switch transcription.state {
        case .missing: return "Runs on this Mac. Every language, and it learns your project names."
        case .downloading(let f): return "Downloading… \(Int(f * 100))%"
        case .ready: return "Installed. Your voice never leaves this Mac."
        case .preparing: return "Preparing…"
        case .failed(let message): return message
        }
    }
}

// MARK: AI

private struct AISettings: View {
    @ObservedObject var app: AppModel
    @ObservedObject var brain: Brain
    @State private var key = ""
    @State private var status: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Claude API key") {
                    HStack {
                        SecureField(brain.hasKey ? "Saved on this Mac" : "sk-ant-…", text: $key)
                            .frame(width: 240)
                        Button("Save") {
                            brain.setKey(key)
                            key = ""
                            check()
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if brain.hasKey {
                    HStack {
                        Button(checking ? "Checking…" : "Test the key") { check() }.disabled(checking)
                        Button("Remove key", role: .destructive) {
                            brain.setKey(nil)
                            status = nil
                        }
                        Spacer()
                        if let status { Text(status).foregroundStyle(status == "Working" ? Color.green : Color.red).font(.system(size: 12)) }
                    }
                }
                Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12))
            } header: {
                Text("Claude")
            } footer: {
                Text("With a key, Claude files what you capture, keeps each project's living page, answers Ask Broski, riffs with you, and writes session and call notes. Routine filing uses Claude Haiku (cheap); pages and answers use Sonnet; riffs use Opus. Only text (and screenshots you share) goes to Anthropic; audio stays on your Mac. Projects marked local only never go to Claude.")
            }
            Section {
                LabeledContent {
                    Button(connecting ? "Connecting…" : "Connect") { connectClaudeCode() }
                        .disabled(connecting)
                } label: {
                    Text("Claude Code")
                    Text("Lets Claude Code read your Broski notes: project pages, open bugs, search. Read-only.")
                }
                if let connectResult {
                    Text(connectResult).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent {
                    Button(copiedDesktop ? "Copied" : "Copy config") {
                        if let problem = Self.serverPathProblem { return connectResult = problem }
                        Exporter.copy(Self.desktopConfig)
                        copiedDesktop = true
                    }
                } label: {
                    Text("Claude Desktop and other MCP apps")
                    Text("Paste into the app's MCP servers config (claude_desktop_config.json for Claude Desktop).")
                }
            } header: {
                Text("Use your notes in Claude")
            }
        }
        .formStyle(.grouped)
    }

    @State private var connecting = false
    @State private var connectResult: String?
    @State private var copiedDesktop = false

    static var serverPath: String { Bundle.main.executablePath ?? "/Applications/Broski.app/Contents/MacOS/Broski" }

    static var desktopConfig: String {
        let path = serverPath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        "broski": {
          "command": "\(path)",
          "args": ["--mcp"]
        }
        """
    }

    /// A copy running from a disk image or a quarantine (translocated) folder has a path that won't last.
    static var serverPathProblem: String? {
        let bundle = Bundle.main.bundlePath
        guard bundle.contains("/AppTranslocation/") || bundle.hasPrefix("/Volumes/") else { return nil }
        return "Move Broski to Applications first, open it from there, then connect. This copy's path won't last."
    }

    /// The path quoted for a shell, for the command shown to the user.
    static func shellQuoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Where Claude Code's `claude` is: the usual install places, else whatever an interactive login shell finds
    /// (that reads .zshrc, where the installer's PATH line usually is).
    nonisolated static func findClaude() -> String? {
        let home = NSHomeDirectory()
        for path in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            where FileManager.default.isExecutableFile(atPath: path) { return path }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "command -v claude"]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { $0.hasPrefix("/") }
        return found.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    /// Runs `claude mcp add` (Claude Code's own command) for the user, in their login shell so it finds `claude`.
    private func connectClaudeCode() {
        if let problem = Self.serverPathProblem { return connectResult = problem }
        connecting = true
        connectResult = nil
        let server = Self.serverPath
        let command = "claude mcp add --scope user broski -- \(Self.shellQuoted(server)) --mcp"
        Task.detached {
            guard let claude = Self.findClaude() else {
                await MainActor.run {
                    connectResult = "Couldn't find Claude Code (the claude command). Install it, or run this yourself:\n\(command)"
                    connecting = false
                }
                return
            }
            // No shell, so a path with quotes or spaces passes through as is.
            func run(_ arguments: [String]) -> (status: Int32, output: String) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: claude)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                } catch {
                    return (-1, error.localizedDescription)
                }
            }
            // Re-registering replaces an older path (a moved or renamed copy of Broski) instead of keeping it.
            _ = run(["mcp", "remove", "--scope", "user", "broski"])
            let (status, output) = run(["mcp", "add", "--scope", "user", "broski", "--", server, "--mcp"])
            let result: String
            if status == 0 {
                result = "Connected. In Claude Code, run /mcp to see “broski”, or just ask: “what's open in my Broski notes for this project?”"
            } else {
                result = "Didn't work (\(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))). Run this in Terminal:\n\(command)"
            }
            await MainActor.run {
                connectResult = result
                connecting = false
            }
        }
    }

    private func check() {
        checking = true
        Task {
            let problem = await brain.verifyKey()
            status = problem ?? "Working"
            checking = false
        }
    }
}

// MARK: Connections

private struct ConnectionSettings: View {
    @ObservedObject var app: AppModel
    @State private var webhook = Secrets.get(Secrets.slackWebhook) ?? ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Incoming webhook") {
                    HStack {
                        SecureField("https://hooks.slack.com/services/…", text: $webhook).frame(width: 260)
                        Button(saved ? "Saved" : "Save") {
                            saved = Secrets.set(webhook.trimmingCharacters(in: .whitespaces), for: Secrets.slackWebhook)
                        }
                        if !saved, !webhook.isEmpty, Secrets.get(Secrets.slackWebhook) != webhook.trimmingCharacters(in: .whitespaces) {
                            Text("Not saved yet").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Link("Create a Slack webhook", destination: URL(string: "https://api.slack.com/messaging/webhooks")!).font(.system(size: 12))
            } header: {
                Text("Slack")
            } footer: {
                Text("With a webhook, “Post to Slack” sends straight to that channel. Without one, Broski copies the text and opens Slack.")
            }
            AutomationSettings(app: app)
            Section("GitHub, Linear, Notion") {
                Text("“GitHub issue” opens a new issue on the project's repo, found from its git remote, with the note filled in and the screenshot on your clipboard. “Linear issue” does the same in Linear. “Notion” copies Markdown that pastes into a page with formatting.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Section("Claude and ChatGPT") {
                Text("“Ask Claude” and “Ask ChatGPT” open a new chat with the note and a ready-made prompt. The prompt is also copied, in case it's too long for a link.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: Companion

private struct CompanionSettings: View {
    @ObservedObject var app: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Speaks up", selection: app.binding(\.companionMode)) {
                    ForEach(CompanionMode.allCases, id: \.self) { mode in
                        Text("\(mode.label): \(mode.detail)").tag(mode)
                    }
                }
                Toggle(isOn: app.binding(\.showPill)) {
                    Text("Show the pill at the top of the screen")
                    Text("Buttons for Ask, Help with this, Riff and call notes. Off, they're in the menu bar and on their shortcuts; nudges, the check-in and Help answers still appear while they're needed.")
                }
                if app.config.showPill {
                    Toggle(isOn: app.binding(\.pillTucked)) {
                        Text("Tuck it away until I point at it")
                        Text("Only Broski's head stays at the top; the buttons slide out on hover, and when a nudge, check-in or call needs them.")
                    }
                }
            } header: {
                Text("Companion")
            } footer: {
                Text("Nudges: when you come back to a project with open bugs or todos, or an idea has sat untouched for weeks. Never while you're taking a note, and every nudge has Useful / Not now / Never.").frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Morning check-in", isOn: app.binding(\.checkInEnabled))
                if app.config.checkInEnabled {
                    DatePicker("At", selection: Binding(get: { checkInDate }, set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        app.update { $0.checkInTime = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 30) }
                    }), displayedComponents: .hourAndMinute)
                    Toggle("Open bugs", isOn: option(\.bugs))
                    Toggle("Todos", isOn: option(\.todos))
                    Toggle("Ideas waiting for weeks", isOn: option(\.staleIdeas))
                    Toggle("What you captured yesterday", isOn: option(\.yesterday))
                    LabeledContent("Projects") {
                        Menu(app.config.checkInOptions.projects.isEmpty ? "All projects" : app.config.checkInOptions.projects.joined(separator: ", ")) {
                            Button("All projects") { app.update { $0.checkInOptions.projects = [] } }
                            Divider()
                            ForEach(app.library.projectNames, id: \.self) { name in
                                Button {
                                    app.update { config in
                                        if let i = config.checkInOptions.projects.firstIndex(of: name) {
                                            config.checkInOptions.projects.remove(at: i)
                                        } else {
                                            config.checkInOptions.projects.append(name)
                                        }
                                    }
                                } label: {
                                    if app.config.checkInOptions.projects.contains(name) { Label(name, systemImage: "checkmark") } else { Text(name) }
                                }
                            }
                        }
                        .frame(maxWidth: 220)
                    }
                }
            } header: {
                Text("Check-in")
            } footer: {
                Text("Off unless you turn it on. It appears in the pill once a day after the time you pick.").frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Shortcuts") {
                LabeledContent("Ask Broski") { ShortcutRecorder(app: app, keyPath: \.askHotkey) }
                LabeledContent("Help with this") { ShortcutRecorder(app: app, keyPath: \.helpHotkey) }
                Toggle("Read riff replies aloud", isOn: app.binding(\.speakReplies))
            }

            Section {
                Toggle(isOn: app.binding(\.autoCompilePages)) {
                    Text("Keep project pages up to date with Claude")
                    Text("Rewrites a project's page a little after its notes change. Without this, pages are built from your notes by Broski's rules.")
                }
                ForEach(app.library.projectNames, id: \.self) { name in
                    Toggle("\(name): local only", isOn: Binding(get: { app.config.localOnlyProjects.contains(name) }, set: { on in
                        app.update { config in
                            config.localOnlyProjects.removeAll { $0 == name }
                            if on { config.localOnlyProjects.append(name) }
                        }
                    }))
                }
            } header: {
                Text("Living pages and privacy")
            } footer: {
                Text("A local-only project's notes never go to Claude: filing uses the rules, its page is built on this Mac, and it's left out of Ask, riffs and help.").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var checkInDate: Date {
        let parts = app.config.checkInTime.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 30, second: 0, of: Date()) ?? Date()
    }

    private func option(_ keyPath: WritableKeyPath<CheckIn.Options, Bool>) -> Binding<Bool> {
        Binding(get: { app.config.checkInOptions[keyPath: keyPath] }, set: { value in app.update { $0.checkInOptions[keyPath: keyPath] = value } })
    }
}

// MARK: Automations

/// Rules over what changes in your projects: a notification, a webhook post, or both. Kept in automations.json in
/// the Broski folder; webhook addresses stay in this Mac's secrets file.
private struct AutomationSettings: View {
    @ObservedObject var app: AppModel
    @State private var rules: [AutomationRule] = []
    @State private var adding = false
    @State private var name = ""
    @State private var project = ""
    @State private var kind = "decided"
    @State private var words = ""
    @State private var notify = true
    @State private var webhook = ""
    @State private var hookName = ""
    @State private var hookURL = ""
    @State private var problem: String?

    private var webhooks: [String] {
        (Secrets.get(Secrets.slackWebhook) == nil ? [] : ["slack"]) + Secrets.names(withPrefix: "webhook.")
    }

    var body: some View {
        Section {
            if rules.isEmpty && !adding {
                Text("None yet. For example: tell me when a strado decision mentions risk, and post it to the team's Slack.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                LabeledContent {
                    HStack {
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in change { $0[index(rule)].enabled = on } }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        Button("Remove", role: .destructive) { change { $0.removeAll { $0.id == rule.id } } }
                    }
                } label: {
                    Text(rule.name)
                    Text(summary(rule))
                }
            }
            if adding { form } else { Button("Add an automation…") { adding = true } }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
        } header: {
            Text("Automations")
        } footer: {
            Text("Checked once a minute. Changes in local-only projects can notify you but are never posted anywhere.")
        }
        .onAppear { rules = Automations.load(root: app.root) }
    }

    @ViewBuilder private var form: some View {
        TextField("Name", text: $name, prompt: Text("Risk decisions"))
        Picker("Project", selection: $project) {
            Text("Any").tag("")
            ForEach(app.library.projectNames, id: \.self) { Text($0).tag($0) }
        }
        Picker("When", selection: $kind) {
            Text("Anything changes").tag("")
            ForEach(Automations.kinds, id: \.self) { Text(Self.label($0)).tag($0) }
        }
        TextField("Title has any of", text: $words, prompt: Text("risk, limit (optional)"))
        Toggle("Notify me", isOn: $notify)
        Picker("Post to", selection: $webhook) {
            Text("Nowhere").tag("")
            ForEach(webhooks, id: \.self) { Text($0).tag($0) }
            Text("A new webhook…").tag("+")
        }
        if webhook == "+" {
            TextField("Webhook name", text: $hookName, prompt: Text("team"))
            SecureField("https://…", text: $hookURL)
        }
        HStack {
            Spacer()
            Button("Cancel") { adding = false }
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (!notify && webhook.isEmpty))
        }
    }

    private func add() {
        var hook = webhook.isEmpty ? nil : webhook
        if webhook == "+" {
            let slug = hookName.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
            guard !slug.isEmpty, let url = URL(string: hookURL.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
                return problem = "A webhook needs a name and an https:// address."
            }
            Secrets.set(url.absoluteString, for: "webhook.\(slug)")
            hook = slug
        }
        let rule = AutomationRule(name: name.trimmingCharacters(in: .whitespaces), projects: project.isEmpty ? [] : [project],
                                  kinds: kind.isEmpty ? [] : [kind],
                                  words: words.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                  notify: notify, webhook: hook)
        change { $0.append(rule) }
        if notify { Automator.askToNotify() }
        adding = false
        (name, words, webhook, hookName, hookURL, problem) = ("", "", "", "", "", nil)
    }

    private func index(_ rule: AutomationRule) -> Int { rules.firstIndex { $0.id == rule.id } ?? 0 }

    private func change(_ edit: (inout [AutomationRule]) -> Void) {
        var new = rules
        edit(&new)
        do {
            try Automations.save(new, root: app.root)
            rules = new
            problem = nil
        } catch {
            problem = "Couldn't save automations: \(error.localizedDescription)"
        }
    }

    private func summary(_ rule: AutomationRule) -> String {
        let scope = rule.projects.first ?? "Any project"
        let when = rule.kinds.first.map(Self.label) ?? "anything changes"
        let has = rule.words.isEmpty ? "" : " with “\(rule.words.joined(separator: "”, “"))”"
        let then = [rule.notify ? "notify" : nil, rule.webhook.map { "post to \($0)" }].compactMap { $0 }.joined(separator: " and ")
        return "\(scope) · \(when)\(has) → \(then)"
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case "decided": return "A decision is saved"
        case "new": return "Something new appears"
        case "closed": return "Something is closed"
        case "reopened": return "Something reopens"
        case "status": return "A status changes"
        case "attested": return "A step is attested"
        case "removed": return "Something is removed"
        case "added": return "A file is shared"
        default: return kind
        }
    }
}
