# Broski vs the Claude app

The Claude desktop app is Anthropic's own app for Mac, Windows and Linux (beta). It gives you Claude's models with projects, memory, voice mode, web search, connectors, and local MCP servers installed as desktop extensions, and your chats live in your Claude account. Broski is a free, open-source app for Mac and iPhone, built for talking through your own projects. It works with any provider, Claude included, and keeps the conversation, memory and notes as plain files in a folder you own. Pick Claude if you want Anthropic's newest models, Claude Code in the same subscription, and a polished app with no keys to manage. Pick Broski if you want your project thinking kept as files you control, a choice of providers, or projects that never leave your Mac. The two also work together: Claude Desktop can read your Broski notes through Broski's MCP server.

## At a glance

| | Broski | Claude desktop app |
|---|---|---|
| Price | Free and open source. You pay the AI provider you choose, or nothing with a model on your Mac. | Free, Pro ($20 a month, or $17 a month billed yearly), Max ($100 a month) and Ultra ($200 a month), before tax |
| Account | None | A Claude account: you sign in after installing |
| Models | Any provider: Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek, or a model on your Mac. You pick one for each kind of work. | Anthropic's Claude models: Haiku and Sonnet on every plan, Opus on paid plans, and Fable through usage credits on Pro or as part of Max and Ultra |
| Local models | Ollama, LM Studio, Apple's on-device model, or any OpenAI-compatible server | None: every plan lists only Claude models |
| Where your data lives | Plain files in your Broski folder | Your Claude account |
| Projects | Each project is a folder with notes, a living page, decisions and a tracker | Projects, up to 5 on the free plan. Each project has its own memory. |
| Memory | What it knows about you, each project's decisions, and notes it recalls. You can read every fact and undo any change. | Memory from your chats, on by default for individual plans. Searching past chats needs a paid plan. |
| Voice | Hold to talk. Bark and Whisper turn speech into text on your Mac. Replies can be read aloud. | Voice mode (beta) on every plan, hands-free or push-to-talk. It counts toward your usage limits. |
| Saving notes | Offers a save card. Nothing is saved until you tap Save. | Saves memory on its own as you chat, or when you say "remember this" |
| MCP | Includes an MCP server that Claude Desktop and Claude Code can connect to | Runs local MCP servers as desktop extensions, from a directory or a `.mcpb` file, plus connectors |
| Web search | Reads links you paste. No web search. | Web search on every plan, Research on paid plans |
| Export | Nothing to export: it's already files | Settings › Privacy › Export data, on the web or the desktop app. A download link arrives by email. |
| Platforms | Mac (macOS 14 or later, Apple silicon). The iPhone app is built from source for now. | macOS 13 or later, Windows, Linux (beta), the web, iPhone and Android |

## Where Claude is the better choice

- **Anthropic's newest models.** Claude Desktop has every Claude model your plan includes, Fable among them, with no keys to set up. Broski can use Claude models too, through Anthropic's API with your own key, billed per use.
- **One subscription for more.** Paid plans add Claude Code, Claude Cowork and Claude in Chrome, and Claude Code draws on the same usage limits as your chats. You know the monthly price up front. With Broski you pay a provider per use.
- **Voice mode.** Claude's voice mode is a spoken conversation: in hands-free mode it replies when you pause, and it can use your connected tools during the call. With Broski you hold to talk, your words are turned into text, and the reply follows.
- **Tools and connectors.** Claude can search the web, run code, create files and artifacts, and use connectors and desktop extensions to reach other apps. Broski's models get no tools: they can't fetch, change or send anything.
- **Polish and reach.** Claude runs on Mac, Windows, Linux, the web, iPhone and Android. Broski's iPhone app isn't in the App Store yet: you build it yourself with Xcode, and if you sign it with a free Apple ID it stops opening after 7 days until you install it again. The Mac app isn't notarized by Apple yet either.

## Where Broski is the better choice

- **Your files, not an account.** The conversation, what Broski knows about you, decisions and notes are markdown and JSON files in a folder you pick: `~/Broski`, iCloud Drive, Dropbox or a Git repo. If you uninstall Broski, the files stay where they are, and there's never an export to wait for.
- **No account, no server.** Broski has no sign-up, no server of its own, and no analytics. See [Privacy](../privacy.md).
- **Not tied to one company.** Use Claude for riffs, a cheaper model for filing and a local one for private projects, and switch providers whenever you like. See [Choosing your AI](../models.md).
- **Projects that stay on your Mac.** Mark a project local only and its text goes only to models on your device. If no local model is set up, Broski refuses rather than sending anything. With a local model and on-device voice, it works offline.
- **Your voice stays on your Mac.** Broski never sends audio anywhere itself. Bark and Whisper turn speech into text on your Mac.
- **It saves only when you tap.** When you decide something or name a todo, Broski offers a card, and nothing is saved until you tap Save. What it learns about you is listed with the reason for each change, and you can undo any of it.
- **Built around your projects.** Each project gets a living page, its tracker is read where it lives, and Ask answers questions across all your projects. Riff mode is for brainstorming. See [Talking to Broski](../talking.md).
- **A private vault.** Notes encrypted on your device, which no model, search or memory ever reads.
- **Open source.** Broski is licensed under Apache 2.0, and you can read every line that handles your notes.

## Using both

- **Claude Desktop can read your Broski notes.** In Broski, Settings › Connections › **Copy config** copies the server entry. Paste it under `mcpServers` in `claude_desktop_config.json`. Claude can then search your notes, project pages, decisions and trackers. The server is read-only, except that it can add items to, or change an item's status in, a tracker Broski keeps. It hides local-only projects and never reads the private vault. See [Claude Code and MCP](../mcp.md).
- **Claude's models in Broski.** Choose Claude in Settings › Models and paste a key from platform.claude.com. Anthropic bills API use separately from a Claude plan, though Max and Ultra include monthly API credits. Broski shows what you spend on Claude by model and task, and you can set a daily limit.
- **Send a note to Claude.** Any note, list, session or report in Broski can go to a Claude prompt: Broski opens Claude.ai in your browser with the text filled in.

## Sources

- [Claude plans and pricing](https://claude.com/pricing)
- [Install Claude Desktop](https://support.claude.com/en/articles/10065433-install-claude-desktop)
- [Use Claude's chat search and memory to build on previous context](https://support.claude.com/en/articles/11817273-use-claude-s-chat-search-and-memory-to-build-on-previous-context)
- [Use voice mode](https://support.claude.com/en/articles/11101966-use-voice-mode)
- [Getting started with local MCP servers on Claude Desktop](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)
- [Export your Claude data](https://support.claude.com/en/articles/9450526-export-your-claude-data)
- [Why is Claude API usage billed separately from my paid Claude plan?](https://support.claude.com/en/articles/9876003-why-is-claude-api-usage-billed-separately-from-my-paid-claude-plan)

Checked 31 October 2026. Products change; tell us if something here is out of date.
