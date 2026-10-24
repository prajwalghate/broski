import AppIntents

/// Siri phrases, and the actions offered for the Action Button and in Shortcuts, with no setup.
struct BroskiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToBroskiIntent(), phrases: ["Talk to \(.applicationName)", "\(.applicationName), take a note", "Note with \(.applicationName)"],
                    shortTitle: "Talk to Broski", systemImageName: "mic.fill")
        AppShortcut(intent: NewBroskiNoteIntent(), phrases: ["New \(.applicationName) note", "Write a \(.applicationName) note"],
                    shortTitle: "New note", systemImageName: "square.and.pencil")
        AppShortcut(intent: AskBroskiIntent(), phrases: ["Ask \(.applicationName)"],
                    shortTitle: "Ask Broski", systemImageName: "sparkle.magnifyingglass")
        AppShortcut(intent: RiffWithBroskiIntent(), phrases: ["Riff with \(.applicationName)", "Think out loud with \(.applicationName)"],
                    shortTitle: "Riff", systemImageName: "bubble.left.and.bubble.right")
    }
}
