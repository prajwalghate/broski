# Troubleshooting

Start with the event log: `<Broski folder>/.broski/broski.log` (`~/Broski/.broski/broski.log`, or `~/Library/Mobile Documents/com~apple~CloudDocs/Broski/.broski/broski.log` once you sync with the iPhone). It lists each step of a capture, the versions and devices, and errors, without the words you said. Settings › About › **Copy diagnostics for feedback** copies your version, settings and the log's last lines.

## The mic hears nothing

- **"Turn on Dictation", or no transcript at all:** turn on System Settings › Keyboard › Dictation. Apple's recognizer refuses to run without it, even on the device.
- **The panel stays empty:** check the input device in System Settings › Sound. An iPhone or Bluetooth mic can win.
- **"No sound came from <mic>":** the mic sent nothing at all. It may be muted, or another app (a stream, a call, a recorder) is holding it. Pick the mic you talk into with the arrow next to the mic button, or in Settings › Voice › **Listen on**. On the iPhone, stop the other app's recording, then try again.
- **"Didn't catch any words from <mic>":** there was sound but no words. Move a little closer, or choose another mic.
- **"Couldn't start <mic>":** the mic you chose is in use by another app or was just unplugged. Broski falls back to the system's mic.
- **A Bluetooth speaker is connected:** with some speakers (and with a streaming app's audio device), Apple's voice processing, which does the echo cancellation, can't start. Broski falls back to the plain mic on a fresh audio engine, logs "Voice processing couldn't start (…); using the plain mic", and remembers that mic-and-speaker pair so it doesn't lose your first words retrying next time. Echo cancellation is off while that pair is in use. A mic you pick yourself always runs plain.
- **Streaming or on a call:** another app may hold the mic, or its virtual device may be the system input. Choose your real mic in Settings › Voice. Broski mixes a mic with several channels down to the ones that carry sound, so three-channel audio interfaces are heard.
- **Bluetooth headsets:** if one is your input, macOS may switch it to low-quality "call" audio while Broski listens.
- **Echo or music in your notes:** turn on Settings › Voice › **Voice isolation** (echo cancellation and noise suppression). It turns itself off on device setups that don't support it.

To see what Broski sees, list the mics and listen for two seconds on each (the report goes to the file you name):

```bash
open -n -W /Applications/Broski.app --args --diagnose /dev/null /tmp/mics.txt --mics
```

## Recognition is wrong

- **Made-up project names get misheard:** pick the project chip in the panel. Whisper is primed with your project names, and Bark's cleanup snaps near-misses to them, but neither is perfect.
- **Check the recognizer without a mic:** make a recording, then run it through every engine.

  ```bash
  say -o /tmp/phrase.aiff "Broski. In the recipe box project, add a todo: test"
  ```

  ```bash
  open -n -W build/Broski.app --args --diagnose /tmp/phrase.aiff /tmp/report.txt
  ```

- **Bark says it's preparing:** after the download it prepares itself for your Mac once, which takes a few minutes (about 5 on an iPhone, with Broski open). Whisper or Apple's dictation writes your notes meanwhile.
- **Bark isn't offered:** it needs macOS 15 or later on the Mac, and iOS 18 or later on the iPhone. Whisper and Apple's dictation work on older versions.

## Shortcuts and keys

- **A shortcut does nothing:** another app may have taken it. Settings says so; pick another one there.
- **Holding fn opens the emoji picker or Dictation:** set System Settings › Keyboard › "Press fn key to" (shown with a globe) to **Do Nothing**. Hold fn also needs Accessibility.
- **⌥⇧C doesn't clip in some apps:** allow Accessibility in System Settings › Privacy & Security. Right-click › Services › **Add to Broski** works without it.
- **⌥⇧B opens a note instead of the conversation:** the menu bar's **Shortcut opens the conversation** is unchecked. Check it again.

## Models

- **"<Provider> didn't accept the key":** paste the key again in Settings › Models. Check it was made on the provider's own key page.
- **"Out of credit":** add credit on the provider's website, or choose another model for that role.
- **"Doesn't have that model":** the provider dropped or renamed it. Choose another in Settings › Models; Broski reads the provider's current list.
- **"Couldn't reach Ollama (or LM Studio) … Is it running?":** start it, and load a model. On the iPhone a model on your Mac can't be reached at all.
- **"This conversation has to stay on this device":** the conversation touches a local-only project and no model on this device is set up. Add Ollama, LM Studio or Apple's on-device model in Settings › Models › Local-only projects.
- **"Can't read images":** the model for that role is text only. Describe it in words, or choose a model that reads images.
- **Replies come from a cheaper model:** you're past today's limit (Settings › Models › Spending), so work moved one role down. The reply says so.

## Sync and files

- **"Broski can't find your notes folder":** the folder you picked isn't there right now (a drive not mounted, iCloud signed out). Connect it and choose Try Again, or pick another folder. Broski asks rather than quietly using `~/Broski`, where new notes would be missing from your real folder.
- **"config.json couldn't be read":** a typo in a hand edit. Broski keeps your file as `config.broken.json`, uses defaults, and treats every project as local only until it's fixed. Fix the file (or copy back what you need), then restart Broski.
- **The iPhone doesn't show the Mac's notes:** on the Mac, Settings › General › Sync with iPhone; on the iPhone, Settings › Use my Mac's Broski folder, and pick the Broski folder itself. Files iCloud hasn't fetched yet are requested; Settings shows how many are still coming.
- **Claude Code says it can't read Broski's notes:** allow the app that runs Claude Code in System Settings › Privacy & Security › Files and Folders. See [Claude Code and MCP](mcp.md).

## Opening the app

- **macOS says it can't check Broski for malicious software:** on macOS 15 or later, System Settings › Privacy & Security › **Open Anyway**; on macOS 14, right-click Broski in Applications › **Open**. Once.
- **The iPhone app stopped opening:** a free Apple ID's profile lasts 7 days. Run `scripts/phone.sh` again. See [The iPhone app](iphone.md).
- **A new build misbehaves:** if you installed with `scripts/install-mac.sh`, put the previous version back:

  ```bash
  scripts/rollback-mac.sh
  ```

## Battery

The wake word keeps the mic on and uses noticeably more battery. Turn it off in the menu bar, and use the shortcut or hold fn instead.

## Seeing every screen

Render every screen with sample data, in light and dark:

```bash
.build/debug/Broski --snapshot /tmp/broski-shots
```

This draws the dashboard, the panel states, the conversation, onboarding and settings.

Still stuck? [SUPPORT.md](../SUPPORT.md) says where to ask and what to include.
