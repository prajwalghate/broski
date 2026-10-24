import AppKit

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
        if let i = args.firstIndex(of: "--diagnose"), i + 2 < args.count {
            Diagnostics.run(audio: URL(fileURLWithPath: args[i + 1]), report: URL(fileURLWithPath: args[i + 2]))
            _exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
