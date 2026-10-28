# Talking to Broski

There are two ways in. **The conversation** (⌥⇧B, or hold fn) is where you think out loud with Broski: it replies, remembers, and offers to save what matters. **Quick notes** (⌥⇧N) skip the reply and file a note straight into a project. Both take voice or typing.

## The conversation

Press ⌥⇧B on the Mac, or open the Talk tab on the iPhone. It's one conversation on both, kept as plain files (`conversations/<month>/<day>.<device>.jsonl`).

- **It remembers.** Broski recalls your notes, older conversation and each project's standing decisions, and says where a fact came from ("on Oct 21 you decided…"). A newer decision replaces an older one instead of mixing with it.
- **It offers, you decide.** When you decide something or name a todo or a bug, a **save card** appears. Nothing is saved until you tap Save; **Not now** dismisses it.
- **Share anything.** Paste or drop screenshots, photos, PDFs and other files anywhere in the window, or take a screenshot with the camera button. They're kept in the project's `resources/` folder and sent with your message.
- **Links are read.** Paste a link and Broski opens the page on your device before it replies (pages drawn by JavaScript in a hidden browser that keeps no cookies), keeps a copy in the project's resources, and sends its text with your message, fenced as data. An average page costs about half a cent on Sonnet. Pages behind a login can't be read. Settings › Models › Links turns it off.
- **Threads.** Broski names the topic of each turn; the thread menu shows one topic at a time, and replies then focus on it.
- **Return sends.** Shift-, Option- or Control-Return adds a line. Up in an empty box brings back your last message. Esc stops listening, then stops a reply, then stops reading aloud. The Send button turns into Stop while Broski replies, and a failed reply gets **Try again**.

### Things you can say

| Say or type | What happens |
|---|---|
| "note: …" | Saves a quick note at once, without a reply |
| "remember that …" | Adds a fact to what Broski knows about you |
| "forget that …", or just "forget that" | Forgets a fact (the last one, when you don't say which) |
| "think harder" | The next replies come from the deep model |
| "save that" | Offers a save card for what was just said |
| "switch to recipe box", "let's talk about recipe box" | Moves the conversation to that project |
| "go private", "leave private" | A blank slate that reads and keeps nothing (see below) |
| "let's riff", "let's riff about …" | Starts riff mode |
| "rule: no code talk" | Adds a rule for every riff |
| "drop the rule about code", "clear my riff rules" | Removes riff rules |
| "wrap up" (while riffing), "end riff" | Ends the riff with one save card |
| "read the docs at …", "go through …" | Reads up to 10 pages of a site, sending lines repeated on every page (menus, footers) once |
| "connect ~/code/recipe-box" | Ties a code folder to the current project, read-only |
| "new pack: game dev" | Drafts a pack of tracker sections and widgets for that kind of project |
| "open my vault" | Opens the private vault |
| "vault: …" | Puts a note straight into the vault; it never reaches a model or the conversation |

Only whole requests count: "should I think harder about pricing?" is a question, not a command.

### New projects by talking

Describe something new you want to build and Broski proposes a project: a name you can edit, packs that fit (web, web3, ai, mobile, personal, or your own), first goals and open questions. **Create project** sets up its folder, a tracker with the packs' sections, a first note, and setup drafts (`CLAUDE.md`, prompts, agents) that Claude Code can apply to a repository later. Repositories are never touched. [Trackers](trackers.md) has more.

### Riff mode

The riff button in the conversation's header, or "let's riff about …", turns the conversation into a brainstorm on the deep model. Broski follows a set of rules: build on your idea first; be proactive; bring real facts, numbers and precedents, saying how sure it is and never inventing them; sketch the 10x version when it fits; flag dark patterns, manipulation and privacy or safety risks, with the honest version; push back when something is weak; back a decision instead of reopening it; keep it short and spoken; end with one question. Then it follows your rules on top.

It pulls in thinking moves when they'd help, used the way a person would ("Quick pre-mortem: …"): first principles, pre-mortem, invert, 10x it, steelman, borrow from another field, Fermi estimate, what must be true, ethics check, simplest version, three directions, and poke holes. Pick one yourself from **Moves** in the riff banner on the Mac, or Thinking moves in the ⋯ menu on the iPhone.

Say "rule: no code talk" mid-riff and it's kept for every riff, on every device ("drop the rule about …" removes one; **Rules** lists them all). There are no save cards while you think. **Wrap up** turns the riff into one card: a summary, up to four ideas, three decisions, four todos and two open questions. A riff survives a restart until you wrap it up.

On the iPhone: Talk › ⋯ › Riff, or "Riff with Broski" from Siri or the Action Button, which opens listening and can read replies aloud.

### Private mode

"Go private" starts a blank slate: Broski doesn't read what it knows about you or your notes, and keeps nothing. When you leave, keep it or let it go. Replies still come from your chosen model; [Privacy](privacy.md) explains exactly what that means.

### It learns, and you can undo it

When the Mac is idle, reflection rereads what you said (never its own replies, files or local-only projects) and updates what it knows about you. Every change is logged with why and can be undone: menu bar › **What Broski knows** shows what it knows about you, every project's decisions, and what reflection changed.

## Quick notes

Press ⌥⇧N, or say "note: …" in the conversation. The note panel opens ready for typing, with the mic off.

- **Talk into it:** hold ⌥⇧N (or the floating head) and let go when you're done, or click the mic and talk as long as you like. Pausing to think doesn't stop it: the speech engine writes out each phrase while you pause, so the text is there the moment you're done.
- **Check, then save:** you see the text and where it's going ("Will save to recipe-box as a todo: “Fix the login bug”"). Edit it, change the project or type with the chips, add screenshots (⌥⇧S), then press ⌘⏎. Return just starts a new line; nothing saves by itself.
- **Esc keeps a draft.** The next note brings it back; **Discard draft** starts fresh.
- **Add more:** after you save, **Add more** puts new text and screenshots under the same note, stamped with the time. It's also in the menu bar as **Add to last note**.
- **Clip what you read:** highlight text in any app and press ⌥⇧C, or right-click › Services › **Add to Broski**. It's quoted with the page or window it came from. Keep pressing ⌥⇧C on more highlights to collect several clips into one note.
- **Context comes along:** each note keeps what you were looking at: the app, the window title, the browser page and any selected text.
- **Noise doesn't become notes:** echo cancellation and noise suppression on the mic when your setup supports it; speech has to stand clear of the room's noise floor; silence is trimmed before Whisper sees it; and segments Whisper rates as non-speech are dropped, along with its known silence phrases ("Thank you.").

With a model, filing tidies what you said, picks the project, the type and the priority, adds tags, and understands commands ("start a QA session for recipe box", "wrap up", "open the dashboard"). Without one, Broski's built-in phrase rules do the job.

### How notes are routed

| You say (or type) | Goes to |
|---|---|
| "In the trail map project, add a note: retry failed uploads" | `trail-map` · note |
| "In project recipe-box, add a todo: fix the login bug" | `recipe-box` · todo (checkbox) |
| "Add an idea to launch-site: social proof on the landing page" | `launch-site` · idea |
| "Bug in recipe box, search doesn't find soups" | `recipe-box` · bug |
| "For launch site, remind me to email the beta testers" | `launch-site` · todo |
| "In the moonshot project, idea: …" (no such project yet) | new `moonshot` |
| "Note to self: buy a better mic", or no project named | `inbox` |
| "…actually, cancel that", "never mind" | nothing saved |

Projects are the folders inside your project folders, plus the projects already in your Broski folder. Names match loosely: "home server two" finds `home-server-2`, a misheard "lunch site" finds `launch-site`, and "at a todo" is read as "add a todo". When dictation keeps mishearing a made-up name, pick the project chip in the panel.

### Sessions and reports

Say "start a QA session for recipe box" (or a research, meeting or review session). Every screenshot and comment goes into it. "Wrap up" has the model look at the screenshots and write a full report, with an issues table and steps to reproduce. One click turns the issues into bugs on the board.

## Ask, help and the companion

- **Ask Broski** (⌥⇧A): ask anything about your notes and trackers, typed or spoken, and get an answer that cites its sources. "What's waiting on me", "what changed this week" and "what did we decide about X" work across projects.
- **Help with this** (⌥⇧H): Broski looks at the window you're in, alongside the project's memory, and helps: it explains an error or reviews a screen you're testing.
- **Call notes:** your mic and the call's audio, transcribed on your Mac as "Me" and "Them", then summarized with decisions and action items.
- **The pill:** a small bar at the top of the screen with Ask, Help with this, Riff, call notes and the check-in. It never takes focus. Off by default; the menu bar turns it on.
- **Nudges:** when you come back to a project with open work, or an idea has sat for weeks. Pick how often in Settings › Companion (Quiet, the default, means never on its own; Daily; Active). Every nudge has Useful, Not now and Never.
- **Morning check-in:** off until you turn it on, at a time you choose, covering what you choose.
- **Related notes** show while you write, and a near-duplicate offers "add to it instead".
- **Automations** (Settings › Connections): when a project changes in a way you name, a notification, a webhook post, or both.

## Where notes go

```
~/Broski/
├── inbox/                              notes without a project
│   └── 2026-10-16-1532-buy-a-better-mic.md
├── projects/recipe-box/
│   ├── 2026-10-16-1530-login-button-overlaps-the-logo.md
│   ├── PROJECT.md                      the project's living page
│   ├── attachments/                    screenshots and files from notes
│   ├── resources/                      what you shared in the conversation
│   └── sessions/2026-10-16-1540-login-flow/
│       ├── session.md                  every capture, in order
│       ├── shots/
│       └── report.md                   written on "wrap up"
├── conversations/                      the conversation, one file per device per day
├── memory/                             what Broski knows about you
└── .broski/                            the event log, the trash, older-format backups
```

Each note is plain markdown with a small header, so it reads well in Obsidian, VS Code, or Claude Code:

```markdown
---
kind: bug
status: todo
priority: high
tags: ui, safari
created: 2026-10-16T15:30:00+05:30
updated: 2026-10-16T15:30:00+05:30
app: Safari
url: https://staging.example.com/login
attachments: attachments/2026-10-16-153000.png
---
# Login button overlaps the logo on narrow windows
```

Front-matter lines another editor adds are kept as they are when Broski saves the note. Notes from 0.2 (one bullet per line) are converted automatically on first launch; the originals are kept in `.broski/legacy-0.2/`.

Each project gets a living page (`PROJECT.md`, the Overview tab in the dashboard): where it stands, open bugs, todos, ideas, decisions and open questions, every line linking to the notes it came from. With a model it's rewritten a while after notes change (at most every six hours, or once a day when only the tracker moved; Refresh rewrites it at once), and it suggests one-click actions: file an issue, mark done, merge duplicates, or hand a task to Claude Code. Without a model, Broski's rules keep it current.

## The dashboard

Menu bar › **Open dashboard**. Per project: **Overview** (the living page), **Command center**, **Tracker**, **Board** (Inbox, To do, Doing, Done; drag cards between columns), **List**, **Sessions** (a timeline plus the rendered report) and **Screenshots**. The inspector edits the title, body, status, type, priority, tags, project and attachments. Search and filters work across everything, and deleting has undo.

Any note, list, session or report can go to a Claude or ChatGPT prompt, a GitHub issue (the repository comes from the project's git remote) or a Linear issue, Slack (through a webhook) or Notion, a PDF with its screenshots, a Markdown file, or the macOS Share menu.
