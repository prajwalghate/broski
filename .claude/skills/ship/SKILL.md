---
name: ship
description: Release a new Broski version to the Mac (and the iPhone) without breaking the person's setup - version bump, full CI, safe install with automatic rollback, phone install, commit and push. Use whenever a change is ready to reach the installed app.
---

# Shipping Broski

The installed app is production: the person's notes, conversations and mic depend on it. Every step below either proves the new build is good or keeps a way back.

## 1. Ready?

- The working tree holds only this release's changes (`git status`), and the `reviewer` subagent has read the diff.
- Versions: bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` for the Mac; `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (both targets) in `iOS/project.yml` for the iPhone. Patch for fixes, minor for features. Add the release to `CHANGELOG.md`.

## 2. Prove it

```bash
scripts/ci.sh --ios
```

Secret scan, guardrail tests, build, every unit test, self-tests, the chat check and the iPhone build. Nothing ships on red. A pass records the code as green.

## 3. Build and install the Mac app

```bash
scripts/build-app.sh
scripts/install-mac.sh
```

`install-mac.sh` refuses code that isn't green, then:
1. runs the new build's chat check off screen, and has the new build read the person's real Broski folder **without writing** (`--check-folder`), failing if it reads less than the installed version did;
2. keeps the installed app in `~/Library/Application Support/Broski/Previous/` (the last three);
3. quits Broski, installs the new one, starts it, and waits for the log to say the new version started;
4. if it doesn't come up, puts the previous version back and starts that.

Afterwards, `scripts/rollback-mac.sh` puts the previous version back at any time.

## 4. The iPhone

```bash
scripts/phone.sh
```

It needs the iPhone unlocked and connected (cable, or the same Wi-Fi once paired), and `iOS/Local.env` with the person's bundle ID and team. A free Apple ID's profile lasts 7 days; say when it expires. If no phone is connected, say so and leave it for later; don't skip silently.

## 5. Commit and push

- One commit for the release, message: what changed for the person, then the versions, e.g. `Any model for every feature (Mac 0.11.0, iPhone 0.7.0)`.
- The pre-commit hook runs the secret scan and checks the code is green. Never `--no-verify`.
- `git push`. CI runs again on GitHub; check it went green.
- For a public release, tag it (`git tag v0.11.0 && git push origin v0.11.0`): the release workflow builds the app and attaches it to a GitHub release.

## 6. Tell the person

What changed for them, what you verified (and how), what you couldn't (the phone wasn't connected, a mic test needs them), and how to roll back.
