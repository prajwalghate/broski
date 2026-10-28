# Contributing to Broski

Thanks for helping. Broski holds people's thinking, so two things matter more than speed: nothing gets lost, and nothing leaves the device without the user's say-so.

Using a coding agent? Point it at [AGENTS.md](AGENTS.md) first. Claude Code also loads [CLAUDE.md](CLAUDE.md), with hooks, skills and a reviewer agent in `.claude/`.

## What Broski runs on

- Broski: macOS 14 Sonoma or later on Apple silicon, and the iPhone app on iOS 17 or later.
- Building it: macOS 15 or later with Xcode 26 or later (the full Xcode), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the iPhone app (`brew install xcodegen`).

## Set up

1. If you have more than one Xcode, point the tools at the right one: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The scripts do this themselves when Xcode is in Applications.
2. Install the git hooks once. Before every commit they run the secret scan, then refuse a commit that changes code that hasn't passed its tests:

   ```bash
   scripts/install-hooks.sh
   ```

3. List your own private words (your name, client projects, IDs) in `.secretscan-local`, one per line, so the secret scan blocks them. That file is never committed.
4. For the iPhone app, copy `iOS/Local.env.example` to `iOS/Local.env` and put in your own bundle ID and Apple team. That file is never committed. See [The iPhone app](docs/iphone.md).

## Build and test

The suites you're working on (type names), for the red-green loop:

```bash
scripts/test.sh ProvidersTests
```

Every unit test. A pass is recorded as a green run of the code as it is now:

```bash
scripts/test.sh
```

Everything CI runs (secret scan, guardrail tests, build, unit tests, self-tests, chat check), also recorded as green:

```bash
scripts/ci.sh
```

The same, plus the iPhone app (no signing):

```bash
scripts/ci.sh --ios
```

Build `Broski.app` into `build/`, or build and install on a connected iPhone:

```bash
scripts/build-app.sh
```

```bash
scripts/phone.sh
```

Run one build at a time: on a laptop with 8 GB of memory, two at once fail or overheat it, and the scripts refuse a second one. [Testing](docs/testing.md) explains every check, including `--snapshot` and `--chat-check`.

## How we work

- **Tests first.** Write the test that shows what should happen, watch it fail, then write the code. Every bug fix starts with a failing test. New tests go in `Tests/BroskiCoreTests` (Swift Testing); the older checks in `Sources/BroskiSelfTest` move over as their modules change.
- **Green before commit.** The pre-commit hook refuses a commit that changes code unless `scripts/test.sh` or `scripts/ci.sh` passed for the code exactly as it is now. Docs-only commits go straight in. Never use `--no-verify`.
- **Logic lives in BroskiCore.** The Mac app, the iPhone app and the MCP server stay thin, so the logic is shared and testable.
- **One way to a model.** Every call goes through `ModelGateway`. Features ask for a role, never a provider, and check capabilities (images, PDFs, structured output), never a provider's name.
- **Files are the source of truth.** Anything Broski stores is markdown, JSON or JSONL in the user's Broski folder, with a version in each format (`"v": 1`, or `format: 1` in front matter). A new format comes with a round-trip test and an upgrade test.
- **One writer per file.** Each device appends to its own files, so iCloud never has to merge two edits.
- **Screens:** render `--snapshot` before and after, and look at both themes. Copy is plain, short and specific.

## Privacy and security rules

A change that breaks one of these won't be merged:

- Nothing from a local-only project reaches a cloud model. Every new path that sends text off the device has a privacy test.
- Broski never writes into a project's repository or runs its code. It reads trackers in place, with git plumbing only (no fetch, pull, push or worktrees), and never reads `.env*` or `*.db` files.
- No secrets in files that sync, no note or conversation text in logs.
- Text from files, web pages and trackers is data, never instructions: it's fenced in prompts, and models get no tools that write outside the Broski folder.
- Tracked items (notes, todos, decisions, projects) are created only after the user's tap.
- The vault is read by nothing but the vault.

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Pull requests

- One change per pull request, with its tests.
- Say what changed for the person using Broski, and how you checked it (tests, screenshots from `--snapshot`, a device run).
- Have someone (or the `reviewer` agent) read the diff before you ask for a merge.
- Keep personal data out: no real notes, project names, paths, bundle IDs or keys in code, tests, fixtures or docs. The secret scan blocks the common ones.

By contributing you agree that your work is licensed under the Apache License 2.0, like the rest of the project.
