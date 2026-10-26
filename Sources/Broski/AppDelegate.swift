import AppKit
import BroskiCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var app: AppModel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.resolveMissingNotesFolder()
        let root = AppModel.notesRoot
        try? FileManager.default.createDirectory(at: root.appendingPathComponent(".broski"), withIntermediateDirectories: true)
        Log.fileURL = root.appendingPathComponent(".broski/broski.log")

        app = AppModel(root: root)
        app.onStatusChange = { [weak self] in self?.refreshStatusItem() }
        app.quickMenu = { [weak self] in self?.quickMenu() ?? NSMenu() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        installMainMenu()

        Log.info("Broski \(app.version) started from \(Bundle.main.bundlePath) · accessibility \(ContextCapture.accessibilityAllowed ? "on" : "off") · screen recording \(CGPreflightScreenCaptureAccess() ? "on" : "off")")
        app.start()
        refreshStatusItem()
    }

    /// Opening Broski again (Finder, Spotlight, Dock) shows the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        app.showDashboard()
        return true
    }

    private var quitPending = false

    /// Quitting (the menu, logout, a restart) with a note open keeps it as a draft first, with its last phrase
    /// transcribed, so it comes back next launch. Whisper gets a few seconds at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard app?.capture.isCapturing == true else { return .terminateNow }
        quitPending = true
        Task { @MainActor [weak self] in
            await self?.app.capture.keepDraftForQuit()
            self?.finishQuit()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.finishQuit()
        }
        return .terminateLater
    }

    private func finishQuit() {
        guard quitPending else { return }
        quitPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.capture.engine.stop()
        Log.info("Broski quit")
        Log.flush()
        UserDefaults.standard.synchronize()
        // whisper.cpp's Metal teardown aborts inside exit()'s static destructors, which made every
        // quit look like a crash. Everything is saved by now, so leave without running them.
        _exit(0)
    }

    // MARK: Menu bar

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = BroskiArt.menuBarImage(talking: app.capture.isCapturing || app.isOnCall)
        button.toolTip = "Broski: \(app.statusLine)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(app.statusLine))
        for problem in app.problems { menu.addItem(disabled("⚠︎ " + problem)) }
        menu.addItem(.separator())
        // A menu item can only live in one menu, so move them across from a fresh quick menu.
        let quick = quickMenu()
        while let first = quick.items.first {
            quick.removeItem(first)
            menu.addItem(first)
        }
    }

    /// Shared by the menu bar and the floating button's right-click.
    private func quickMenu() -> NSMenu {
        let menu = NSMenu()
        if app.config.conversationFirst {
            menu.addItem(shortcutItem("Talk to Broski", #selector(talk), spec: app.config.hotkey))
            menu.addItem(shortcutItem("Quick note", #selector(newNote), spec: app.config.noteHotkey))
        } else {
            menu.addItem(shortcutItem("New note", #selector(newNote), spec: app.config.hotkey))
        }
        let shot = item("Screenshot note", #selector(screenshotNote))
        if let parsed = HotKey.parse(app.config.screenshotHotkey) {
            shot.keyEquivalent = parsed.keyEquivalent
            shot.keyEquivalentModifierMask = parsed.flags
        }
        menu.addItem(shot)
        let clip = item("Clip highlighted text", #selector(clipSelection))
        if let parsed = HotKey.parse(app.config.clipHotkey) {
            clip.keyEquivalent = parsed.keyEquivalent
            clip.keyEquivalentModifierMask = parsed.flags
        }
        menu.addItem(clip)
        if app.capture.canAddMore {
            menu.addItem(item("Add to last note", #selector(addToLastNote)))
        }
        menu.addItem(.separator())
        menu.addItem(shortcutItem("Ask Broski", #selector(askBroski), spec: app.config.askHotkey))
        menu.addItem(shortcutItem("Help with this", #selector(helpWithThis), spec: app.config.helpHotkey))
        menu.addItem(item("Riff", #selector(riff)))
        menu.addItem(item(app.isOnCall ? "Stop call notes" : "Take notes on a call", #selector(callNotes)))
        menu.addItem(item("Check-in now", #selector(checkIn)))
        if let session = app.library.activeSession {
            menu.addItem(item("Wrap up “\(session.title)”", #selector(wrapUpSession)))
        }
        menu.addItem(item("What Broski knows", #selector(openMemory)))
        menu.addItem(item("Private Vault…", #selector(openVault)))
        menu.addItem(item("Open dashboard", #selector(openDashboard)))
        menu.addItem(.separator())
        let button = item("Floating Broski head", #selector(toggleButton))
        button.state = app.config.showFloatingButton ? .on : .off
        menu.addItem(button)
        let door = item("Shortcut opens the conversation", #selector(toggleFrontDoor))
        door.state = app.config.conversationFirst ? .on : .off
        menu.addItem(door)
        let fn = item("Hold fn to talk", #selector(toggleFn))
        fn.state = app.config.fnHoldToTalk ? .on : .off
        menu.addItem(fn)
        let pill = item("Pill at the top of the screen", #selector(togglePill))
        pill.state = app.config.showPill ? .on : .off
        menu.addItem(pill)
        let wake = item("Listen for “\(app.config.wakeWords.first ?? "broski")”", #selector(toggleWake))
        wake.state = app.config.wakeWordEnabled ? .on : .off
        menu.addItem(wake)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Broski", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    // MARK: Main menu

    /// Shown while a Broski window is open. Its Edit menu is also what makes ⌘C/⌘V work in text fields.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Broski", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Broski", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Broski", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu))

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("New Note", #selector(newNote), key: "n"))
        fileMenu.addItem(item("Dashboard", #selector(openDashboard), key: "d"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(editMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    // MARK: Actions

    @objc private func newNote() { app.capture.trigger(.shortcut) }
    @objc private func talk() { app.showHome() }
    @objc private func toggleFrontDoor() { app.update { $0.frontDoor = $0.conversationFirst ? "note" : "conversation" } }
    @objc private func clipSelection() { app.capture.clipSelection() }
    @objc private func askBroski() { app.showAsk(nil) }
    @objc private func helpWithThis() { app.companion.helpWithThis() }
    @objc private func riff() { app.showRiff(project: nil, opening: nil) }
    @objc private func callNotes() { app.toggleCall() }
    @objc private func checkIn() { app.companion.checkInNow() }

    private func shortcutItem(_ title: String, _ action: Selector, spec: String) -> NSMenuItem {
        let entry = item(title, action)
        if let parsed = HotKey.parse(spec) {
            entry.keyEquivalent = parsed.keyEquivalent
            entry.keyEquivalentModifierMask = parsed.flags
        }
        return entry
    }
    @objc private func addToLastNote() { app.capture.continueLastNote() }
    @objc private func screenshotNote() { app.capture.screenshotShortcut() }
    @objc private func wrapUpSession() {
        guard let session = app.library.activeSession else { return }
        app.library.endSession(session)
        app.showDashboard(project: session.project)
        Task { await app.library.writeReport(for: session) }
    }
    @objc private func openDashboard() { app.showDashboard() }
    @objc private func openMemory() { app.showMemory() }
    @objc private func openVault() { app.showVault() }
    @objc private func openSettings() { app.showSettings() }
    @objc private func toggleButton() { app.update { $0.showFloatingButton.toggle() } }
    @objc private func togglePill() { app.update { $0.showPill.toggle() } }
    @objc private func toggleFn() { app.update { $0.fnHoldToTalk.toggle() } }
    @objc private func toggleWake() { app.update { $0.wakeWordEnabled.toggle() } }
    @objc private func quit() { NSApp.terminate(nil) }
}
