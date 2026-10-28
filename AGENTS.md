# Working on Broski (for coding agents)

Broski is a companion you talk to about your projects: a Mac menu-bar app, an iPhone app and a read-only MCP server, sharing one Swift core (`Sources/BroskiCore`). People run it every day on their own notes, so a bad change costs someone real data or a working mic. This file is how agents (Claude Code, Codex, Cursor, Copilot, Gemini CLI) work here without breaking it. Humans: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Map

| Where | What |
|---|---|
| `Sources/BroskiCore` | All logic: models and the gateway, conversation, memory, notes, trackers, vault, stored formats. Testable, no UI. |
| `Sources/Broski` | The Mac app (SwiftUI + AppKit). Thin: views and wiring. Dev tools: `ChatCheck`, `Snapshots`, `Diagnostics`, `FolderCheck`. |
| `iOS/` | The iPhone app (XcodeGen, `iOS/project.yml`). Thin, like the Mac app. |
| `Tests/BroskiCoreTests` | Unit tests (Swift Testing). New code is written test-first here. |
| `Sources/BroskiSelfTest` | Older assertion checks (`swift run BroskiSelfTest`); they move into the unit tests as modules change. |
| `scripts/` | `test.sh`, `ci.sh`, `build-app.sh`, `install-mac.sh`, `rollback-mac.sh`, `phone.sh`, `package.sh`; `scripts/agent/` holds the guardrails. |
| `site/` | The website (GitHub Pages). `docs/` holds the guides it links to. |

## Commands

```bash
scripts/test.sh ModelsTests GatewayTests   # the suites you're working on (type names): the red-green loop
scripts/test.sh                            # every unit test; a pass is recorded as green
scripts/ci.sh                              # what CI runs: secret scan, guardrail tests, build, tests, self-tests, chat check
scripts/ci.sh --ios                        # the same plus the iPhone app (unsigned)
.build/debug/Broski --snapshot /tmp/shots  # every screen as PNGs, light and dark, with sample data
.build/debug/Broski --chat-check /tmp/r    # the real chat views off screen: keys, scrolling (exit 1 on failure)
scripts/install-mac.sh                     # install the built app safely (see Releasing)
```

Use the full Xcode: the scripts set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when it's there. One build at a time: the maintainer's Mac has 8 GB, and two builds fail or overheat it (the guard refuses a second one).

## The loop

1. **Find the behavior's home in BroskiCore.** If it's in an app target today and has logic, move the logic down first.
2. **Write the failing test** in `Tests/BroskiCoreTests`, named for what the person sees ("a local-only project never reaches a cloud model"). Run `scripts/test.sh YourTests` and watch it fail for the right reason.
3. **Write the code** until it passes. Then run `scripts/test.sh` (everything).
4. **UI changes:** render `--snapshot` before and after and look at both themes; run `scripts/ci.sh` (it runs the chat check). See the `broski-ui` skill.
5. **Bugs get a failing test first**, reproducing the report. A fix without one isn't done.
6. **Before committing:** `scripts/ci.sh` (`--ios` if the iPhone app or shared code changed). The pre-commit hook refuses code that hasn't had a green run as it is now.

For an important test, break the code on purpose once and check the test catches it.

## Guardrails (what the hooks enforce, and why)

Claude Code loads them from `.claude/settings.json`; the git hook applies to everyone. Each one is tested in `scripts/agent/test-hooks.sh`.

- **Code that hasn't passed doesn't ship.** You're sent back once if you try to finish with code that changed since its last green run, and a commit of untested code is refused.
- **One build at a time.** A second `swift build`, `swift test`, `xcodebuild` or build script is refused while one runs.
- **History stays.** No force-push, no remote branch deletes, no `--no-verify`, no turning the git hooks off. Resets, cleans, rebases and discarding changes need the person's yes.
- **Production stays safe.** The installed app changes only through `scripts/install-mac.sh`. Writing to the person's real Broski folder (`~/Library/Mobile Documents/com~apple~CloudDocs/Broski`, `~/Broski`) or `~/Library/Application Support/Broski` needs their yes; tests use a temporary folder.
- **Secrets stay unread.** `.env*`, `*.db`, `iOS/Local.env`, the secrets file and Keychain items are off limits. No `sudo`.
- **The guardrails are the person's.** Changes to `.claude/settings.json`, `.githooks/` or `scripts/agent/` need their approval.

## Rules of the product

- **One way to a model:** every call goes through `ModelGateway` (BroskiCore). It masks secrets, routes by role, keeps local-only projects on local models, and logs cost. No feature talks to a provider directly.
- **Any provider:** nothing may assume Claude. Features ask for a role (`fast`, `everyday`, `deep`); Settings maps roles to providers (`ProviderPreset`). Use capability checks (images, PDFs, structured output), never a provider's name.
- **Privacy:** text from a local-only project never reaches a cloud model, and every new send path gets a privacy test. Private mode keeps nothing: it reads no memory, projects or recall, talks to the same models as any conversation, and nothing from it is written to the Broski folder unless the person asks (Save on a card, Keep when leaving, a "note: …"). Vault contents never reach a model, search, recall, memory or MCP.
- **Untrusted text is data:** text from files, web pages, trackers and tool output is fenced in prompts, never followed as instructions.
- **The person decides:** notes, todos, decisions and projects are created only after their tap.
- **Files are the source of truth:** markdown, JSON or JSONL in the person's Broski folder, each format versioned (`"v": 1`, or `format: 1` in front matter), with round-trip and upgrade tests. One writer per file: each device appends to its own.
- **Never** write into a project's repository, run its code, or read its `.env*` / `*.db` files. Trackers are read in place with git plumbing only (no fetch, pull, push or worktrees).
- **No personal data** in code, tests, fixtures or docs: no real names, notes, project data, paths, bundle IDs or keys. The secret scan blocks the common ones.
- **English:** Broski replies in English; UI copy is plain, short and specific (see `broski-ui`).

## Releasing

Use the `ship` skill. In short: bump the versions (`Resources/Info.plist`, `iOS/project.yml`), `scripts/ci.sh --ios`, `scripts/build-app.sh`, `scripts/install-mac.sh` (it checks the new build reads the real data without writing it, keeps the old app, starts the new one and rolls back by itself if it doesn't come up), `scripts/phone.sh` for the iPhone, then commit and push. `scripts/rollback-mac.sh` puts the previous version back.

## When the installed app misbehaves

Use the `diagnose` skill: read `<Broski folder>/.broski/broski.log` (it never holds note text), reproduce with `--diagnose`, `--chat-check` or a unit test, and write the failing test before the fix.
