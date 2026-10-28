# Releasing

For maintainers. The installed app is production: people's notes, conversations and mics depend on it. Every step below either proves the new build is good or keeps a way back. Coding agents follow the same steps through the `ship` skill.

## 1. Ready?

- The working tree holds only this release's changes (`git status`), and a person or the `reviewer` agent has read the diff.
- Bump the versions. Patch for fixes, minor for features.
  - Mac: `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
  - iPhone: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `iOS/project.yml`, in both targets (`BroskiPhone` and `BroskiWidgets`).
- Add the release to [CHANGELOG.md](../CHANGELOG.md).

## 2. Prove it

```bash
scripts/ci.sh --ios
```

The secret scan, the guardrail tests, the build, every unit test, the self-tests, the chat check and the iPhone build. Nothing ships on red. A pass records the code as green. [Testing](testing.md) explains each step.

## 3. Build and install on your Mac

```bash
scripts/build-app.sh
```

```bash
scripts/install-mac.sh
```

`build-app.sh` builds `build/Broski.app` and records the hash of the code it was built from. `install-mac.sh` then:

1. refuses a build that isn't of green code (tested and built from exactly the code as it is now);
2. runs the new build's chat check off screen;
3. has the installed version, then the new one, read your real Broski folder without writing anything (`--check-folder`), and refuses a new version that reads less of any format, or can't read `config.json`;
4. keeps the installed app in `~/Library/Application Support/Broski/Previous/` (the last three);
5. quits Broski, installs the new one, starts it, and waits for the log to say the new version started;
6. if it doesn't come up, puts the previous version back and starts that.

`--force` skips the green check, for a build checked some other way.

To go back at any time:

```bash
scripts/rollback-mac.sh
```

`scripts/rollback-mac.sh 0.10.2` puts back that version, and `scripts/rollback-mac.sh --list` shows what's kept. The version it replaces is kept too, so you can go forward again the same way.

## 4. The iPhone

```bash
scripts/phone.sh
```

It needs the iPhone unlocked and connected, and `iOS/Local.env` with your bundle ID and team. A free Apple ID's profile lasts 7 days. [The iPhone app](iphone.md) has the details.

## 5. Commit and push

- One commit for the release. The message says what changed for the person, then the versions, for example `Any model for every feature (Mac 0.11.0, iPhone 0.7.0)`.
- The pre-commit hook runs the secret scan and checks the code is green. Never `--no-verify`.
- Push, and check CI goes green on GitHub.

## 6. Tag a public release

```bash
git tag v0.11.0
```

```bash
git push origin v0.11.0
```

The tag starts the release workflow: it builds the app on a clean macOS runner, zips it, and attaches the zip and its SHA-256 checksum to a GitHub release. Paste the version's CHANGELOG entry into the release notes.

## Signing and notarization

Without an Apple Developer ID the app is ad-hoc signed, and people approve it once on first open (System Settings › Privacy & Security › Open Anyway). The ad-hoc signature uses a designated requirement that only names the bundle ID, so macOS permissions carry over between builds.

With a Developer ID, set these before building, and the scripts sign with the hardened runtime, notarize and staple, so the app opens like any other download:

- `BROSKI_SIGN_IDENTITY`, the signing identity, like `Developer ID Application: Your Name (TEAMID)`.
- `BROSKI_NOTARY_PROFILE`, a notarytool profile made once with `xcrun notarytool store-credentials`.

## A beta disk image

```bash
scripts/package.sh
```

Runs the self-tests, builds, and writes `dist/Broski-<version>.dmg` and `.zip`, then prints the SHA-256 of both. The disk image has the drag-to-Applications layout and includes `BETA.md` as "Read me first", which covers installing, the one-time Open Anyway step, permissions and feedback.

## The website

`site/` is the website. `.github/workflows/pages.yml` publishes it to GitHub Pages whenever `site/` changes on `main`, filling in the repository and site links at publish time, so the site's source never names the repository.

## Security fixes

Fixes go into the latest release of the Mac app and the iPhone app; older builds aren't patched. See [SECURITY.md](../SECURITY.md).
