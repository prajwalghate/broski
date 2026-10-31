# Broski vs Obsidian

Obsidian is a free note-taking app for Mac, Windows, Linux, iPhone and Android. It keeps your notes as markdown files on your device and has thousands of community plugins. AI comes from those plugins: Copilot, with about 3.1 million downloads, adds chat and AI agents, and Smart Connections, with 1.2 million, finds related notes. Broski isn't an editor. It's a companion you talk to about your projects: it replies, remembers what you've decided, and saves notes and todos as markdown files only when you tap Save. Pick Obsidian if you want to write and link your notes yourself, on any platform, with AI as an add-on you put together. Pick Broski if you mostly want to think out loud about your projects, by voice or typing, and have what matters filed for you. Broski's notes are markdown, so Obsidian can open them too.

## At a glance

| | Broski | Obsidian with AI plugins |
|---|---|---|
| Price | Free and open source. You pay the AI provider you choose, or nothing with a model on your Mac. | Obsidian is free. Sync is $4 a month billed yearly ($5 monthly), Publish $8 a month billed yearly ($10 monthly). Copilot is free with your own key or a local model; Copilot Plus is $14.99 a month. Smart Connections is free, with paid Pro features. |
| Account | None | None for Obsidian itself. Sync and Publish need an account. |
| What it is | A companion you talk to. Notes come out of the conversation. | A markdown editor for notes you write and link yourself |
| Where your notes live | Markdown and JSON files in your Broski folder | Markdown files in your vault, on your device |
| Models | Any provider: Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek, or a model on your Mac. You pick one for each kind of work. | Copilot: your own key for a cloud, local or OpenAI-compatible provider, Copilot's hosted models (paid), or Claude Code, Codex and OpenCode as agents |
| Local models | Ollama, LM Studio, Apple's on-device model, or any OpenAI-compatible server | Copilot works with Ollama and LM Studio. Smart Connections makes its index on your device by default. |
| Conversation | One conversation across your projects and devices, with memory, recall and sources | Copilot's Agent and Quick Chat. Copilot projects keep their own instructions and chat history. |
| Memory | What it knows about you and each project's decisions. You can read every fact and undo any change. | Not stated |
| Voice | Hold to talk. Bark and Whisper turn speech into text on your Mac. Replies can be read aloud. | The built-in Audio recorder saves a recording into a note. Its help page doesn't mention transcription. |
| Saving notes | Offers a save card. Nothing is saved until you tap Save. | You write notes yourself. Copilot's Agent can create files in your vault, with permissions you set. |
| MCP | Includes an MCP server, so Claude Code and other MCP clients can read your notes | Not stated |
| Mobile | The iPhone app, built from source for now, carries the same conversation | iPhone and Android apps. Copilot's Quick Chat, Commands and Quick Ask work on mobile; its Agent is desktop only. Smart Connections works on mobile. |
| Platforms | Mac (macOS 14 or later, Apple silicon) and iPhone | Mac, Windows, Linux, iPhone and Android |

## Where Obsidian is the better choice

- **Writing and organising.** Obsidian is built for writing, linking and arranging notes yourself. Broski's dashboard lets you edit a note's title, body and tags, but it isn't a full editor.
- **Plugins.** Thousands of community plugins, such as Calendar, Kanban, Dataview and Tasks, let you shape Obsidian around how you work. Broski has no plugin system.
- **Every platform.** Obsidian runs on Windows, Linux and Android as well as Mac and iPhone, with apps in the App Store and Google Play. Broski is Mac and iPhone only, and its iPhone app you build yourself with Xcode. If you sign it with a free Apple ID, it stops opening after 7 days until you install it again.
- **Sync and publishing.** Obsidian Sync offers end-to-end encryption, version history and shared vaults, and Publish puts notes on the web. Broski syncs through a folder you choose, such as iCloud Drive, and doesn't publish.
- **AI agents in your notes.** Copilot can run Claude Code, Codex or OpenCode on your vault, using tools and creating files with your permission. Broski's models get no tools: they can't save, fetch or change anything themselves.
- **Related notes.** Smart Connections finds related notes and searches by meaning with a model on your device, with no API key needed.

## Where Broski is the better choice

- **Talking, not typing.** Press a shortcut or hold fn in any app and talk. Bark and Whisper turn speech into text on your Mac, and Broski replies. See [Talking to Broski](../talking.md).
- **It remembers.** Broski recalls your notes, older conversations and each project's decisions, and says where a fact came from. A newer decision replaces an older one. What it learns about you is listed with the reason for each change, and you can undo any of it.
- **Notes come out of the conversation.** When you decide something or name a todo or a bug, Broski offers a save card and files it into the right project, but only when you tap Save.
- **Privacy rules built in, not assembled.** Every request goes through one gateway that masks keys and tokens first. Mark a project local only and its text goes only to models on your device, and Broski refuses rather than sending it anywhere else. With plugins, each one sends what it sends to the service you set it up with. See [Privacy](../privacy.md).
- **Built around projects.** Each project gets a living page, its tracker is read where it lives, Ask answers questions across all your projects, and riff mode is for brainstorming.
- **Your notes in Claude Code.** Broski's MCP server lets Claude Code and other MCP clients read your notes, project pages and decisions. See [Claude Code and MCP](../mcp.md).
- **A private vault.** Notes encrypted on your device, which no model, search or memory ever reads.

## Using both

- **Obsidian can open Broski's notes.** Each note is a markdown file with a small header, so you can open your Broski folder as an Obsidian vault, read the notes there and link them. Header lines another editor adds are kept when Broski saves the note.
- **Broski's privacy rules stay in Broski.** An AI plugin in Obsidian reads the folder as it is: notes from a local-only project go wherever that plugin sends them. Leave those notes out of plugins that use a cloud model.
- **Plugins add their own files.** Some plugins keep data in the vault; Smart Connections, for example, keeps its index in a `.smart-env/` folder. Open your Broski folder as a vault and that folder lands in it, and syncs with it.
- **Broski can use the same models.** If you run Ollama or LM Studio for Copilot, Broski can use the same local server. See [Choosing your AI](../models.md).

## Sources

- [Obsidian](https://obsidian.md/)
- [Obsidian pricing](https://obsidian.md/pricing)
- [Obsidian download](https://obsidian.md/download)
- [Obsidian Help: Audio recorder](https://obsidian.md/help/plugins/audio-recorder)
- [Copilot in Obsidian's community plugins](https://community.obsidian.md/plugins/copilot)
- [Copilot for Obsidian on GitHub](https://github.com/logancyang/obsidian-copilot)
- [Copilot for Obsidian: LLM providers](https://github.com/logancyang/obsidian-copilot/blob/master/docs/llm-providers.md)
- [Copilot for Obsidian pricing](https://www.obsidiancopilot.com/en/pricing)
- [Smart Connections in Obsidian's community plugins](https://community.obsidian.md/plugins/smart-connections)
- [Smart Connections on GitHub](https://github.com/brianpetro/obsidian-smart-connections)

Checked 31 October 2026. Products change; tell us if something here is out of date.
