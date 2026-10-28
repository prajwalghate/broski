# Privacy

Broski holds your thinking, so it's built to keep it yours: your notes are plain files you own, nothing leaves your device without you, and there are no accounts, analytics or tracking.

## The short version

- Your notes, conversations and memory are files in your Broski folder. No account, no Broski server, no analytics.
- Text goes to a model only through one gateway, which hides keys and tokens first, and only to the provider you chose.
- A local-only project's text goes only to models on your device. With none set up, Broski refuses rather than sending anything.
- Broski never sends audio anywhere itself: Bark and Whisper turn speech into text on your Mac.
- The private vault is encrypted on the device, and nothing in it ever reaches a model, search, memory or Claude Code.
- Nothing is saved as a note, todo, decision or project until you tap Save.

## What goes to a model

Every call to a model goes through Broski's model gateway (`ModelGateway` in `Sources/BroskiCore`). No feature talks to a provider directly. For a reply in the conversation, the model gets:

- Broski's instructions.
- What it knows about you, the project's living page and the project's standing decisions, each fenced as data.
- The recent turns of the conversation that fit, and the notes and older turns it recalled for this reply, numbered so it can cite them.
- Files you shared with this message: images and PDFs as they are (for a model that reads them), text files fenced as data.
- The text of a link you shared, fenced as data.

Before anything is sent, the gateway masks secrets in the text: Anthropic, OpenAI, GitHub, Slack and Google API keys and tokens, AWS access keys, private key blocks, and `.env`-style lines whose name ends in KEY, TOKEN, SECRET, PASSWORD, PASSWD or PWD. Masking covers text, including the text of a PDF sent to a model that can't read PDFs. Images and PDFs sent as files go as they are.

Other jobs send less: filing a quick note sends the note, your project names and what you were looking at (the app, window title and page address); save suggestions send the last few turns; reflection sends only your own words (see below).

Each call is logged in `usage/<month>.<device>.jsonl` with its role, provider, model, project, task and token counts. The log never holds text.

### Text from files, pages and trackers is data

Text that didn't come from you (a page, a file, a tracker record, a commit message) is fenced in the prompt and marked as data. Broski's instructions tell the model never to follow instructions found there, and never to visit or send anything to an address a page mentions. Models get no tools: they can't save, fetch or change anything. Notes, todos, decisions and projects are created only when you tap Save or Create.

### Reflection

When the Mac has been idle for ten minutes (at most every six hours, and only when there's something new), Broski rereads what you said and updates what it knows about you. It reads only your own words: never its own replies, your notes or attachments, a private conversation, or a local-only project. What it reads is fenced as data. What comes back is filtered again: nothing with a link, nothing that reads like an instruction, nothing long. Every change is logged with why, and What Broski knows › Reflection lists them with Undo. Turn reflection off in the same place.

## Local-only projects

Mark a project local only (Settings › Companion › Living pages and privacy) and its text never reaches a cloud model:

- Its conversations, notes, pages, reports, call notes and help requests go only to models on your device: Apple's on-device model, Ollama, LM Studio, or a custom server at a loopback address marked as running on this Mac. [Choosing your AI](models.md) explains which models count.
- With no local model set up, Broski refuses before sending anything.
- A conversation that mentions a local-only project's name stays on the device as a whole.
- Recall leaves local-only projects out of a conversation that isn't local, and save suggestions are never told they exist.
- Ask leaves their notes out, and a question that names a local-only project gets a list of matching notes instead of a model's answer.
- Claude Code (MCP) can't see local-only projects at all.
- Automations can notify you about a local-only project, but never post it to a webhook.
- If `config.json` can't be read (it doesn't parse, or iCloud is still downloading it), every project counts as local only until it can, so nothing slips out meanwhile.

## Private mode

Say "go private" for a blank slate. In private mode Broski doesn't read what it knows about you, your projects, decisions or notes, and recalls nothing. The conversation is kept in memory only: nothing from it is written to disk unless you ask (saying "note: …" still saves that note), files you share aren't copied, "remember that …" is refused, and a save card comes only when you say "save that": it's drawn from the private conversation alone, and nothing is saved unless you tap Save. When you leave, you choose to keep it (it's added to the conversation and its files are copied into the project's resources) or let it go.

Private mode is about what Broski keeps and reads, not where the reply comes from: your messages still go to your everyday model (or the deep one after "think harder"), and "save that" to your fast one. If that's a cloud model, what you say in private mode goes to it, without the rest of your context. For text that must stay on your device, use a local model or a local-only project.

## Links you share

When you paste a link, Broski opens the page on your device before it replies:

- Only `http` and `https`, and never an address with a password in it. Pages behind a login can't be read.
- A page drawn with JavaScript is rendered in a hidden browser that keeps no cookies.
- The readable text only, cut to about 15,000 tokens (and Broski says so). "Read the docs at …" or "go through …" reads up to 10 pages, only in the same section of the same site.
- The text goes with your message once, fenced as data. A copy is kept in the project's resources so recall can find it later (not in private mode).
- Settings › Models › Links turns it off.

## The private vault

The vault (menu bar › Private Vault…, the iPhone's Talk › ⋯ › Private vault, or "vault: …" in the conversation) holds notes only your passphrase opens:

- Each note is its own file, encrypted with AES-256-GCM under a random 256-bit vault key. Titles are encrypted too.
- The vault key is stored only wrapped: once under your passphrase and once under a recovery key, each stretched with PBKDF2-SHA256 at 600,000 rounds. Passphrases need at least 10 characters. The recovery key is 160 random bits, shown once as eight groups of four letters and digits, and never stored.
- Nothing that opens the vault is written to disk. Tampered files fail to decrypt.
- After the first unlock, Touch ID or Face ID can open it. On the iPhone the Keychain item itself requires Face ID. On the Mac the key sits in the login Keychain for Broski, and Broski asks for Touch ID before reading it.
- It locks after 5 minutes idle. On the Mac it also locks when its window closes, the Mac sleeps or the screen locks, and its window is left out of screenshots and screen recordings. A recovery key you copy leaves the clipboard after a minute. On the iPhone it locks when Broski leaves the screen and hides its contents in the app switcher.
- "vault: …" in the conversation goes straight into the vault after you unlock it, and is never sent to a model or kept in the conversation.
- No other part of Broski reads the vault: not search, recall, memory, reflection, Claude Code or any model. iCloud only ever syncs ciphertext.
- Lose both the passphrase and the recovery key and nobody can open it, including you.

## The microphone

- The mic is off except while you talk or dictate a note.
- The wake word keeps the mic on while it's enabled, and runs only with on-device recognition. If your language can't do that, it refuses to start rather than stream your room to a server.
- Broski never sends audio anywhere itself. Bark and Whisper run on your Mac. Apple's recognizer, which draws the live preview, runs on the device whenever your language (or English) supports it; when no on-device recognizer is available, Apple's own speech service is used and the wake word is turned off.
- Call notes record your mic and the call's audio, transcribe them on your Mac, and remind you to tell people you're taking notes. The finished transcript goes to your everyday model for the summary.

## What's stored where

| Where | What |
|---|---|
| Your Broski folder (`~/Broski`, or iCloud Drive › Broski) | Notes, sessions and screenshots; the conversation; memory and decisions; project pages; files and links you shared; trackers Broski keeps; `config.json` (settings, model choices, local-only projects; no keys); the usage log (counts and cost, no text); the vault (encrypted) |
| `<Broski folder>/.broski/` | The event log `broski.log` (steps, versions, devices and errors; never note or conversation text), the trash, and backups of older formats |
| `~/Library/Application Support/Broski/` on the Mac | `secrets.json` (your keys and webhook addresses, readable only by your user), the voice models, and earlier app versions kept by `scripts/install-mac.sh` |
| The Mac's login Keychain | Only the vault's Touch ID key, if you turn that on |
| The iPhone's Keychain | Your keys, and the vault's Face ID key |

The event log never holds what you said, but it does hold file paths, which can include your Mac's user name. Check before you share it.

## What Broski connects to

Broski has no server of its own and sends no analytics or crash reports. It connects only to:

- The model providers you set up, when a feature calls a model.
- Pages you share, when link reading is on.
- Hugging Face, when you download a voice model.
- Webhooks you add (automations, Slack).
- Pages you choose to open: exporting to Claude.ai, ChatGPT, a GitHub or Linear issue opens your browser with the text filled in; "Get a key" links open the provider's site.

Claude Code and other MCP clients run Broski on your Mac; nothing goes over the network.

## Reporting a problem

Found a way to make Broski leak, act without asking, or read what it shouldn't? Report it privately: see [SECURITY.md](../SECURITY.md). The checklist for outside reviews is [SECURITY-REVIEW.md](SECURITY-REVIEW.md).
