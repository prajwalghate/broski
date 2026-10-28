# The iPhone app

The iPhone app is Broski in your pocket: the same conversation as the Mac, quick notes, and your notes to browse and search. It isn't in the App Store, so you build it with your own Apple ID. A free one works.

## What's in it

- **Talk:** the same conversation as the Mac, with memory, recall, citations, save cards, "note: …", remember and forget, think harder, private mode, riffs and thinking moves. Share photos and files; replies can be read aloud. The ⋯ menu has Riff, Thinking moves, Search my notes and the private vault.
- **Capture:** a quick note, typed or dictated.
- **Notes:** every project and note, with search.
- **Settings:** syncing with your Mac, voice, your model keys, and the morning check-in.

Siri ("Talk to Broski"), the Action Button, Shortcuts and Control Center open Broski listening. There are also "Riff with Broski", "Ask Broski" and "New Broski note". A `broski://` link opens a screen but never starts the microphone; only the ones you trigger yourself do.

## What you need

- A Mac with Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

  ```bash
  brew install xcodegen
  ```

- An Apple ID added in Xcode › Settings › Accounts. A free account gives you a personal team.
- An iPhone with iOS 17 or later, and a cable. Bark (on-device speech) and the Control Center buttons need iOS 18.

## Build and install

1. Copy the example settings file:

   ```bash
   cp iOS/Local.env.example iOS/Local.env
   ```

2. Open `iOS/Local.env` and fill in two values:
   - `BROSKI_BUNDLE_ID`: a reverse-DNS ID that's yours and no one else's, such as `com.<your-name>.broski`.
   - `BROSKI_TEAM_ID`: your team ID, from Xcode › Settings › Accounts.

   `iOS/Local.env` is never committed. Keep it out of pull requests.

3. Connect the iPhone with the cable, unlock it, and tap **Trust** if it asks. On iOS 16 or later, turn on Developer Mode (Settings › Privacy & Security › Developer Mode) when iOS asks for it.
4. Build, install and open the app:

   ```bash
   scripts/phone.sh
   ```

   The script generates the Xcode project from `iOS/project.yml` with XcodeGen, builds it signed with your team (registering the iPhone with your team the first time), installs it and opens it. To build without installing:

   ```bash
   scripts/phone.sh --build
   ```

5. With a free Apple ID, iOS may refuse to open the app until you trust your developer certificate: Settings › General › VPN & Device Management › your Apple ID › Trust.

The generated `iOS/BroskiPhone.xcodeproj` is never committed: change `iOS/project.yml` instead.

### The 7-day limit

An app signed with a free Apple ID stops opening after 7 days. Run `scripts/phone.sh` again to renew it; the app's data stays, and notes in iCloud Drive are never at risk.

## Sync with your Mac

The two apps share one Broski folder in iCloud Drive:

1. On the Mac: Settings › General › **Sync with iPhone**. Your notes move from `~/Broski` into iCloud Drive › Broski, and Broski restarts there.
2. On the iPhone: Settings › **Use my Mac's Broski folder**, then pick iCloud Drive › Broski. Pick the Broski folder itself, not a folder inside it.

Until you do this, the iPhone keeps its notes in a Broski folder on the phone, which you can see in the Files app. **Stop sharing** goes back to that folder; the shared notes stay in iCloud Drive for the Mac.

### What syncs

Everything in the Broski folder:

- Notes, sessions and the files you share.
- The conversation. Each device writes its own files (`conversations/<month>/<day>.mac.jsonl` and `….iphone.jsonl`) and reads both, so iCloud never has to merge two edits of one file.
- What Broski knows about you, decisions, and riff rules, also one file per device.
- Project pages. The Mac writes them; the iPhone reads them, and builds a simple one from your notes when the Mac hasn't written one yet.
- The private vault, as ciphertext only.
- `config.json`: your model choices, your local-only projects and whether links are read. The Mac writes it; the iPhone only reads it.

What doesn't sync: your keys (each device keeps its own), the microphone you picked on the Mac, and the voice models.

While Talk is on screen, the iPhone checks for new turns every 4 seconds; the Mac picks up the iPhone's turns as iCloud brings them. A turn from the other device says so ("on your iPhone"). Neither refreshes while a reply is on its way.

If `config.json` can't be read on the iPhone (iCloud is still downloading it, or it doesn't parse), every project counts as local only until it can. When the file doesn't parse, Settings says so.

## Models on the iPhone

The iPhone uses the roles and models you chose on the Mac, from `config.json`. Its Settings asks for a key for each provider in use; keys stay in the iPhone's Keychain and never sync. Use the same key as on the Mac, or a separate one.

A model on your Mac (Ollama, LM Studio) sits at an address only the Mac can reach, so the iPhone can't use it. Apple's on-device model runs on the iPhone itself (iOS 26 with Apple Intelligence on). Typing and the mic always work, and commands like "note: …" need no model.

## Voice on the iPhone

Apple's recognizer shows the words as you talk. For better English notes, download **Bark** in Settings › Voice (202 MB, under a minute on Wi-Fi, iOS 18 or later). The first preparation takes about 5 minutes with Broski open. Then Bark writes each English note when you stop, about 0.3 s for a 5-second phrase on an iPhone 15, with the same cleanup and project names as the Mac. Apple's recognizer writes the note whenever Bark isn't ready.

## The private vault on the iPhone

Talk › ⋯ › **Private vault**. It locks when Broski leaves the screen, hides its contents in the app switcher, and can open with Face ID after the first unlock. [Privacy](privacy.md) explains how it's encrypted.
