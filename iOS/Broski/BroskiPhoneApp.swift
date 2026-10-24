import BroskiCore
import SwiftUI
import UserNotifications

@main
struct BroskiPhoneApp: App {
    @StateObject private var store: PhoneStore
    @StateObject private var capture: CaptureModel
    @StateObject private var riff: PhoneRiff
    @StateObject private var recorder = Recorder()
    @StateObject private var router = PhoneRouter.shared
    @Environment(\.scenePhase) private var phase
    @State private var tab = Tab.capture
    @State private var showCheckIn = false
    @State private var showRiff = false

    enum Tab { case capture, notes, ask, settings }

    init() {
        let store = PhoneStore()
        _store = StateObject(wrappedValue: store)
        _capture = StateObject(wrappedValue: CaptureModel(store: store))
        _riff = StateObject(wrappedValue: PhoneRiff(store: store))
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                CaptureView(capture: capture, recorder: recorder, store: store)
                    .tabItem { Label("Capture", systemImage: "square.and.pencil") }
                    .tag(Tab.capture)
                NotesView(store: store)
                    .tabItem { Label("Notes", systemImage: "square.stack") }
                    .tag(Tab.notes)
                AskScreen(store: store, recorder: recorder, onRiff: { openRiff(listening: false) })
                    .tabItem { Label("Ask", systemImage: "sparkle.magnifyingglass") }
                    .tag(Tab.ask)
                SettingsView(store: store)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)
            }
            .tint(Brand.purple)
            .onOpenURL { router.handle($0) }
            .onChange(of: router.request) { _, request in route(request) }
            .onAppear {
                // The mic taken away mid-recording (a call, Siri, an error): what was said for a note (or the riff)
                // still lands in it.
                recorder.onInterrupted = { heard in keepHeard(heard) }
                recorder.vocabulary = { [store] in store.projects }
                route(router.request)
                if CommandLine.arguments.contains("--riff-selftest") {
                    Task { await PhoneRiff.selfTest(store: store) }
                }
                if let i = CommandLine.arguments.firstIndex(of: "--bark-selftest"), i + 1 < CommandLine.arguments.count {
                    Task { await PhoneBark.shared.selfTest(file: CommandLine.arguments[i + 1]) }
                } else {
                    PhoneBark.shared.warmUp()
                }
            }
            .sheet(isPresented: $showCheckIn) { CheckInScreen(store: store) }
            .sheet(isPresented: $showRiff) { RiffScreen(model: riff, store: store, recorder: recorder) }
            // Capture and Ask share one mic: leaving a screen ends its recording, and only a note keeps the words
            // (a question dictated on Ask mustn't end up in the note).
            .onChange(of: tab) { old, _ in
                guard recorder.isRecording else { return }
                Task {
                    let heard = await recorder.stop()
                    if old == .capture { capture.addSpoken(heard) }
                }
            }
            .onChange(of: phase) { _, new in
                if new == .active {
                    store.reload()
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
        // Everything else opens behind the riff, so it steps aside (it's kept for next time).
        if request != .riff { showRiff = false }
        switch request {
        case .talk:
            tab = .capture
            Task {
                // Give the app a moment to come forward before the mic starts.
                try? await Task.sleep(nanoseconds: 450_000_000)
                if !recorder.isRecording { await recorder.start() }
            }
        case .note:
            tab = .capture
            capture.focusRequest += 1
        case .ask:
            tab = .ask
        case .checkIn:
            showCheckIn = true
        case .riff:
            tab = .ask
            openRiff(listening: true)
        }
    }

    /// Opens the riff where you left it (a saved one makes way for a new one). From Siri or the Action Button it
    /// starts listening too, for thinking out loud on a walk.
    private func openRiff(listening: Bool) {
        if riff.saved != nil {
            // Words waiting in the box come along to the new riff.
            let waiting = riff.draft
            riff.newRiffGuessingProject()
            riff.draft = waiting
        } else if !riff.started, riff.draft.isEmpty, riff.riff.project == nil {
            riff.newRiffGuessingProject()
        }
        showRiff = true
        guard listening, riff.hasKey, riff.wrap == nil, !riff.thinking else { return }
        Task {
            // Give the app a moment to come forward, and a recording on Capture time to hand over its words.
            try? await Task.sleep(nanoseconds: 600_000_000)
            for _ in 0..<40 where recorder.isRecording || recorder.finishing {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if showRiff, !recorder.isRecording { await recorder.start() }
        }
    }

    /// Words from a recording that ended without its screen asking (the mic taken away, the app sent to the
    /// background): the open riff keeps them, else a note on Capture does. A question on Ask doesn't.
    private func keepHeard(_ heard: String) {
        if showRiff {
            riff.addHeard(heard)
        } else if tab == .capture {
            capture.addSpoken(heard)
        }
    }
}

enum Brand {
    static let purple = Color(red: 0.47, green: 0.33, blue: 0.95)
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
