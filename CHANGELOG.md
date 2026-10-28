# Changelog

All notable changes to Broski are in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The Mac app and the iPhone app have their own version numbers; each entry names the ones that changed. The iPhone stayed at 0.6.0 while Mac 0.9.1 to 0.9.6 shipped, so iPhone changes in those releases are listed under the Mac version.

## Mac 0.11.1 - 2026-10-28

### Security

- The Whisper voice model downloads from one pinned version on Hugging Face and is checked against its size and SHA-256 before it's used. A download that doesn't match is deleted, and Broski says so. A model already on your Mac counts as downloaded only at the expected size.

## Mac 0.11.0, iPhone 0.7.0 - 2026-10-28

### Added

- Any model for every feature. Every feature asks for a role (fast, everyday or deep), and Settings › Models maps each role to a provider. Presets for Claude, OpenAI, Google Gemini, OpenRouter, Groq, Mistral, DeepSeek, Ollama, LM Studio, Apple's on-device model, and any OpenAI-compatible server.
- The first-run setup asks you to choose a provider: paste a key (with a Get a key link) or pick a local model. Broski tests it, reads the provider's own list of models and picks one per role, which you can change.
- The iPhone uses the model choices from the Broski folder's `config.json` and asks for keys for the providers in use. Each device keeps its own keys: the Mac in `~/Library/Application Support/Broski/secrets.json`, the iPhone in its Keychain.
- A harness for working on Broski: `AGENTS.md` for any coding agent, Claude Code hooks, skills and a reviewer agent, `scripts/test.sh` with a recorded green run, a pre-commit hook that refuses untested code, `scripts/install-mac.sh` (a safe install that checks the new build reads your Broski folder and rolls back by itself) and `scripts/rollback-mac.sh`.
- Guides in `docs/`, this changelog, a support page, issue forms, and a website in `site/` published to GitHub Pages. Tagged releases get a zip of the app with its SHA-256 checksum.

### Changed

- Filing, session reports, Help with this, call notes, project pages, Ask and riffs all go through the model gateway by role; the Claude-only client is gone. Errors name the provider and say what to do in Settings › Models. Providers that can't hold a reply to a JSON shape get it in their instructions.
- Local-only projects use only models on the device (Ollama, LM Studio, Apple, or a custom server on a loopback address marked as on this Mac); with none set up, Broski refuses rather than sending anything.
- Spending: Claude calls are priced in Settings › Models › Spending; other providers' calls are counted (tokens and calls) but not priced.
- Supported systems: macOS 14 Sonoma or later on Apple silicon, checked in CI on clean macOS 14, 15 and 26 runners; iPhone with iOS 17 or later. Provider keys now live in Settings › Models, and connecting Claude Code moved to Settings › Connections.

## Mac 0.10.2, iPhone 0.6.7 - 2026-10-27

### Fixed

- The message box: Return sends, Shift-, Option- or Control-Return adds a line, Up brings back your last message, pasting or dropping a file attaches it, and the draft survives a quit.
- The conversation opens at the latest message, follows new replies only while you're at the bottom, and failed replies get Try again. Replies render headings, quotes, lists and code.
- The mic with a Bluetooth speaker connected: when Apple's voice processing can't start, the plain-mic fallback gets a fresh audio engine instead of a broken one.
- `--chat-check` drives the real chat views off screen, and CI runs it.

## Mac 0.10.1, iPhone 0.6.6 - 2026-10-27

### Fixed

- The mic heard nothing during a stream with a three-channel input; Broski now mixes the channels that carry sound.

### Added

- Choose the mic (next to the mic button, and in Settings › Voice), a level meter while listening, and Cancel.
- When nothing was heard, Broski says why and names the mic.
- Send turns into Stop while Broski replies; Stop speaking, and a voice and speed for reading replies aloud.

## Mac 0.10.0, iPhone 0.6.5 - 2026-10-27

### Changed

- Riff replies are short and spoken: under about 120 words, plain sentences, no headings or bullets.
- Riffs end with one question, not two, and back a decision you've made instead of reopening it.

## iPhone 0.6.4 - 2026-10-27

### Fixed

- Talk's typing box and mic always work, even without a key. Commands need no model, and a message for a reply waits with a line saying to add a key.

## Mac 0.9.9, iPhone 0.6.3 - 2026-10-27

### Changed

- Broski always replies in English, even when you talk in another language or a mix, and doesn't comment on it.
- Thinking moves are used the way a person would, never announced.

### Added

- A riff quality test (`--eval-riff`) that runs riff cases through the app's own path and judges them blind.

## Mac 0.9.8, iPhone 0.6.2 - 2026-10-26

### Changed

- Every model call is logged with its task, and Settings › Models › Spending shows this month by task.
- Project pages are rewritten at most every six hours when notes change, and once a day when only the tracker moved.
- Long conversations are cached between turns, and session reports run on Sonnet instead of Opus.

## Mac 0.9.7, iPhone 0.6.1 - 2026-10-26

### Added

- Talk on both devices at once: the conversation refreshes live on the Mac and the iPhone, and turns from the other device say so.

## Mac 0.9.6 - 2026-10-26

### Added

- The private vault, on the Mac and the iPhone: notes encrypted on the device that only your passphrase or recovery key opens, with Touch ID or Face ID after the first unlock.

## Mac 0.9.5 - 2026-10-26

### Changed

- Riffs are proactive, bring real facts and precedents without inventing them, sketch the 10x version, and flag dark patterns and risks.

### Added

- Twelve thinking moves to pull into a riff, from first principles to poke holes.

## Mac 0.9.4 - 2026-10-26

### Added

- Riff mode inside the conversation, on the Mac and the iPhone, with rules you set by saying them ("rule: no code talk"), kept for every riff.
- Wrap up turns a riff into one save card.

## Mac 0.9.3 - 2026-10-25

### Added

- Broski reads the links you share, on the Mac and the iPhone, on the device and fenced as data. "Read the docs at …" reads up to 10 pages of a site.

## Mac 0.9.2 - 2026-10-25

### Added

- Drop files, images and links anywhere in the conversation window.

## Mac 0.9.1 - 2026-10-25

### Fixed

- A screenshot started from a Broski window hides Broski's windows while you pick.
- Every icon-only button says what it does: a tooltip on the Mac, a spoken label on the iPhone.

## Mac 0.9.0, iPhone 0.6.0 - 2026-10-25

### Added

- The iPhone gets the conversation: a Talk tab on the same files as the Mac.
- Settings › Models: a model per role, local servers, Apple's on-device model, and spending with a daily limit.
- Reflection: when the Mac is idle, Broski learns from what you said, with every change logged and undoable.
- Automations, a first conversation that gets to know you, packs you author ("new pack: game dev"), and a command center per project.

## Mac 0.8.2 - 2026-10-24

### Added

- Attach files, screenshots and drops in the conversation; they're kept in the project's resources.
- New projects from a conversation, with packs, first goals and open questions.
- "connect ~/code/…" ties a code folder to a project, read-only.

## Mac 0.8.1 - 2026-10-24

### Added

- Recall: your notes, standing decisions and older conversation, cited in replies.
- Decisions kept with their dates, a newer one replacing an older one.
- What Broski knows, threads in the conversation, and MCP tools for conversations, decisions and memory.

## Mac 0.8.0 - 2026-10-24

### Added

- The conversation is the front door: ⌥⇧B opens it, holding fn talks into it, and ⌥⇧N keeps quick notes one key away.
- Save cards, plain-language commands ("note: …", "go private", "think harder", "remember that …"), and memory of what you tell it.
- The model layer: roles, a router that keeps local-only work on the device, connectors for Claude, OpenAI-compatible servers and Apple's on-device model, secret masking and a usage log.

## Mac 0.7.2, iPhone 0.5.0 - 2026-10-24

### Added

- The first commit in this repository: the Apache 2.0 license, a contributing guide, a code of conduct, a security policy and an outside-review checklist.
- A secret scan before every commit, a Swift Testing target, `scripts/ci.sh` and a GitHub Actions workflow.
