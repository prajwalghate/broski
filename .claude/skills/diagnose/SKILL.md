---
name: diagnose
description: Find out why the installed Broski misbehaves (mic not heard, a reply that never comes, a screen that looks wrong, data that seems missing) without touching the person's data, then fix it test-first. Use when the person reports a problem with the app they're running.
---

# Diagnosing the installed app

## Look before you guess

- **The log:** `<Broski folder>/.broski/broski.log` (usually `~/Library/Mobile Documents/com~apple~CloudDocs/Broski/.broski/broski.log`, or `~/Broski/.broski/broski.log`). It records steps, versions, devices and errors, never note or conversation text. Read the end of it; it's the only file in that folder you read routinely.
- **Which version is running:** the log's `started from` line, or `/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Broski.app/Contents/Info.plist`.
- **The machine:** macOS version (`sw_vers`), the audio devices (`system_profiler SPAudioDataType`), whether a Bluetooth speaker or a streaming app holds the mic.
- Ask the person for a screenshot when it's about what they see.

## Reproduce without their data

- **Voice and the mic:** `Broski --diagnose <audio file> <report>` with its flags (`--voice-processing-fallback`, `--mics` and the others in `Sources/Broski/Diagnostics.swift`). Make test audio with `say -o /tmp/phrase.aiff "…"`; with a Bluetooth speaker connected, `say` may play there instead.
- **The chat (keys, scrolling, focus):** `Broski --chat-check <report>`.
- **How screens look:** `Broski --snapshot <folder>`, light and dark.
- **Can this build read their data:** `Broski --check-folder <report>` reads the real folder without writing and reports what it couldn't read (counts only, never content).
- **Models:** reproduce with a fake connector in a unit test. A real call costs money: only with the person's yes.

Never write to the real Broski folder, `~/Library/Application Support/Broski` or `/Applications/Broski.app` while diagnosing (the guard asks first). Never read `secrets.json`.

## Then fix it like any bug

Write the failing test that reproduces it (`tdd` skill), fix, `scripts/ci.sh`, and ship with the `ship` skill. Tell the person what the cause was in plain words, what changed, and what you checked on their setup.
