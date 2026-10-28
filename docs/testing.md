# Testing

People run Broski every day on their own notes, so a change is done only when it's been checked at the right level. This page is the ladder, from the quickest check to the slowest, and the guardrails that make sure nothing untested ships.

Use the full Xcode: the scripts set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when it's there. Run one build at a time; the scripts refuse to start while another build is running, because two at once fail or overheat a Mac with 8 GB.

## 1. Unit tests

Swift Testing, in `Tests/BroskiCoreTests`. New behavior is written test-first: the failing test, then the code.

While you work, run only the suites you're changing (type names, matched as regular expressions):

```bash
scripts/test.sh ProvidersTests GatewayAndMemoryTests
```

Then run every test:

```bash
scripts/test.sh
```

A pass with no filter is recorded as a green run of the code as it is now (see "The green-run record" below).

Tests never touch the network, spend money or read your real data:

- **Models:** a fake `ModelConnector` records each request and returns a canned reply. Wire formats are checked through the connectors' `body` and `parse` functions, or a fake transport.
- **Files:** a fresh temporary folder per test, removed afterwards.
- **Time:** dates are passed in, never read from the clock.
- **Devices:** two devices are two device names writing their own files in the same temporary folder.

Every bug fix starts with a test that reproduces the report and fails before the fix. Every stored format has a round-trip test and an upgrade test that reads a line written by the previous version. Every path that sends text off the device has a privacy test showing local-only projects, private mode and the vault stay where they belong. For a test that guards privacy, data or money, break the code on purpose once and check the test catches it.

## 2. Self-tests

Older assertion checks of the parser, the project matcher, the note store, living pages, trackers and onboarding:

```bash
swift run BroskiSelfTest
```

They move into the unit tests as their modules change.

## 3. Guardrail tests

`scripts/agent/test-hooks.sh` feeds each agent hook and the commit check the input it would get, and checks what it decides: allowed, refused, or put to the person. It runs in a throwaway repository for the commit and Stop checks.

```bash
scripts/agent/test-hooks.sh
```

## 4. The chat check

The real conversation views, driven off screen in a throwaway Broski folder: it presses Return, Shift-Return, Up and Esc in the message box, pastes, scrolls the conversation, and checks what happened. No model is called and nothing real is touched. It exits with 1 when anything failed.

```bash
.build/debug/Broski --chat-check /tmp/chat-report.txt
```

## 5. Snapshots

Every screen rendered with sample data, in light and dark, as PNGs in `light/` and `dark/` folders. Render before and after a UI change and look at both themes.

```bash
.build/debug/Broski --snapshot /tmp/broski-shots
```

## 6. Diagnostics

`--diagnose <audio file> <report file>` feeds a recording through the speech pipeline in real time and writes down what each engine heard. No microphone is involved. Launch it through `open` so it runs with Broski's permissions:

```bash
open -n -W build/Broski.app --args --diagnose /tmp/phrase.aiff /tmp/report.txt
```

Extra flags check one thing at a time, for example `--transcribe <audio>` (the app's own transcriber), `--mics` (the Mac's microphones), `--voice-processing-fallback` (the plain-mic fallback, forced) and `--three-channel <audio>` (a multi-channel mic). Pass `/dev/null` as the audio file for checks that don't need one. Some flags make live calls to a real model and cost money: `--converse`, `--riff-mode`, `--read-link`, `--first-run`, `--reflect`, `--new-pack`, `--cache-check`, `--page-cost` and `--eval-riff`. Run those only with your own key, in a throwaway folder they set up themselves. `Sources/Broski/Diagnostics.swift` lists them all.

## 7. The folder check

Reads your Broski folder (the one the app uses) the way the app does, without writing anything, and reports how many entries of each format it read and couldn't read (config, projects, conversations, usage, memory, riff rules, notes, vault). Counts only, never content. It exits with 1 when `config.json` doesn't parse.

```bash
.build/debug/Broski --check-folder /tmp/folder-report.json
```

`scripts/install-mac.sh` runs it with the installed version and the new one before replacing anything, and refuses a new version that reads less.

## 8. Everything CI runs

```bash
scripts/ci.sh
```

The secret scan, the guardrail tests, the build, every unit test, the self-tests and the chat check. Add `--ios` to build the iPhone app too (unsigned):

```bash
scripts/ci.sh --ios
```

A pass is recorded as green. On GitHub, CI runs `scripts/ci.sh --ios` on every push to `main` and every pull request, on clean macOS 14, 15 and 26 runners, so a change that only works on one macOS version is caught.

## The green-run record

`scripts/test.sh` (with no filter) and `scripts/ci.sh` record a hash of the code they tested in `.build/agent/green`. The code is everything under `Sources`, `Tests` and `iOS`, plus `Package.swift` and `Package.resolved`, tracked or not (ignored files like `iOS/Local.env` don't count). If the code changes while the tests run, the run isn't recorded.

Three checks read that record:

- **The pre-commit hook** (install it once with `scripts/install-hooks.sh`) runs the secret scan on what's staged, then refuses a commit that changes code unless the code as it is now has had a green run. Commits of docs and other files go straight in.
- **The Stop hook** in Claude Code sends an agent back, once, when it tries to finish with code that changed since its last green run.
- **`scripts/install-mac.sh`** installs only an app built from green code.

## The secret scan

`scripts/check-secrets.sh` looks for API keys, tokens, private keys and account ids in every tracked file (`--staged` for what's about to be committed). It also blocks your own private words, listed one per line in `.secretscan-local`, which is never committed. A test fixture line that must keep a match ends with `secretscan:allow`.

```bash
scripts/check-secrets.sh
```

## Agent hooks

For Claude Code, `.claude/settings.json` adds a guard before every shell command and file edit (`scripts/agent/guard-bash.sh`, `guard-edit.sh`), the Stop check (`check-green.sh`), and a short status at session start (`session-start.sh`). The guards stop a second build, force-pushes, `--no-verify`, reading secret files, and writes to the person's real Broski folder or installed app. [CONTRIBUTING.md](../CONTRIBUTING.md) and [AGENTS.md](../AGENTS.md) have the rules they enforce.
