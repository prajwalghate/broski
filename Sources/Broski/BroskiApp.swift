import AppKit
import BroskiCore

@main
enum BroskiApp {
    @MainActor
    static func main() {
        // Used by scripts/build-app.sh to render the icon from the same drawing code as the app.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-icons"), i + 1 < args.count {
            do {
                try BroskiArt.exportIcons(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
                _exit(0)
            } catch {
                FileHandle.standardError.write(Data("Icon export failed: \(error)\n".utf8))
                _exit(1)
            }
        }

        if let i = args.firstIndex(of: "--export-launch-art"), i + 1 < args.count {
            NSApplication.shared.setActivationPolicy(.prohibited)
            do {
                try LaunchArt.export(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
                _exit(0)
            } catch {
                FileHandle.standardError.write(Data("Launch art failed: \(error)\n".utf8))
                _exit(1)
            }
        }
        // Claude Code / Claude Desktop launch this to read your notes (see Settings › AI › Connect).
        if args.contains("--mcp") {
            MCPServer.run()
            _exit(0)
        }
        if let code = OnboardKit.command(args) { _exit(code) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshots.run(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            _exit(0)
        }
        if let i = args.firstIndex(of: "--chat-check"), i + 1 < args.count {
            _exit(ChatCheck.run(report: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        // scripts/install-mac.sh: can this build read the real Broski folder? Reads only; the report holds counts.
        if let i = args.firstIndex(of: "--check-folder"), i + 1 < args.count {
            let report = FolderCheck.run(root: AppModel.notesRoot)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: URL(fileURLWithPath: args[i + 1]))
            _exit(report.ok ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--diagnose"), i + 2 < args.count {
            Diagnostics.run(audio: URL(fileURLWithPath: args[i + 1]), report: URL(fileURLWithPath: args[i + 2]))
            _exit(0)
        }

        oneAtATime()

        // Tooltips after 0.4 s instead of macOS's 1.5 s, so hovering an icon says what it does (Broski only).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    /// One Broski at a time (see SingleInstance): a second copy shows the running one and exits, and the installed
    /// copy replaces a build or a kept copy that Spotlight opened first.
    @MainActor
    private static func oneAtATime() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        let running = others.map {
            SingleInstance.Running(pid: $0.processIdentifier, path: $0.bundleURL?.standardizedFileURL.path ?? "", terminated: $0.isTerminated)
        }
        let decision = SingleInstance.decide(running, me: ProcessInfo.processInfo.processIdentifier, installed: "/Applications/Broski.app")
        func other(_ pid: Int32) -> NSRunningApplication? { others.first { $0.processIdentifier == pid } }
        func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
        Log.fileURL = AppModel.notesRoot.appendingPathComponent(".broski/broski.log")
        switch decision {
        case .run:
            return
        case .replace(let pid):
            guard let app = other(pid) else { return }
            Log.info("Quitting the Broski running from \(app.bundleURL?.path ?? "another copy") so the installed one runs")
            app.terminate()
            // A copy keeping a note as a draft takes up to 6 s to quit.
            let deadline = Date().addingTimeInterval(10)
            while alive(pid), Date() < deadline { usleep(200_000) }
            if alive(pid) { app.forceTerminate() }
        case .handOver(let pid):
            guard let app = other(pid) else { return }
            Log.info("Broski is already running from \(app.bundleURL?.path ?? "another copy"); showing that one instead of starting \(Bundle.main.bundlePath)")
            if let url = app.bundleURL {
                // Opening the running copy asks it to reopen, which shows its dashboard.
                let done = DispatchSemaphore(value: 0)
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
                _ = done.wait(timeout: .now() + 3)
            }
            // It was quitting after all: start, so clicking Broski never leaves nothing running.
            guard alive(pid) else { return }
            Log.flush()
            _exit(0)
        }
    }
}
