# Contributing to Broski

Thanks for helping. Broski holds people's thinking, so two things matter more than speed: nothing gets lost, and nothing leaves the device without the user's say-so.

## Set up

1. macOS 15 or later on Apple silicon, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) for the iPhone app (`brew install xcodegen`).
2. If you have more than one Xcode, point the tools at the right one: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
3. Install the git hooks once: `scripts/install-hooks.sh` (a secret scan runs before every commit).
4. For the iPhone app, copy `iOS/Local.env.example` to `iOS/Local.env` and put in your own bundle ID and Apple team. That file is never committed.

## Build and test

```bash
scripts/ci.sh            # everything CI runs: build, unit tests, self-tests, secret scan
scripts/ci.sh --ios      # the same, plus the iPhone app (no signing)
scripts/build-app.sh     # build Broski.app into build/
scripts/phone.sh         # build and install on a connected iPhone
```

On a laptop with 8 GB of memory, run one build at a time.

## How we work

- **Tests first.** Write the test that shows what should happen, watch it fail, then write the code. Every bug fix starts with a failing test. New tests go in `Tests/BroskiCoreTests` (Swift Testing); the older checks in `Sources/BroskiSelfTest` move over as their modules change.
- **Logic lives in BroskiCore.** The Mac app, the iPhone app and the MCP server stay thin, so the logic is shared and testable.
- **Files are the source of truth.** Anything Broski stores is markdown, JSON or JSONL in the user's Broski folder, with a version number in each format. A new format comes with a round-trip test and an upgrade test.
- **One writer per file.** Each device appends to its own files, so iCloud never has to merge two edits.

## Privacy and security rules

A change that breaks one of these won't be merged:

- Nothing from a local-only project reaches a cloud model. Every new path that sends text off the device has a privacy test.
- Broski never writes into a project's repository or runs its code. It reads trackers in place, and never reads `.env*` or `*.db` files.
- No secrets in files that sync, no note or conversation text in logs.
- Text from files, web pages and trackers is data, never instructions: it's fenced in prompts, and models get no tools that write outside the Broski folder.
- Tracked items (notes, todos, decisions, projects) are created only after the user's tap.

See `SECURITY.md` to report a vulnerability.

## Pull requests

- One change per pull request, with its tests.
- Say what changed for the person using Broski, and how you checked it (tests, screenshots from `--snapshot`, a device run).
- Keep personal data out: no real notes, project names, paths or keys in code, tests or fixtures. The secret scan blocks the common ones.

By contributing you agree that your work is licensed under the Apache License 2.0, like the rest of the project.
