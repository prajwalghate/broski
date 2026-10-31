# Broski vs ChatGPT

ChatGPT is OpenAI's assistant. It's a polished app for Mac, Windows, the web, iPhone and Android, and it comes with OpenAI's own models, web search, image generation, live voice and plugins for other apps. Your chats live in your OpenAI account. Broski is a free, open-source app for Mac and iPhone, built for talking through your own projects. It works with whichever AI provider you choose, including models on your Mac, and keeps the conversation, memory and notes as plain files in a folder you own. Pick ChatGPT if you want the strongest all-round assistant with the least setup. Pick Broski if you want your project thinking kept as files you control, your own choice of models, or projects that never leave your Mac.

## At a glance

| | Broski | ChatGPT |
|---|---|---|
| Price | Free and open source. You pay the AI provider you choose, or nothing with a model on your Mac. | A free plan, and paid Go, Plus and Pro plans |
| Account | None | An OpenAI account. Projects and exports need you signed in. |
| Models | Any provider: Claude, OpenAI, Gemini, OpenRouter, Groq, Mistral, DeepSeek, or a model on your Mac. You pick one for each kind of work. | OpenAI's own models |
| Local models | Ollama, LM Studio, Apple's on-device model, or any OpenAI-compatible server | None: every plan lists only OpenAI's hosted models |
| Where your conversations live | Plain files in your Broski folder | Your ChatGPT account, on OpenAI's systems |
| Memory | What it knows about you, each project's decisions, and notes it recalls. You can read every fact and undo any change. | Saved memories and past chats, with a memory summary you can correct. Paid plans get more memory. |
| Projects | Each project is a folder with notes, a living page, decisions and a tracker | Projects group chats, files and instructions, and can be shared with other people |
| Voice | Hold to talk. Bark and Whisper turn speech into text on your Mac. Replies can be read aloud. | Live voice conversations, with daily limits that depend on your plan |
| Saving notes | Offers a save card. Nothing is saved until you tap Save. | Saves memories when you ask, and on its own. You can add a reply to a project's sources. |
| Web search and images | Reads links you paste. No web search or image generation. | Web search and image generation |
| Connectors and MCP | An MCP server, so Claude Code and other MCP clients can read your notes. Broski's own models get no tools. | Plugins for apps like Gmail, Google Drive and Slack. Custom MCP servers at an HTTPS address, with full support on Business and Enterprise plans. |
| Export | Nothing to export: it's already files. A note can also go to a ChatGPT or Claude prompt, a GitHub or Linear issue, a PDF or a Markdown file. | Request an export in Settings › Data controls. A link to a ZIP file arrives by email, which can take up to 7 days. |
| Platforms | Mac (macOS 14 or later, Apple silicon). The iPhone app is built from source for now. | Mac (macOS 14 or later) and Windows apps, the web, iPhone and Android |

## Where ChatGPT is the better choice

- **The models.** You get OpenAI's newest models, tuned for the app, with no keys to set up. Broski uses whatever model you connect, so its answers are only as good as the model you choose.
- **More it can do.** Web search, image generation, deep research and data analysis are built in. Broski reads links you paste, but it doesn't search the web or make images.
- **Voice.** ChatGPT's Live option listens and speaks at the same time, so you can interrupt it. With Broski you hold to talk, your words are turned into text, and the reply follows.
- **Reaching other apps.** Plugins let ChatGPT work with apps like Gmail, Google Drive and Slack. Broski's models get no tools: they can't fetch, change or send anything.
- **Polish and reach.** ChatGPT has App Store apps for iPhone and Android, plus Windows and the web. Broski's iPhone app isn't in the App Store yet: you build it yourself with Xcode, and if you sign it with a free Apple ID it stops opening after 7 days until you install it again. The Mac app isn't notarized by Apple yet either.
- **Working with others.** You can share a ChatGPT project with other people.

## Where Broski is the better choice

- **Your files, not an account.** The conversation, what Broski knows about you, decisions and notes are markdown and JSON files in a folder you pick: `~/Broski`, iCloud Drive, Dropbox or a Git repo. If you uninstall Broski, the files stay where they are, and there's never an export to wait for.
- **No account, no server.** Broski has no sign-up, no server of its own, and no analytics. See [Privacy](../privacy.md).
- **Any model, for each job.** Use a cheap fast model for filing, a strong one for riffs and a local one for private projects, and change providers without losing your history. See [Choosing your AI](../models.md).
- **Projects that stay on your Mac.** Mark a project local only and its text goes only to models on your device. If no local model is set up, Broski refuses rather than sending anything. With a local model and on-device voice, it works offline.
- **Your voice stays on your Mac.** Broski never sends audio anywhere itself. Bark and Whisper turn speech into text on your Mac.
- **It saves only when you tap.** When you decide something or name a todo, Broski offers a card, and nothing is saved until you tap Save. What it learns about you is listed with the reason for each change, and you can undo any of it.
- **Built around your projects.** Each project gets a living page, its tracker is read where it lives, and Ask answers questions across all your projects. Riff mode is for brainstorming. See [Talking to Broski](../talking.md).
- **Your notes in Claude Code.** Broski's MCP server lets Claude Code and other MCP clients read your notes and project pages. See [Claude Code and MCP](../mcp.md).
- **Open source.** Broski is licensed under Apache 2.0, and you can read every line that handles your notes.

## Using both

- **OpenAI's models in Broski.** Choose OpenAI in Settings › Models and paste a key from platform.openai.com. OpenAI bills API use separately from a ChatGPT subscription, so you pay for what Broski sends even if you already pay for ChatGPT. Pro plans can include monthly API credits.
- **Send a note to ChatGPT.** Any note, list, session or report in Broski can go to a ChatGPT prompt: Broski opens your browser with the text filled in.

## Sources

- [ChatGPT plans and pricing](https://chatgpt.com/pricing/)
- [Downloading the ChatGPT macOS app](https://help.openai.com/en/articles/9275200-downloading-the-chatgpt-macos-app)
- [Memory in ChatGPT](https://help.openai.com/en/articles/8590148-memory-in-chatgpt)
- [Projects in ChatGPT](https://help.openai.com/en/articles/10169521-projects-in-chatgpt)
- [ChatGPT Voice](https://help.openai.com/en/articles/20001274-chatgpt-voice)
- [Connecting custom MCP servers in ChatGPT](https://help.openai.com/en/articles/12584461-connecting-custom-mcp-servers-in-chatgpt)
- [Exporting your ChatGPT history and data](https://help.openai.com/en/articles/7260999-exporting-your-chatgpt-history-and-data)
- [Managing billing for ChatGPT and the API platform](https://help.openai.com/en/articles/9039756-managing-billing-for-chatgpt-and-the-api-platform)

Checked 31 October 2026. Products change; tell us if something here is out of date.
