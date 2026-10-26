import BroskiCore
import SwiftUI
import UserNotifications

@main
struct BroskiPhoneApp: App {
    @StateObject private var store: PhoneStore
    @StateObject private var capture: CaptureModel
    @StateObject private var home: PhoneHome
    @StateObject private var recorder = Recorder()
    @StateObject private var router = PhoneRouter.shared
    @Environment(\.scenePhase) private var phase
    @State private var tab = Tab.talk
    @State private var showCheckIn = false
    /// The private vault while it's on screen; a fresh, locked session each time.
    @State private var vault: VaultSession?

    enum Tab { case talk, capture, notes, settings }

    init() {
        let store = PhoneStore()
        _store = StateObject(wrappedValue: store)
        _capture = StateObject(wrappedValue: CaptureModel(store: store))
        _home = StateObject(wrappedValue: PhoneHome(store: store))
        // Filing, Ask and reports (not yet through the model gateway) are logged with the rest.
        ClaudeClient.onUsage = { model, task, usage in
            Task { @MainActor in
                try? UsageLog.append(UsageLog.Entry(device: "iphone", role: UsageLog.role(forModel: model), provider: "claude", model: model,
                                                    project: nil, usage: usage, task: task ?? "other"), root: store.root)
            }
        }
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                TalkScreen(model: home, store: store, recorder: recorder, onRiff: { openRiff(listening: false) })
                    .tabItem { Label("Talk", systemImage: "bubble.left.and.text.bubble.right") }
                    .tag(Tab.talk)
                CaptureView(capture: capture, recorder: recorder, store: store)
                    .tabItem { Label("Capture", systemImage: "square.and.pencil") }
                    .tag(Tab.capture)
                NotesView(store: store)
                    .tabItem { Label("Notes", systemImage: "square.stack") }
                    .tag(Tab.notes)
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .tint(Brand.purple)
            .onOpenURL { router.handle($0) }
            .onChange(of: router.request) { _, request in route(request) }
            .onAppear {
                // The mic taken away mid-recording (a call, Siri, an error): what was said still lands where it
                // was said (the conversation's box, or the note).
                recorder.onInterrupted = { heard in keepHeard(heard) }
                recorder.vocabulary = { [store] in store.projects }
                home.openVault = { note in
                    let session = VaultSession(root: store.root)
                    if let note { session.queue(note) }
                    vault = session
                }
                route(router.request)
                if let i = CommandLine.arguments.firstIndex(of: "--bark-selftest"), i + 1 < CommandLine.arguments.count {
                    Task { await PhoneBark.shared.selfTest(file: CommandLine.arguments[i + 1]) }
                } else {
                    PhoneBark.shared.warmUp()
                }
            }
            .sheet(isPresented: $showCheckIn) { CheckInScreen(store: store) }
            .sheet(isPresented: Binding(get: { vault != nil }, set: { if !$0 { vault?.lock(); vault = nil } })) {
                if let vault { VaultScreen(session: vault) }
            }
            // Talk and Capture share one mic: leaving a screen ends its recording, and its words stay where they were
            // said (in the conversation's box, or the note).
            .onChange(of: tab) { old, _ in
                guard recorder.isRecording else { return }
                Task {
                    let heard = await recorder.stop()
                    if old == .capture { capture.addSpoken(heard) }
                    if old == .talk { home.addHeard(heard) }
                }
            }
            .onChange(of: phase) { _, new in
                if new == .active {
                    store.reload()
                    home.reload()
                    Task { await CheckInSchedule.refresh(items: store.items) }
                }
                // Going to the background ends a recording at once but keeps what was said for a note in the draft.
                // One already stopping hands its words to whoever stopped it.
                if new == .background, recorder.isRecording, !recorder.isStopping {
                    keepHeard(recorder.stopNow())
                }
            }
        }
    }
}

extension BroskiPhoneApp {
    /// Siri, the Action Button, Control Center, notifications and links all land here.
    private func route(_ request: PhoneRouter.Request?) {
        guard let request else { return }
        router.request = nil
        // A broski:// link opens the screen but never starts the mic; only what you trigger yourself does.
        let listen = !router.fromLink
        switch request {
        case .talk:
            tab = .talk
            guard listen, home.canTalk else { return }
            Task {
                // Give the app a moment to come forward before the mic starts.
                try? await Task.sleep(nanoseconds: 450_000_000)
                if !recorder.isRecording {
                    home.stopSpeaking()
                    await recorder.start()
                }
            }
        case .note:
            tab = .capture
            capture.focusRequest += 1
        case .ask:
            tab = .talk
        case .checkIn:
            showCheckIn = true
        case .riff:
            tab = .talk
            openRiff(listening: listen)
        }
    }

    /// Riff mode in the conversation (ends it, with the wrap-up card, when one is on). From Siri or the Action Button
    /// it starts listening too, for thinking out loud on a walk.
    private func openRiff(listening: Bool) {
        tab = .talk
        if home.riffing, !listening {
            home.endRiff()
            return
        }
        home.startRiff(about: nil)
        guard listening, home.canTalk, !home.thinking else { return }
        Task {
            // Give the app a moment to come forward, and a recording on Capture time to hand over its words.
            try? await Task.sleep(nanoseconds: 600_000_000)
            for _ in 0..<40 where recorder.isRecording || recorder.finishing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if !recorder.isRecording {
                home.stopSpeaking()
                await recorder.start()
            }
        }
    }

    /// Words from a recording that ended without its screen asking (the mic taken away, the app sent to the
    /// background): the conversation's box keeps them on Talk, the note on Capture.
    private func keepHeard(_ heard: String) {
        if tab == .capture {
            capture.addSpoken(heard)
        } else if tab == .talk {
            home.addHeard(heard)
        }
    }
}

enum Brand {
    /// #7d4dff, the design system's purple.
    static let purple = Color(red: 125 / 255, green: 77 / 255, blue: 1)
    /// The design system's private-mode text: #94560a on light, #ffbe4d on dark.
    static let privateText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 190 / 255, blue: 77 / 255, alpha: 1)
            : UIColor(red: 148 / 255, green: 86 / 255, blue: 10 / 255, alpha: 1)
    })
}

extension NoteKind {
    var label: String {
        switch self {
        case .note: return "Note"
        case .idea: return "Idea"
        case .todo: return "Todo"
        case .bug: return "Bug"
        }
    }

    var symbol: String {
        switch self {
        case .note: return "note.text"
        case .idea: return "lightbulb"
        case .todo: return "checkmark.circle"
        case .bug: return "ladybug"
        }
    }

    var color: Color {
        switch self {
        case .note: return .secondary
        case .idea: return .yellow
        case .todo: return .blue
        case .bug: return .red
        }
    }
}
