# Broski beta

Broski is a companion you talk to about your projects, on the Mac and the iPhone. Press **⌥⇧B** and talk or type: it remembers what you've told it, thinks with you, and offers to save the decisions and todos that come up. Quick notes are still one key away (**⌥⇧N**).

## Install

1. Open the DMG and drag **Broski** into **Applications**.
2. Open Broski from Applications.
3. If macOS says it can't check Broski for malicious software, the beta isn't signed with an Apple Developer ID yet:
   - **macOS 15 or later:** open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Broski.
   - **macOS 14 or earlier:** right-click Broski in Applications and choose **Open**.

   You only have to do this once.

Broski needs macOS 14 Sonoma or later on a Mac with Apple silicon.

## First run

Your first conversation opens with Broski asking what to call you, what you're working on and how you like answers; after your third answer it remembers what you said (you can see and undo it under **What Broski knows**). With no model yet, a card offers **Choose a model…**: a cloud model with your own key (Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek), a model on your Mac (Ollama, LM Studio), or Apple's on-device model.

A short welcome also walks you through setup:

- **How to call Broski:** the menu bar icon, the keyboard shortcut, holding fn, and an optional wake word. (The floating head and the pill are off; the menu bar menu turns them on.)
- **Voice:** allow the microphone and speech recognition, then use **Test my voice**. Voice is optional; you can type every note instead.
  - For the best local transcription, download **Bark** (English, about 200 MB) or **Whisper** (every language, about 570 MB) in Settings › Voice. Bark prepares itself for your Mac once after the download, which takes a few minutes; Broski uses Whisper or Apple's dictation meanwhile.
  - **Dictation must be on** (System Settings › Keyboard › Dictation). Apple's speech recognition won't run without it, even fully on-device.
- **Project folders:** pick the folder where your projects live, like `~/Developer`. Each subfolder becomes a project you can name.

## Using it

- **Talk to Broski:** press **⌥⇧B**, or hold **fn** and talk. It remembers your projects, and when you decide something or name a task it offers a card: tap **Save** to file it, or **Not now**. Say "go private" for a conversation that keeps nothing, and "think harder" for the deep model.
- **What Broski knows:** the menu bar › **What Broski knows**: about you, every project's decisions, and what reflection changed (each with **Undo**).
- **New project:** describe it in the conversation; Broski proposes one with packs that fit. **Create project** sets up its folder, tracker and setup drafts. "connect ~/code/x" ties a repo to the current project; "new pack: game dev" drafts your own pack.
- **Private vault:** menu bar › **Private Vault…** (or say "open my vault"; "vault: …" puts a note straight in without it ever reaching a model). Pick a passphrase, save the recovery key it shows you once, and use Touch ID after that. It locks itself after 5 minutes.
- **Riff:** click the riff button in the conversation's header (or say "let's riff about …") to brainstorm. Say "rule: …" to add a rule Broski keeps for every riff; **Rules** shows them all. **Wrap up** turns the riff into one card to save.
- **Links:** paste a link and Broski reads the page before it replies (a line in the conversation says what it read, with **Open copy**). Say "read the docs at …" or "go through …" for up to 10 pages of a site. Turn it off in Settings › Models › Links.
- **Models and spending:** Settings › **Models**: a model per role, local servers, Apple's on-device model, today's and this month's spend, a daily limit.
- **Automations:** Settings › Connections › **Automations**: a notification or a webhook post when a project changes the way you name.
- **Start a note:** press **⌥⇧N**, or type "note: …" in the conversation. The note opens ready for typing, and the mic stays off. (Prefer the old way? Menu bar › uncheck **Shortcut opens the conversation**, and ⌥⇧B opens notes again.)
- **Hold fn to talk** (Settings › General): hold the fn (🌐) key anywhere, talk, let go. It needs Accessibility. If the emoji picker or Dictation opens when you let go, set System Settings › Keyboard › "Press 🌐 key to" to Do Nothing.
- **Talk into a note:** hold **⌥⇧N** or the Broski head and let go when you're done, or click 🎙 and talk as long as you need. Pausing to think doesn't stop it; click **Done talking** or press ⌘⏎ when you're finished.
- **Check, then save:** you see the text and where it's going. Edit it, add screenshots (**⌥⇧S**), then press ⌘⏎. Return just starts a new line; nothing saves by itself.
- **Esc keeps a draft.** Open a new note and it's back; **Discard draft** starts fresh.
- **Clip text:** highlight something in any app and press **⌥⇧C** (or right-click › Services › Add to Broski). Press it on more highlights to collect them into one note. Some apps need Accessibility access for ⌥⇧C; Services works without it.
- **Project pages:** in the dashboard, each project's **Overview** is a living page written from your notes. Claude keeps it up to date if you've added a key. Click a citation to open the note; the Suggested cards act in one click.
- **Ask Broski:** **⌥⇧A**, or the magnifier in the pill at the top of the screen. Answers come with sources.
- **Companion:** the pill at the top holds Ask, **Help with this** (**⌥⇧H**, which looks at your screen), **Riff**, **call notes** and the **check-in**. Nudges are off by default ("Quiet"); turn them up in Settings › Companion. The morning check-in is there too, off until you turn it on.
- **Trackers:** each project's **Tracker** tab shows its own tracker (ship, launch, ops, decisions, threads, open items), read in place. Broski never writes to a project's tracker. Live state, like which launch steps are ready, comes from the tracker's own board, with the time it was read.
- **Onboard a project:** Tracker › **Onboard** asks the project's Claude Code threads where everything lives. Every answer has to cite a real file, commit, record or transcript, and Broski checks each one. A project with no tracker gets one Broski keeps, with **New** and status buttons.
- **Claude Code:** Settings › Connections › **Connect**, then ask Claude Code "what's open in my Broski notes for this project?" or "what's waiting on me across my projects?"
- **Add more:** after you save, **Add more** carries on the same note. It's also in the menu as **Add to last note**.
- **Name the project in the sentence:**
  - "In the strado project, add a todo: rotate the API keys"
  - "Idea for marketroom: social proof on the landing page"
  - "Bug in trading bot, fills are double counted"
  - Anything without a project goes to the **Inbox**.
- **Or pick by hand:** use the project and type chips in the panel.
- **Dashboard:** the menu bar icon › **Open dashboard**. Browse every project, tick todos off, edit (double-click), move notes between projects, delete (with undo), search, and copy a project's notes as a prompt for Claude.

## Privacy

- **On-device:** speech recognition runs on your Mac when your language supports it. Broski never sends audio anywhere itself.
- **Mic:** on only while you're taking a note, unless you turn on the wake word.
- **Your notes:** plain markdown files in `~/Broski`. No account, no cloud, no analytics.

## Feedback

Go to **Settings › About › Copy diagnostics** and paste the result into your message. It includes your version, settings, and recent events, but nothing you said.

## Known rough edges

- **Mishearings:** recognition is Apple's dictation model. It mishears made-up project names sometimes; picking the project chip fixes that.
- **Bluetooth headsets:** if one is your input, macOS may switch it to low-quality "call" audio while Broski listens.
- **Wake word mode** keeps the mic on and uses noticeably more battery.

## Uninstall

1. Quit Broski from its menu.
2. Delete it from Applications.
3. Delete `~/Broski` too if you don't want your notes anymore.
