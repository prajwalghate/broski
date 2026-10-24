import Foundation

/// Settings stored in ~/Broski/config.json. Missing keys fall back to defaults,
/// so a hand-edited file with only one key still works.
public struct BroskiConfig: Codable, Equatable {
    /// Show the floating Broski button. Click it to take a note.
    public var showFloatingButton: Bool
    /// Keep the mic on and listen for the wake word. Off by default: costs battery and keeps the mic indicator lit.
    public var wakeWordEnabled: Bool
    /// Start listening as soon as the note panel opens from the button or shortcut.
    public var startMicOnOpen: Bool
    public var wakeWords: [String]
    /// Folders whose subfolders count as projects you can name.
    public var projectRoots: [String]
    public var hotkey: String
    /// How long a pause ends a dictated note.
    public var silenceSeconds: Double
    /// "auto" uses the system language and falls back to en-US.
    public var locale: String
    public var mirrorToProjectFolder: Bool
    public var playSounds: Bool
    /// Global shortcut that takes a screenshot and opens a capture with it.
    public var screenshotHotkey: String
    /// Grabs the text you've highlighted in any app into a note.
    public var clipHotkey: String
    /// Remember the browser page you were on (macOS asks once per browser).
    public var captureBrowserPage: Bool
    /// Remember the window title and selected text (needs Accessibility access).
    public var captureWindowDetails: Bool
    /// Show Apple's live transcript while you talk; Whisper still writes the final text.
    public var livePreview: Bool
    /// Apple voice processing: echo cancellation and noise suppression on the mic.
    public var voiceIsolation: Bool
    /// Save on a pause without asking. Off: you review the transcript and press Return.
    public var autoSave: Bool

    // The companion
    /// How much Broski speaks up on its own: quiet (only when asked), daily, active.
    public var companionMode: CompanionMode = .quiet
    /// The small pill at the top of the screen where nudges, Ask and Help appear without stealing focus.
    public var showPill: Bool = false
    /// Hold fn (🌐) anywhere to talk, like holding the note shortcut. Needs Accessibility.
    public var fnHoldToTalk: Bool = false
    /// Speech-to-text: "auto" (Bark for English when it's downloaded, Whisper otherwise), "bark" or "whisper".
    public var speechEngine: String = "auto"
    /// Keeps the pill down to Broski's head until you point at it (or it has something to show), so it doesn't sit over your work.
    public var pillTucked: Bool = true
    /// The morning check-in is opt-in; you pick the time and what it covers.
    public var checkInEnabled: Bool = false
    public var checkInTime: String = "09:30"
    public var checkInOptions: CheckIn.Options = CheckIn.Options()
    /// Projects whose notes never go to Claude (filing falls back to Broski's rules for them).
    public var localOnlyProjects: [String] = []
    /// Keep each project's living page up to date with Claude when notes change.
    public var autoCompilePages: Bool = true
    public var askHotkey: String = "option+shift+a"
    public var helpHotkey: String = "option+shift+h"
    /// Read riff replies aloud.
    public var speakReplies: Bool = false
    /// Names your trackers use for you ("sam", "founder"), so "waiting on you" finds what's yours.
    public var ownerAliases: [String] = []
    /// What the main shortcut and fn open: "conversation" (talk to Broski) or "note" (the quick-note panel, as before).
    public var frontDoor: String = "conversation"
    /// The quick-note shortcut while the conversation is the front door.
    public var noteHotkey: String = "option+shift+n"
    /// Which model does what; nil means the defaults (Claude by role).
    public var models: ModelSettings? = nil

    /// The conversation opens on the main shortcut and fn.
    public var conversationFirst: Bool { frontDoor != "note" }

    public static let defaults = BroskiConfig(
        showFloatingButton: false,
        wakeWordEnabled: false,
        startMicOnOpen: false,
        wakeWords: ["broski"],
        projectRoots: [],
        hotkey: "option+shift+b",
        silenceSeconds: 2.0,
        locale: "auto",
        mirrorToProjectFolder: false,
        playSounds: true,
        screenshotHotkey: "option+shift+s",
        clipHotkey: "option+shift+c",
        captureBrowserPage: true,
        captureWindowDetails: true,
        livePreview: true,
        voiceIsolation: true,
        autoSave: false
    )

    public init(
        showFloatingButton: Bool, wakeWordEnabled: Bool, startMicOnOpen: Bool, wakeWords: [String],
        projectRoots: [String], hotkey: String, silenceSeconds: Double, locale: String,
        mirrorToProjectFolder: Bool, playSounds: Bool, screenshotHotkey: String = "option+shift+s", clipHotkey: String = "option+shift+c",
        captureBrowserPage: Bool = true, captureWindowDetails: Bool = true, livePreview: Bool = true, voiceIsolation: Bool = true, autoSave: Bool = false
    ) {
        self.autoSave = autoSave
        self.voiceIsolation = voiceIsolation
        self.screenshotHotkey = screenshotHotkey
        self.clipHotkey = clipHotkey
        self.captureBrowserPage = captureBrowserPage
        self.captureWindowDetails = captureWindowDetails
        self.livePreview = livePreview
        self.showFloatingButton = showFloatingButton
        self.wakeWordEnabled = wakeWordEnabled
        self.startMicOnOpen = startMicOnOpen
        self.wakeWords = wakeWords
        self.projectRoots = projectRoots
        self.hotkey = hotkey
        self.silenceSeconds = silenceSeconds
        self.locale = locale
        self.mirrorToProjectFolder = mirrorToProjectFolder
        self.playSounds = playSounds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        // One bad value falls back on its own, so it can't throw away the rest (localOnlyProjects above all).
        showFloatingButton = (try? c.decodeIfPresent(Bool.self, forKey: .showFloatingButton)) ?? d.showFloatingButton
        wakeWordEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .wakeWordEnabled)) ?? d.wakeWordEnabled
        startMicOnOpen = (try? c.decodeIfPresent(Bool.self, forKey: .startMicOnOpen)) ?? d.startMicOnOpen
        wakeWords = (try? c.decodeIfPresent([String].self, forKey: .wakeWords)) ?? d.wakeWords
        projectRoots = (try? c.decodeIfPresent([String].self, forKey: .projectRoots)) ?? d.projectRoots
        hotkey = (try? c.decodeIfPresent(String.self, forKey: .hotkey)) ?? d.hotkey
        silenceSeconds = (try? c.decodeIfPresent(Double.self, forKey: .silenceSeconds)) ?? d.silenceSeconds
        locale = (try? c.decodeIfPresent(String.self, forKey: .locale)) ?? d.locale
        mirrorToProjectFolder = (try? c.decodeIfPresent(Bool.self, forKey: .mirrorToProjectFolder)) ?? d.mirrorToProjectFolder
        playSounds = (try? c.decodeIfPresent(Bool.self, forKey: .playSounds)) ?? d.playSounds
        screenshotHotkey = (try? c.decodeIfPresent(String.self, forKey: .screenshotHotkey)) ?? d.screenshotHotkey
        clipHotkey = (try? c.decodeIfPresent(String.self, forKey: .clipHotkey)) ?? d.clipHotkey
        captureBrowserPage = (try? c.decodeIfPresent(Bool.self, forKey: .captureBrowserPage)) ?? d.captureBrowserPage
        captureWindowDetails = (try? c.decodeIfPresent(Bool.self, forKey: .captureWindowDetails)) ?? d.captureWindowDetails
        livePreview = (try? c.decodeIfPresent(Bool.self, forKey: .livePreview)) ?? d.livePreview
        voiceIsolation = (try? c.decodeIfPresent(Bool.self, forKey: .voiceIsolation)) ?? d.voiceIsolation
        autoSave = (try? c.decodeIfPresent(Bool.self, forKey: .autoSave)) ?? d.autoSave
        companionMode = (try? c.decodeIfPresent(CompanionMode.self, forKey: .companionMode)) ?? d.companionMode
        showPill = (try? c.decodeIfPresent(Bool.self, forKey: .showPill)) ?? d.showPill
        pillTucked = (try? c.decodeIfPresent(Bool.self, forKey: .pillTucked)) ?? d.pillTucked
        speechEngine = (try? c.decodeIfPresent(String.self, forKey: .speechEngine)) ?? d.speechEngine
        fnHoldToTalk = (try? c.decodeIfPresent(Bool.self, forKey: .fnHoldToTalk)) ?? d.fnHoldToTalk
        checkInEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .checkInEnabled)) ?? d.checkInEnabled
        checkInTime = (try? c.decodeIfPresent(String.self, forKey: .checkInTime)) ?? d.checkInTime
        checkInOptions = (try? c.decodeIfPresent(CheckIn.Options.self, forKey: .checkInOptions)) ?? d.checkInOptions
        // A hand-typed single name ("localOnlyProjects": "Secret") counts as a one-item list. Anything else malformed
        // throws rather than falling back to []: readers fail closed on a throw (loadOrCreate recovers the names, the phone
        // keeps every project local), where an empty list would quietly send these projects to Claude.
        if let list = try? c.decodeIfPresent([String].self, forKey: .localOnlyProjects) {
            localOnlyProjects = list
        } else if let name = try? c.decodeIfPresent(String.self, forKey: .localOnlyProjects) {
            localOnlyProjects = [name]
        } else if c.contains(.localOnlyProjects), (try? c.decodeNil(forKey: .localOnlyProjects)) != true {
            throw DecodingError.dataCorruptedError(forKey: .localOnlyProjects, in: c,
                                                   debugDescription: "localOnlyProjects must be a list of project names")
        } else {
            localOnlyProjects = d.localOnlyProjects
        }
        autoCompilePages = (try? c.decodeIfPresent(Bool.self, forKey: .autoCompilePages)) ?? d.autoCompilePages
        askHotkey = (try? c.decodeIfPresent(String.self, forKey: .askHotkey)) ?? d.askHotkey
        helpHotkey = (try? c.decodeIfPresent(String.self, forKey: .helpHotkey)) ?? d.helpHotkey
        speakReplies = (try? c.decodeIfPresent(Bool.self, forKey: .speakReplies)) ?? d.speakReplies
        ownerAliases = (try? c.decodeIfPresent([String].self, forKey: .ownerAliases)) ?? d.ownerAliases
        frontDoor = (try? c.decodeIfPresent(String.self, forKey: .frontDoor)) ?? d.frontDoor
        noteHotkey = (try? c.decodeIfPresent(String.self, forKey: .noteHotkey)) ?? d.noteHotkey
        models = (try? c.decodeIfPresent(ModelSettings.self, forKey: .models)) ?? d.models
        if wakeWords.isEmpty { wakeWords = d.wakeWords }
        silenceSeconds = min(max(silenceSeconds, 0.8), 6)
    }

    public var projectRootURLs: [URL] {
        projectRoots.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// Reads the config, writing the defaults first if the file doesn't exist.
    /// Returns a warning when the file exists but can't be parsed.
    public static func loadOrCreate(at url: URL) -> (config: BroskiConfig, warning: String?) {
        let loaded = load(at: url)
        return (loaded.config, loaded.warning)
    }

    /// Like `loadOrCreate`, plus whether the local-only list can be trusted. When it can't (the file is there but
    /// can't be read, iCloud hasn't downloaded it yet, or its local-only list is beyond recovery), callers treat
    /// every project as local only and don't save over the file.
    public static func load(at url: URL) -> (config: BroskiConfig, warning: String?, trusted: Bool) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            // iCloud keeps a file it hasn't downloaded as ".config.json.icloud": fetch it, never write defaults over it.
            let stub = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
            if fm.fileExists(atPath: stub.path) {
                try? fm.startDownloadingUbiquitousItem(at: url)
                return (defaults, "config.json is still downloading from iCloud, so every project is local only until it arrives. Restart Broski then.", false)
            }
            try? defaults.save(to: url)
            return (defaults, nil, true)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (defaults, "config.json couldn't be read (\(error.localizedDescription)), so every project is local only and settings aren't saved until it can be. Restart Broski once it's fixed.", false)
        }
        do {
            return (try JSONDecoder().decode(BroskiConfig.self, from: data), nil, true)
        } catch {
            // A typo mustn't send local-only projects to Claude, and the next settings change saves over this file,
            // so keep the local-only list and a copy of what was written.
            let text = String(decoding: data, as: UTF8.self)
            var config = defaults
            config.localOnlyProjects = recoverLocalOnly(from: text)
            let backup = url.deletingPathExtension().appendingPathExtension("broken.json")
            let saved = (try? data.write(to: backup, options: .atomic)) != nil
            // The list was there but nothing could be recovered from it: don't guess, keep everything local.
            let trusted = !(config.localOnlyProjects.isEmpty && text.contains("localOnlyProjects"))
            return (config, "config.json couldn't be read, so defaults are in use"
                    + (saved ? " (your file is kept as \(backup.lastPathComponent))" : "")
                    + (trusted ? "" : "; every project is local only until it's fixed")
                    + ": \(error.localizedDescription)", trusted)
        }
    }

    /// The local-only projects, read without ever writing anything (for the MCP server and diagnostics). A config.json
    /// that's there but won't read or parse, or that iCloud hasn't downloaded yet, makes every project local only.
    public static func localOnly(root: URL, allProjects: () -> [String]) -> Set<String> {
        let fm = FileManager.default
        let url = root.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: url.path) else {
            return fm.fileExists(atPath: root.appendingPathComponent(".config.json.icloud").path) ? Set(allProjects()) : []
        }
        guard let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(BroskiConfig.self, from: data) else {
            return Set(allProjects())
        }
        return Set(config.localOnlyProjects)
    }

    /// The local-only project names from a config.json that won't parse, read straight from the text.
    static func recoverLocalOnly(from text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #""localOnlyProjects"\s*:\s*(\[[^\]]*\]?|\{[^}]*\}?|"[^"]*")"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return [] }
        let value = String(text[r])
        if let list = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) { return list }
        // A broken list (a trailing comma, a missing quote): take every quoted name in it.
        guard let names = try? NSRegularExpression(pattern: #""([^"]+)""#) else { return [] }
        return names.matches(in: value, range: NSRange(value.startIndex..., in: value))
            .compactMap { Range($0.range(at: 1), in: value).map { String(value[$0]) } }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Common places people keep code, for suggesting project folders on first run.
    public static func suggestedProjectRoots(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> [String] {
        let candidates = ["Developer", "Projects", "projects", "Code", "code", "dev", "src", "GitHub", "Documents/GitHub",
                          "Documents/Projects", "Documents/Code", "Documents/Work/ai_projects", "Work"]
        let fm = FileManager.default
        var seen = Set<String>()
        return candidates.compactMap { relative in
            let url = home.appendingPathComponent(relative, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
                  let key = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath,
                  seen.insert(key.lowercased()).inserted else { return nil }
            return "~/" + relative
        }
    }
}
