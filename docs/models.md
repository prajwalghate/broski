# Choosing your AI

Broski isn't tied to one AI company. Every feature asks for a kind of model (a role), and you decide which provider and model fills each role. You can mix them: a cheap fast model for filing, a strong one for riffs, a model on your Mac for private projects.

## Roles

| Role | What it does |
|---|---|
| Fast | Filing quick notes, titles, save cards |
| Everyday | The conversation, Ask, project pages, session reports, call notes, help with a screenshot |
| Deep | "Think harder", riffs, reflection, setting up a project, drafting a pack |

Settings › Models maps each role to a provider and one of its models. Change them whenever you like.

## Setting one up

The first-run welcome asks you to choose a provider, and Settings › Models lets you add more:

1. Pick a provider.
2. For a cloud provider, paste a key. Each one has a **Get a key** link to the provider's own key page.
3. Broski reads the provider's own list of models and sends one tiny test request, so a wrong key or a stopped server shows up straight away.
4. It picks a model for each role: the one the preset suggests when the provider still offers it, otherwise one whose name fits the role (a "mini", "lite" or "haiku" model for fast work, a "pro", "large" or "opus" model for deep work). You can change each choice.

## The presets

| Provider | What you need | Where it runs | Reads images | Cost |
|---|---|---|---|---|
| Claude (Anthropic) | A key from [platform.claude.com](https://platform.claude.com/settings/keys) | Cloud | Yes, and PDFs | Pay as you go. Haiku costs the least, Opus the most. |
| OpenAI | A key from [platform.openai.com](https://platform.openai.com/api-keys) | Cloud | Yes | Pay as you go |
| Google Gemini | A key from [Google AI Studio](https://aistudio.google.com/apikey) | Cloud | Yes | Has a free tier, then pay as you go |
| OpenRouter | One key from [openrouter.ai](https://openrouter.ai/keys) for hundreds of models from every lab | Cloud | Yes | Pay as you go; the price depends on the model you pick |
| Groq | A key from [console.groq.com](https://console.groq.com/keys) | Cloud | No, text only | Pay as you go; open models, very fast |
| Mistral | A key from [console.mistral.ai](https://console.mistral.ai/api-keys) | Cloud, hosted in Europe | Yes | Pay as you go |
| DeepSeek | A key from [platform.deepseek.com](https://platform.deepseek.com/api_keys) | Cloud | No, text only | Low-cost models |
| Ollama | Ollama running on your Mac, with a model pulled. No key. | Your Mac | No, unless you mark the model as reading images | Free |
| LM Studio | LM Studio's local server running, with a model loaded. No key. | Your Mac | No, unless you mark the model as reading images | Free |
| Apple on-device | macOS 26 or iOS 26 with Apple Intelligence on. No key. | Your device | No, text only, short answers | Free |
| Another server (custom) | The address of any server that speaks the OpenAI API (llama.cpp, vLLM, LiteLLM, a company gateway), and its key if it needs one | Wherever the server is | If you mark it | Whatever the server costs |

Prices change; check each provider's pricing page before you rely on it. For Claude, Broski prices calls from Anthropic's published prices: Haiku costs a small fraction of Sonnet, and Opus about twice Sonnet. Long conversations with Claude cost less after the first turns, because the earlier part is cached.

### Models on your Mac

- **Ollama:** install it from ollama.com, then pull a chat model that fits your Mac's memory. Broski finds it at `http://localhost:11434/v1`.
- **LM Studio:** load a model and start LM Studio's local server. Broski finds it at `http://localhost:1234/v1`.
- **Apple on-device:** turn on Apple Intelligence in System Settings. It's free and private, and suits short answers more than long riffs.

A local model is only as good as the model you load. Small models file notes well; long conversations and riffs need a larger one.

### What a model can and can't read

- A model that can't read images can't help with a screenshot: Broski says so instead of guessing. Session reports are written from the text when the model can't see the screenshots.
- A model that can't read PDFs gets the PDF's text instead.
- Some providers can't hold a reply to a fixed JSON shape (save cards, filing, reports). Broski puts the shape in the instructions for those and reads the reply leniently, so they still work.

## Local-only projects

Mark a project local only and its text goes only to models on your device. A model counts as on your device when it's Apple's on-device model, Ollama, LM Studio, or a custom server at a loopback address (`localhost`, `127.0.0.1` or `::1`) that you've marked as running on this Mac. A server elsewhere on your network never counts, even if you mark it.

- Settings › Models › **Local-only projects** maps each role to a model on this device. Choosing Ollama, LM Studio or Apple's model in the welcome fills these too.
- When a local-only role has no model of its own, another local model stands in, and the reply says "On this Mac: <model>".
- With no local model set up, Broski refuses rather than sending anything: "This conversation has to stay on this device, and no local model is set up."
- A conversation that mentions a local-only project stays on the device as a whole. The save suggestions aren't told local-only projects exist, so they can't file into them.

You mark a project local only in Settings › Companion, under **Living pages and privacy**. [Privacy](privacy.md) has the rest of the rules.

## Without any model

Broski still works. Quick notes are filed by its built-in phrase rules ("in the recipe box project, add a todo: …"), commands like "note: …" need no model, project pages are built from your notes by rules, and Ask lists the notes that match your question. Replies and riffs need a model.

## Keys

Keys stay on the device you typed them on:

- **Mac:** `~/Library/Application Support/Broski/secrets.json`, which only your user can read (mode 600). Not the Keychain: ad-hoc-signed builds get a new signature on every build, and the Keychain would ask for your login password each time.
- **iPhone:** the iPhone's Keychain.

Your model choices sync to the iPhone through `config.json` in your Broski folder, but keys never do. The iPhone's Settings asks for a key for each provider in use, so each device keeps its own.

## Spending

Settings › Models › **Spending** shows today's spend, this month's, and this month by model and by task (the conversation, save cards, riffs, project pages, filing, Ask, reports and so on). Every call is logged with its task in `usage/<month>.<device>.jsonl` in your Broski folder: token counts and cost, never text.

- Claude calls are priced. Other providers' calls are counted (tokens and calls) but not priced, so check their dashboards for what you spent.
- **Daily limit:** past the limit you set, work moves one role down (deep to everyday, everyday to fast) for the rest of the day, and replies say so. Because only Claude calls are priced, the limit counts only Claude spending.

## When something goes wrong

Errors name the provider and what to do: a key it didn't accept, an account out of credit, a model it doesn't have, a rate limit, or a local server that isn't running ("Couldn't reach Ollama at http://localhost:11434/v1. Is it running?"). Fix it in Settings › Models. [Troubleshooting](troubleshooting.md) has more.
