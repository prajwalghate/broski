# Security

Broski holds people's notes, conversations, memory and API keys, and reads their project repositories. We take reports seriously and fix them first.

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **Report a vulnerability** button on this repository's Security tab, which reaches the maintainers privately. Include what you found, how to reproduce it, and what an attacker could do with it.

You'll hear back within 7 days. We'll agree a fix and a disclosure date with you, and credit you in the release notes unless you'd rather not be named.

## Supported versions

Fixes go into the latest release of the Mac app and the iPhone app. Older builds aren't patched; update to get the fix.

## What's in scope

- Anything that sends a note, conversation, memory or resource off the device when it shouldn't: local-only projects, private mode, secrets in text.
- Prompt injection that makes Broski create items, change memory, fetch a URL or act without the user's tap.
- The MCP server (`Broski --mcp`): reading outside the Broski folder, reading local-only projects, writing anything but Broski's own trackers.
- Reading a project repository: path escapes, symlinks, running repo code, reading `.env*` or `*.db` files.
- The `broski://` URL scheme, App Intents and Siri phrases.
- Model downloads and their checksums; API key storage.

Out of scope: attacks that need full control of the user's unlocked Mac, and denial of service by filling the user's own folder.

The threat model and the testing plan live in the project's Foundations document; `docs/SECURITY-REVIEW.md` is the checklist an outside review works through.
