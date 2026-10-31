// Made by scripts/site/build.py --guide from docs/. Don't edit: change the docs, then run it again.

extension HowTo {
    public static let guide = #"""
# Getting started
Install Broski on a Mac and get through the first run: permissions, voice models, where your files live, and how to update or uninstall it.
This page takes you from download to your first conversation: installing Broski, the first run, the permissions it asks for, the voice models, and where your files live.
## What you need
A Mac with Apple silicon, on macOS 14 Sonoma or later.
## Install from a release
Download the latest zip from the Releases page.
## Build from source
You need macOS 15 or later with Xcode 26 or later (the full Xcode, not only the Command Line Tools). Clone this repository, then from its folder: That builds build/Broski.app with its icon, signs it, and starts it. The ad-hoc signature uses a designated requirement tied to the bundle ID, so the microphone, speech and folder permissions you grant survive rebuilds.
## The first run
A short welcome walks you through setup: How to call Broski: the keyboard shortcut, holding fn, the wake word "broski", and a floating Broski head. Pick any mix; you can change it later in Settings › General.
## Calling Broski
You can change every shortcut in Settings. The menu bar menu has the rest: the dashboard, What Broski knows, the private vault, riffs, the check-in, and switches for the floating head, the pill at the top of the screen and the wake word.
## Permissions
Broski asks for each permission when a feature first needs it. Everything except the microphone and speech recognition is optional.
## Voice models
Broski turns speech into text on your Mac. Three engines take part: Apple's dictation shows the words as you talk (the live preview). It needs Dictation turned on.
## Where your files live
Your Broski folder holds everything Broski knows: notes, conversations, memory, decisions, project pages, the files you share, and settings.
## Updating
Download the new release and replace the app in Applications. Your notes, settings and keys stay where they are.
## Uninstalling
Quit Broski from its menu.
Q: Which Macs does Broski run on? A: A Mac with Apple silicon, on macOS 14 Sonoma or later. Building it from source needs macOS 15 or later and the full Xcode 26 or later.
Q: Do I have to talk to Broski, or can I type? A: You can type everything. Voice is optional: the conversation and quick notes both take voice or typing; see Talking to Broski.
Q: Can I keep my Broski notes in iCloud Drive or Dropbox? A: Yes. Go to Settings › General › Notes folder › Choose and pick the folder: an empty folder gets your notes moved into it, and a folder that already has Broski notes is used as it is.

# Talking to Broski
How to talk to Broski: the conversation, quick notes, Ask, help with what's on screen, where notes go, and the dashboard of every project.
There are two ways in. The conversation (⌥⇧B, or hold fn) is where you think out loud with Broski: it replies, remembers, and offers to save what matters.
## The conversation
Press ⌥⇧B on the Mac, or open the Talk tab on the iPhone. It's one conversation on both, kept as plain files (conversations/<month>/<day>.<device>.jsonl).
## Quick notes
Press ⌥⇧N, or say "note: …" in the conversation. The note panel opens ready for typing, with the mic off.
## Ask, help and the companion
Ask Broski (⌥⇧A): ask anything about your notes and trackers, typed or spoken, and get an answer that cites its sources.
## Where notes go
Each note is plain markdown with a small header, so it reads well in Obsidian, VS Code, or Claude Code: Front-matter lines another editor adds are kept as they are when Broski saves the note. Notes from 0.2 (one bullet per line) are converted automatically on first launch; the originals are kept in .broski/legacy-0.2/.
## The dashboard
Menu bar › Open dashboard. Per project: Overview (the living page), Command center, Tracker, Board (Inbox, To do, Doing, Done; drag cards between columns), List, Sessions (a timeline plus the rendered report) and Screenshots.
Q: Does Broski save things without asking me? A: No. When you decide something or name a todo or a bug, Broski offers a save card, and nothing is saved until you tap Save.
Q: How do I make Broski forget something it learned about me? A: Say "forget that …", or just "forget that" for the last fact. Menu bar › What Broski knows shows everything it knows about you and what reflection changed, and every change can be undone.
Q: What is a project brief? A: A short page on what a project is and where it stands, in seven fixed sections, kept as brief.md in the project's folder.
Q: How do I get Claude Code to write a project's brief? A: Tap Copy a prompt for Claude Code on the project's card (or ⌘K › Ask Claude Code for the brief), paste it into that project's Claude Code thread, then paste the whole answer back into Broski.
Q: What is riff mode? A: A brainstorm on the deep model: Broski builds on your idea, brings real facts without inventing them, pushes back when something is weak, and ends with one question.
Q: Can Broski read a web page if I paste a link? A: Yes. It opens the page on your device before it replies and sends the page's text with your message, fenced as data. Pages behind a login can't be read, and Settings › Models › Links turns it off.

# Choosing your AI
Choose the AI behind Broski for each role: Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek, Ollama, LM Studio or Apple's model.
Broski isn't tied to one AI company. Every feature asks for a kind of model (a role), and you decide which provider and model fills each role.
## Roles
Settings › Models maps each role to a provider and one of its models. Change them whenever you like.
## Setting one up
The first-run welcome asks you to choose a provider, and Settings › Models lets you add more: Pick a provider.
## The presets
Prices change; check each provider's pricing page before you rely on it. For Claude, Broski prices calls from Anthropic's published prices: Haiku costs a small fraction of Sonnet, and Opus about twice Sonnet.
## Local-only projects
Mark a project local only and its text goes only to models on your device. A model counts as on your device when it's Apple's on-device model, Ollama, LM Studio, or a custom server at a loopback address (localhost, 127.0.0.1 or ::1) that you've marked as running on this Mac.
## Without any model
Broski still works. Quick notes are filed by its built-in phrase rules ("in the recipe box project, add a todo: …"), commands like "note: …" need no model, project pages are built from your notes by rules, and Ask lists the notes that match your question.
## Keys
Keys stay on the device you typed them on: Mac: ~/Library/Application Support/Broski/secrets.json, which only your user can read (mode 600). Not the Keychain: ad-hoc-signed builds get a new signature on every build, and the Keychain would ask for your login password each time.
## Spending
Settings › Models › Spending shows today's spend, this month's, and this month by model and by task (the conversation, save cards, riffs, project pages, filing, Ask, reports and so on).
## When something goes wrong
Errors name the provider and what to do: a key it didn't accept, an account out of credit, a model it doesn't have, a rate limit, or a local server that isn't running ("Couldn't reach Ollama at http://localhost:11434/v1.
Q: Can I use a different model for riffs than for everyday chat? A: Yes. Riffs use the deep role and the conversation uses the everyday role, and Settings › Models maps each role to its own provider and model.
Q: Can I set a spending limit? A: Yes, a daily limit in Settings › Models › Spending. Past it, work moves one role down for the rest of the day (deep to everyday, everyday to fast), and because only Claude calls are priced, the limit counts only Claude spending.
Q: Where does Broski keep my API key? A: On the device you typed it on. On the Mac it's in ~/Library/Application Support/Broski/secrets.json, readable only by your user; on the iPhone it's in the Keychain, and keys never sync between them.

# Privacy
What Broski sends to a model and what stays on your device: masked secrets, local-only projects, private mode, the encrypted vault and the mic.
Broski holds your thinking, so it's built to keep it yours: your notes are plain files you own, nothing leaves your device without you, and there are no accounts, analytics or tracking.
## The short version
Your notes, conversations and memory are files in your Broski folder. No account, no Broski server, no analytics.
## What goes to a model
Every call to a model goes through Broski's model gateway (ModelGateway in Sources/BroskiCore). No feature talks to a provider directly.
## Local-only projects
Mark a project local only (Settings › Companion › Living pages and privacy) and its text never reaches a cloud model: Its conversations, notes, pages, reports, call notes and help requests go only to models on your device: Apple's on-device model, Ollama, LM Studio, or a custom server at a loopback address marked as running on this Mac.
## Private mode
Say "go private" for a blank slate. In private mode Broski doesn't read what it knows about you, your projects, decisions or notes, and recalls nothing.
## Starting fresh
Settings › General › Start fresh has three separate levels. Each says what it clears and what it keeps, and none deletes anything.
## Links you share
When you paste a link, Broski opens the page on your device before it replies: Only http and https, and never an address with a password in it. Pages behind a login can't be read.
## The private vault
The vault (menu bar › Private Vault…, the iPhone's Talk › ⋯ › Private vault, or "vault: …" in the conversation) holds notes only your passphrase opens: Each note is its own file, encrypted with AES-256-GCM under a random 256-bit vault key. Titles are encrypted too.
## The microphone
The mic is off except while you talk or dictate a note.
## What's stored where
The event log never holds what you said, but it does hold file paths, which can include your Mac's user name. Check before you share it.
## What Broski connects to
Broski has no server of its own and sends no analytics or crash reports. It connects only to: The model providers you set up, when a feature calls a model.
## Reporting a problem
Found a way to make Broski leak, act without asking, or read what it shouldn't? Report it privately: see SECURITY.md.
Q: How do I reset Broski? A: Settings › General › Start fresh. Pause memory keeps everything but stops using it; Forget what Broski knows about me clears its memory of you; Start completely fresh moves the whole folder aside and begins again.
Q: Does Broski collect analytics or crash reports? A: No. Broski has no account, no server of its own, and sends no analytics or crash reports.
Q: Is private mode the same as using a local model? A: No. Private mode changes what Broski reads and keeps, not where the reply comes from: your messages still go to your everyday model, so if that's a cloud model, it gets what you say.
Q: Does Broski hide API keys and passwords before sending text to a model? A: Yes. The gateway masks common API keys and tokens, private key blocks, and .env-style lines whose name ends in KEY, TOKEN, SECRET or PASSWORD before anything is sent.
Q: What happens if I forget my vault passphrase? A: Your recovery key opens the vault instead; it's shown once and never stored. Lose both the passphrase and the recovery key and nobody can open it, including you.

# The iPhone app
Build and install the Broski iPhone app with a free Apple ID, sync it with your Mac through iCloud Drive, and set up its models and voice.
The iPhone app is Broski in your pocket: the same conversation as the Mac, quick notes, and your notes to browse and search.
## What's in it
Talk: the same conversation as the Mac, with memory, recall, citations, save cards, "note: …", remember and forget, think harder, private mode, riffs and thinking moves.
## What you need
A Mac with Xcode 26 or later, and XcodeGen: An Apple ID added in Xcode › Settings › Accounts. A free account gives you a personal team.
## Build and install
Copy the example settings file: Open iOS/Local.env and fill in two values:
## Sync with your Mac
The two apps share one Broski folder in iCloud Drive: On the Mac: Settings › General › Sync with iPhone. Your notes move from ~/Broski into iCloud Drive › Broski, and Broski restarts there.
## Models on the iPhone
The iPhone uses the roles and models you chose on the Mac, from config.json. Its Settings asks for a key for each provider in use; keys stay in the iPhone's Keychain and never sync.
## Voice on the iPhone
Apple's recognizer shows the words as you talk. For better English notes, download Bark in Settings › Voice (202 MB, under a minute on Wi-Fi, iOS 18 or later).
## The private vault on the iPhone
Talk › ⋯ › Private vault. It locks when Broski leaves the screen, hides its contents in the app switcher, and can open with Face ID after the first unlock.
Q: Do I need a paid Apple developer account for the iPhone app? A: No. A free Apple ID works, but an app signed with one stops opening after 7 days; run scripts/phone.sh again to renew it, and the app's data stays.
Q: How do I sync Broski between my Mac and iPhone? A: On the Mac, turn on Settings › General › Sync with iPhone, which moves your Broski folder into iCloud Drive. On the iPhone, choose Settings › Use my Mac's Broski folder and pick iCloud Drive › Broski itself, not a folder inside it.
Q: Can the iPhone app use Ollama or LM Studio on my Mac? A: No. A model on your Mac sits at an address only the Mac can reach. Apple's on-device model runs on the iPhone itself, with iOS 26 and Apple Intelligence on.

# Claude Code and MCP
Connect Claude Code, Claude Desktop or any MCP client to Broski's MCP server to read your notes, project pages, decisions and trackers.
Broski includes a Model Context Protocol (MCP) server, so Claude Code, Claude Desktop or any other MCP client can read your notes, project pages, decisions and trackers while you work.
## What it can and can't do
It reads your Broski folder in place. It doesn't copy anything anywhere.
## Connect Claude Code
The easy way: Settings › Connections › Connect (Claude Code) in Broski. It runs Claude Code's own claude mcp add for you and replaces an older registration if Broski moved.
## Connect Claude Desktop and other MCP clients
Settings › Connections › Copy config copies this entry. Paste it into the client's MCP servers list (for Claude Desktop, under mcpServers in claude_desktop_config.json): If a tool answers "Can't read Broski's notes", macOS is stopping the app that runs the client from reading your Broski folder.
## Tools
Note ids look like 2026-10-16-0452-login-bug. Tracker record ids carry their tracker's id, like recipe-box:DEC-14.
## Protocol details
Transport: standard input and output, one JSON-RPC object per line. Notifications get no reply.
Q: Can Claude Code change or delete my notes through Broski? A: No. The MCP server is read-only, except that tracker_add and tracker_set_status can add or update items in a tracker Broski keeps.
Q: How do I connect Broski to Claude Desktop? A: In Broski, Settings › Connections › Copy config copies the server entry. Paste it under mcpServers in claude_desktop_config.json.
Q: Why does Claude Code say it can't read Broski's notes? A: macOS is stopping the app that runs Claude Code from reading your Broski folder. Allow it in System Settings › Privacy & Security › Files and Folders.

# Projects and trackers
How Broski finds your projects, reads each project's own tracker in place without writing to it, and how to onboard a project.
Broski keeps one view over all your projects: your notes about each one, and each project's own tracker, read where it lives.
## Where projects come from
Your project folders. Every folder inside the folders you add in Settings › Projects (like ~/Developer) is a project you can name.
## Trackers, read in place
Broski reads each project's own tracker where it lives, and never copies it or writes to it. For example, it reads a command center from a pinned main commit, a register of items, a WORK-BOARD.md, or plain docs.
## A tracker Broski keeps
A project with no tracker gets Create a Broski tracker (Tracker › Onboard). It's plain markdown under projects/<p>/tracker/ that threads, people and Broski all edit: Broski edits only trackers it keeps (the New and status buttons on the Tracker tab), and so can Claude Code through MCP (tracker_add, tracker_set_status).
## Onboard a project
Onboarding asks a project's threads (its Claude Code sessions) where everything lives, so Broski can draft how to read that tracker.
## What's kept in your Broski folder
Q: Does Broski write to my project's repository or tracker? A: No. It reads each project's own tracker where it lives and never writes into a repository or runs its code. The only trackers it writes to are the ones it keeps itself, for projects that have none.
Q: Can Broski read my project's .env files? A: No. Broski never reads .env*, *.db, *.sqlite, *.pem, *.key, *.p12 or secrets.json, whatever a manifest says.
Q: What if my project doesn't have a tracker? A: Use Create a Broski tracker (Tracker › Onboard). You get plain markdown files in your Broski folder, in the project's own folder under projects/, which you, your Claude Code sessions and Broski can all edit.

# Troubleshooting
Fix Broski when the mic hears nothing, recognition is wrong, a shortcut or model fails, or sync looks off, starting from the event log.
Start with the event log: <Broski folder>/.broski/broski.log (~/Broski/.broski/broski.log, or ~/Library/Mobile Documents/com~apple~CloudDocs/Broski/.broski/broski.log once you sync with the iPhone).
## The mic hears nothing
"Turn on Dictation", or no transcript at all: turn on System Settings › Keyboard › Dictation. Apple's recognizer refuses to run without it, even on the device.
## Recognition is wrong
Made-up project names get misheard: pick the project chip in the panel. Whisper is primed with your project names, and Bark's cleanup snaps near-misses to them, but neither is perfect.
## Shortcuts and keys
A shortcut does nothing: another app may have taken it. Settings says so; pick another one there.
## Models
"<Provider> didn't accept the key": paste the key again in Settings › Models. Check it was made on the provider's own key page.
## Sync and files
"Broski can't find your notes folder": the folder you picked isn't there right now (a drive not mounted, iCloud signed out).
## Opening the app
macOS says it can't check Broski for malicious software: on macOS 15 or later, System Settings › Privacy & Security › Open Anyway; on macOS 14, right-click Broski in Applications › Open.
## Battery
The wake word keeps the mic on and uses noticeably more battery. Turn it off in the menu bar, and use the shortcut or hold fn instead.
## Seeing every screen
Render every screen with sample data, in light and dark: This draws the dashboard, the panel states, the conversation, onboarding and settings.
Q: Why doesn't Broski hear me? A: Check Dictation first: turn on System Settings › Keyboard › Dictation, because Apple's recognizer won't run without it. If the panel stays empty, check the input device in System Settings › Sound, since an iPhone or Bluetooth mic can win.
Q: Why does holding fn open the emoji picker? A: Set System Settings › Keyboard › "Press fn key to" (shown with a globe) to Do Nothing. Holding fn to talk also needs Accessibility.
Q: Why does Broski use so much battery? A: The wake word keeps the mic on and uses noticeably more battery. Turn it off in the menu bar and use the shortcut or hold fn instead.
"""#
}
