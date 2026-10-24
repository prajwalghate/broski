# Broski

A Mac sidekick for ideas that show up at random. Click the floating Broski head (or press **⌥⇧B**) and type, hold it and talk, or highlight text anywhere and press **⌥⇧C**. You check the note, press ⌘⏎, and it's filed into the right project before it evaporates. A dashboard shows every project and its notes; the notes themselves are plain markdown you own.

```
hold ⌥⇧B  →  "in the strado project, add a todo: rotate the API keys"  →  let go
             panel: "Will save to strado as a todo: “Rotate the API keys”"  →  ⌘⏎
~/Broski/projects/strado/2026-10-16-153200-rotate-the-api-keys.md
```

## What's in the box

- **Capture anything, anywhere.**
  - **How to start:** **⌥⇧B** for a note (hold it to talk), **⌥⇧S** for a screenshot note, Broski in the menu bar, or opt in to **holding fn** to talk anywhere, the wake word "broski", or a floating Broski head.
  - **What goes in:** talk, type, drop files, paste images, or grab screenshots. Each note also keeps what you were looking at: the app, the window title, the browser URL, and any selected text.
- **Never in your way.**
  - **The mic is off until you ask.** A tap or click opens the note ready for typing. **Hold** ⌥⇧B or the head to talk and let go when you're done, or click 🎙 and talk as long as you like.
  - **Pauses are fine.** The mic doesn't stop because you stopped to think. Whisper writes out each phrase while you pause, so the text is there the moment you're done.
  - **Nothing saves on its own.** You see the text and where it's going, edit it, add screenshots, then press ⌘⏎. Return is just a new line.
  - **Nothing gets lost.** Esc keeps a draft, and the next note brings it back.
- **Clip what you read.**
  - Highlight text in any app and press **⌥⇧C**, or right-click › Services › **Add to Broski**. It's quoted with the page or window it came from.
  - Keep highlighting and pressing ⌥⇧C to collect several clips into one note, then add what you think.
- **A brain for every project.** Each project gets a living page (`PROJECT.md`): where it stands, open bugs, todos, ideas, decisions and open questions. Every line links to the notes it came from. Claude keeps it up to date as notes change, and it suggests one-click actions: file an issue, mark done, merge duplicates, or hand a task to Claude Code.
- **Every project's tracker, read in place.**
  - Broski reads each project's own tracker where it lives and never copies it or writes to it. For example, it reads a command center from a pinned `main` commit, a register of items, a `WORK-BOARD.md`, or plain docs. A project with its own tracker shape keeps its manifest in Broski's folder (`trackers/<id>.broski.json`).
  - Every tracker maps onto the same core sections (ship, launch, ops, decisions, threads, open items), plus a project layer for what's unique to it (protocol parameters, backtests, courses).
  - Live state (step readiness, prices, health) comes only from the tracker's own board, with the time it was read. When the board is down, Broski says it's unknown instead of guessing.
  - Projects without a tracker get one in Broski's folder, which Broski can edit (new item, status changes), and so can Claude Code through MCP.
  - **It stays current.** Every read checks for drift: files no mapping reads, mappings that find nothing, status words nobody mapped, new threads. The Tracker tab says so, and **Ask the threads** asks only about what changed. Every change Broski sees (findings opened or closed, decisions made, steps attested) goes into a per-project change stream, which Claude Code reads with `changes_since`.
- **Ask Broski** (⌥⇧A): ask anything about your notes and trackers, by typing or by voice, and get an answer that cites its sources (`[[one:DEC-70]]`, `[[note-id]]`). "What's waiting on me", "what changed this week" and "what did we decide about X" work across projects.
- **Onboard a project.** Its threads (Claude Code sessions) answer a short questionnaire about where everything lives, and every answer must cite a real file, commit, record or transcript. Broski checks each citation, then drafts how to read that tracker. See [Onboard a project](#onboard-a-project).
- **A companion that knows when to speak.**
  - A small pill at the top of the screen holds Ask, Help with this, Riff, call notes and the check-in. It never takes focus.
  - Nudges when you come back to a project with open work, or when an idea has sat for weeks. Pick the dial (quiet, daily, active); there's a daily budget, and every nudge has Useful / Not now / Never.
  - An opt-in morning check-in, at a time you choose, covering what you choose.
  - **Help with this** (⌥⇧H): Broski looks at the window you're in, alongside your project's memory, and helps. For example, it explains an error or reviews a screen you're testing.
  - **Riff mode:** think out loud with Claude about a project, by voice or typing. Wrap it up into a note with ideas, decisions and todos. On the iPhone too: Ask › Riff, or "Riff with Broski" from Siri or the Action Button (it opens listening, and can read replies aloud). The riff is kept until you start a new one.
  - **Call notes:** your mic and the call's audio, transcribed locally as "Me" and "Them", then summarized with decisions and action items.
  - Related notes show while you write, and a near-duplicate offers "add to it instead".
- **Your notes in Claude Code.** Settings › AI › Connect adds Broski's read-only MCP server (`Broski --mcp`), so Claude Code can list projects, query trackers, ask what's waiting on you, read the journal of what changed, search notes and check onboarding answers.
- **Private where you want it.** Mark a project local only and its notes never go to Claude. Notes can live in any folder: iCloud Drive (to sync with the iPhone app), Dropbox, a Git repo, or ~/Broski.
- **Keep a thought going.** **Add more** (after saving, or from the menu) puts new text and screenshots under the note you just saved, stamped with the time.
- **Noise doesn't become notes.**
  - Echo cancellation and noise suppression on the mic, when your audio setup supports it.
  - Speech has to stand clear of the room's noise floor.
  - Silence is trimmed before Whisper sees it.
  - Segments Whisper rates as non-speech are dropped, along with its known silence phrases ("Thank you.").
- **Voice that works, on your Mac.**
  - **Bark 3.0** (English) runs on the Neural Engine: about 0.2 s per phrase, cooler than Whisper, and more accurate on meetings. A cleanup pass drops "um", snaps near-misses to your project names ("strato" → strado) and punctuates.
  - **Whisper** (large-v3-turbo, Metal) handles every other language, is primed with your project names, and takes over whenever Bark can't run. Settings › Voice picks the engine (Automatic by default).
  - Apple's dictation only drives the live preview.
- **Bark on the iPhone too** (iOS 18+). Settings › Voice downloads it (202 MB, under a minute on Wi-Fi); the first preparation takes about 5 minutes with Broski open. Then Bark writes each English note when you stop, about 0.3 s for a 5-second phrase on an iPhone 15, with the same cleanup and your project names. Apple's recognizer shows the words as you talk and writes the note whenever Bark isn't ready.
- **Claude files it** (optional, with your API key).
  - Tidies what you said, picks the project, the type and the priority, and adds tags.
  - Understands commands: "start a QA session for strado", "wrap up", "open the dashboard".
  - Without a key, Broski's built-in phrase rules do the job.
- **Sessions → reports.** Start a QA, research, meeting or review session. Every screenshot and comment goes into it. "Wrap up" has Claude look at the screenshots and write a full report, with an issues table and steps to reproduce. One click turns the issues into bugs on the board.
- **Dashboard = project management.**
  - Per project: **Board** (Inbox → To do → Doing → Done, drag cards between columns), **List**, **Sessions** (timeline plus rendered report), and **Screenshots** (gallery).
  - **Inspector** for editing title, body, status, type, priority, tags, project and attachments.
  - Search and filters across everything.
- **Send anywhere.** Any note, list, session or report can go to:
  - a Claude or ChatGPT prompt
  - a GitHub issue (the repo is detected from the project's git remote) or a Linear issue
  - Slack (via a webhook) or Notion
  - a PDF with embedded screenshots, or a Markdown file
  - the macOS Share menu
- **Beta-ready.** Onboarding, a Settings window, secrets stored in a private file (not the keychain, so ad-hoc builds never prompt), and a signed DMG with optional notarization.

## Build and run

Needs macOS 13+ and the Xcode Command Line Tools (full Xcode isn't required).

```bash
./scripts/build-app.sh --open
```

Builds `build/Broski.app` with its icon, signs it, and starts it. The ad-hoc signature uses a designated requirement tied to the bundle ID, so microphone, speech, and Documents permissions survive rebuilds.

## Ship a beta

```bash
./scripts/package.sh
```

Runs the self-test, builds, and writes `dist/Broski-<version>.dmg` and `.zip`. Send testers the DMG. It contains [BETA.md](BETA.md) as "Read me first", which covers install, the one-time "Open Anyway" step for unsigned builds, permissions, and feedback.

With an Apple Developer ID, set `BROSKI_SIGN_IDENTITY` (and `BROSKI_NOTARY_PROFILE`, created once with `xcrun notarytool store-credentials`). The script then signs with the hardened runtime, notarizes, and staples, so the app opens like any other download.

## Talking to Broski

| You say (or type) | Goes to |
|---|---|
| "In the trading bot project, add a note: retry failed orders" | `trading-bot` · note |
| "In project strado, add a todo: fix the login bug" | `strado` · todo (checkbox) |
| "Add an idea to marketroom: social proof on the landing page" | `marketroom` · idea |
| "Bug in bugbyte ASO, keyword ranks don't refresh" | `bugbyte-aso` · bug |
| "For Tamer, remind me to email the beta testers" | `Tamer` · todo |
| "In the moonshot project, idea: …" (no such project yet) | new `moonshot` |
| "Note to self: buy a better mic" / no project named | `inbox` |
| "…actually, cancel that" / "never mind" | nothing saved |

Projects are the folders inside your project folders, plus any notes files Broski has already created. Names match loosely: "hip three observatory" finds `hip3-observatory`, a misheard "trading bought" finds `trading-bot`, and "at a todo" is read as "add a todo".

## Where notes go

```
~/Broski/
├── inbox/                              notes without a project
│   └── 2026-10-16-1532-buy-a-better-mic.md
├── projects/strado/
│   ├── 2026-10-16-1530-login-button-overlaps-the-logo.md
│   ├── attachments/                    screenshots and files
│   └── sessions/2026-10-16-1540-login-flow/
│       ├── session.md                  every capture, in order
│       ├── shots/
│       └── report.md                   written on "wrap up"
└── .broski/                            log, trash, pre-0.3 backup
```

Each note is plain markdown with a small header, so it's readable in Obsidian, VS Code, or by Claude Code:

```markdown
---
kind: bug
status: todo
priority: high
tags: ui, safari
created: 2026-10-16T15:30:00+05:30
app: Safari
url: https://staging.example.com/login
attachments: attachments/2026-10-16-153000.png
---
# Login button overlaps the logo on narrow windows
```

Notes from 0.2 (one bullet per line) are converted automatically on first launch. The originals are kept in `.broski/legacy-0.2/`.

Broski's folder also holds what it knows about your projects:

```
projects.json                           every project: real name, code folders, trackers, earlier names
trackers/<id>.broski.json               how to read a tracker (written only when you approve an onboarding draft)
projects/<p>/tracker/                   a tracker Broski keeps, for projects that have none
projects/<p>/onboarding/<run>/          a run's questions, prompts, the threads' answers and CHECK.md
```

## Onboard a project

1. Dashboard › the project › **Tracker** › **Onboard** › **Start a run**. Or from Terminal:
   ```bash
   /Applications/Broski.app/Contents/MacOS/Broski --start-onboarding "My Project"
   ```
2. For each thread, **Copy command** and paste it in Terminal. It forks that thread's newest Claude Code session and asks it its questions. The thread reads only. It writes its answers into the run folder and checks them itself.
3. **Check answers.** Every evidence ref is verified: the file exists and contains the quote, the commit exists and its message contains the quote, the record id exists, the transcript exists, or the glob finds nothing for a claimed gap. Paths outside the repo and secret files are refused.
   ```bash
   /Applications/Broski.app/Contents/MacOS/Broski --check-onboarding "<run folder>"
   ```
4. **Draft manifest**, review it, then **Approve draft**. Broski reads the tracker with it from then on, and keeps the previous one beside it.

A project with no tracker gets **Create a Broski tracker**: plain markdown (`TRACKER.md`, `ship/PLAN.md`, `launch/`, `ops/`, `decisions/`, `items/`, `threads/THREADS.md`) that threads, people and Broski all edit.

## Privacy

- **Mic:** off except while you dictate a note, unless you turn on the wake word.
- **Wake word:** runs only with on-device recognition (`requiresOnDeviceRecognition`). If your language can't do that, it refuses to start rather than streaming your room to a server.
- **What's kept:** nothing is uploaded and there are no analytics. Notes are local markdown files.

## Layout

```
Sources/BroskiCore/     pure logic: wake-word matching, note routing, markdown read/write/edit, config
Sources/Broski/
  AppModel.swift        owns everything; applies settings live; windows and Dock behaviour
  CaptureController     one note at a time: voice + typing, silence detection, saving
  SpeechEngine          mic + Apple Speech; wake and dictation tasks; audio replay after the wake word
  Bubble / FloatingPanel / PanelView     the floating button and the note panel
  NotesLibrary / DashboardView           the dashboard, with FSEvents live reload
  OnboardingView / SettingsView / Permissions (incl. VoiceCheck)
  BroskiArt             the character, drawn in code: app icon, menu-bar glyph, avatar
  Diagnostics / Snapshots                --diagnose and --snapshot developer tools
  Onboard               --start-onboarding, --check-onboarding, --assemble-onboarding, --new-tracker
  Dashboard/TrackerViews                 the Tracker tab, Waiting on you, onboarding, new items
  MCP/MCPServer         Broski --mcp: read-only tools for Claude Code
Sources/BroskiCore/Trackers, TrackerEngine   reading trackers in place: manifests, presets, readers, git snapshots
Sources/BroskiCore/Onboarding, OnboardingCheck, TrackerTemplate   the onboarding kit
Sources/BroskiCore/ChangeStream   what changed in each tracker, read after read
Sources/BroskiBark/     Bark 3.0 on Core ML: audio frontend, encoder, TDT decoder (swift run BarkCheck <model> <audio>)
Sources/BroskiSelfTest/ swift run BroskiSelfTest: checks of parser, matcher, store, brain, trackers, onboarding
```

## Troubleshooting

- **No transcript, or "Turn on Dictation":** go to System Settings › Keyboard › Dictation. Apple's recognizer refuses to run without it.
- **The panel stays empty:** check the input device in System Settings › Sound. An iPhone or Bluetooth mic can win.
- **Event log:** `~/Broski/.broski/broski.log` lists each step of a capture without the words.
- **Check the recognizer without a mic:**
  ```bash
  say -o /tmp/phrase.aiff "Broski. In the strado project, add a todo: test"
  ```
  ```bash
  open -n -W build/Broski.app --args --diagnose /tmp/phrase.aiff /tmp/report.txt
  ```
- **Render every screen with sample data:**
  ```bash
  .build/debug/Broski --snapshot /tmp/broski-shots
  ```
  This draws the dashboard, the panel states, onboarding, and settings, in light and dark.

## Roadmap

- **Low-power wake word.** A [sherpa-onnx keyword spotter](https://github.com/k2-fsa/sherpa-onnx) in front of the recognizer, so the wake word costs almost nothing.
- **Better transcription.** macOS 26 `SpeechAnalyzer`, once built with that SDK, or [FluidAudio](https://github.com/FluidInference/FluidAudio) Parakeet for accuracy.
- **LLM clean-up pass.** Tidy wording, split rambles into several notes, and suggest the project.
- **Claude Code hand-off.** Today the Tracker tab copies a prompt for the thread that owns a record; next, send it straight to that session.
- **Auto-update** (Sparkle) once there's a signed release channel.

## Credits

Speech recognition: [Underdog Bark 3.0](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0) by Conway Research (CC BY 4.0), built on NVIDIA's parakeet-tdt-0.6b-v3 (CC BY 4.0). Whisper via [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT).

## Prior art

OpenClaw's macOS voice wake (MIT) inspired the on-device recognizer, the text-gate design, and restarting the recognizer after each capture. VoiceInk and FluidVoice (GPL) informed the floating-panel UX; I studied them and copied no code.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md): set up with `scripts/install-hooks.sh`, run `scripts/ci.sh` before you push, and write the test first. Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Security

Found a way to make Broski leak, act without asking, or read what it shouldn't? Please report it privately: see [SECURITY.md](SECURITY.md). The checklist for outside reviews is in [docs/SECURITY-REVIEW.md](docs/SECURITY-REVIEW.md).

## License

Apache License 2.0: see [LICENSE](LICENSE). Third-party credits are in [NOTICE](NOTICE).
