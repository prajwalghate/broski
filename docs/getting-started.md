# Getting started

This page takes you from download to your first conversation: installing Broski, the first run, the permissions it asks for, the voice models, and where your files live.

## What you need

- A Mac with Apple silicon, on macOS 14 Sonoma or later.
- For the iPhone app (optional): an iPhone with iOS 17 or later. You build it yourself with a free Apple ID; see [The iPhone app](iphone.md).
- For replies: any model. A key from a cloud provider, a model on your Mac, or Apple's on-device model. See [Choosing your AI](models.md). Without one, quick notes still work.

## Install from a release

1. Download the latest zip from the [Releases page](../../../releases/latest).
2. Optional: check the download against the SHA-256 checksum on the release page. In Terminal, this prints the zip's checksum:

   ```bash
   shasum -a 256 ~/Downloads/Broski-*.zip
   ```

3. Unzip it and drag **Broski** into **Applications**. Open it from there, not from Downloads: a copy that runs from Downloads or a disk image gets a temporary path, and Claude Code can't connect to it.
4. If macOS says it can't check Broski for malicious software, the build isn't notarized with an Apple Developer ID:
   - **macOS 15 or later:** open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Broski.
   - **macOS 14:** right-click Broski in Applications and choose **Open**.

   You only do this once.

Broski lives in the menu bar. It has no Dock icon unless one of its windows is open.

## Build from source

You need macOS 15 or later with Xcode 26 or later (the full Xcode, not only the Command Line Tools). Clone this repository, then from its folder:

```bash
scripts/build-app.sh --open
```

That builds `build/Broski.app` with its icon, signs it, and starts it. The ad-hoc signature uses a designated requirement tied to the bundle ID, so the microphone, speech and folder permissions you grant survive rebuilds.

To install it into Applications the safe way, run the tests, build, then install:

```bash
scripts/test.sh
```

```bash
scripts/build-app.sh
```

```bash
scripts/install-mac.sh
```

`install-mac.sh` checks the new build can read your Broski folder before it replaces anything, keeps the previous version, and puts it back by itself if the new one doesn't start. [Releasing](releasing.md) explains each step.

## The first run

A short welcome walks you through setup:

1. **How to call Broski:** the keyboard shortcut, holding fn, the wake word "broski", and a floating Broski head. Pick any mix; you can change it later in Settings › General.
2. **Voice:** allow the microphone and speech recognition, check that Dictation is on, and try **Test my voice**. Voice is optional: you can type everything.
3. **Your AI:** choose a provider. Paste a key (each cloud provider has a **Get a key** link) or pick a model on your Mac. Broski tests it, reads the provider's own list of models and picks one for each job, which you can change. You can skip this and add one later in Settings › Models.
4. **Project folders:** pick the folder where your projects live, like `~/Developer`. Each folder inside it becomes a project you can name.

Then your first conversation opens. Broski asks what to call you, what you're working on and how you like answers. After your third answer it remembers what you said; you can see and undo each fact under **What Broski knows** in the menu bar. If no model is set up yet, a card in the conversation offers to set one up.

Settings › About › **Show welcome again** runs the welcome a second time.

## Calling Broski

| Shortcut | What it does |
|---|---|
| ⌥⇧B | Opens the conversation |
| Hold fn | Talk into the conversation; let go to send. Off until you turn it on in Settings › General. Needs Accessibility. |
| ⌥⇧N | A quick note: tap to type, hold to talk |
| ⌥⇧S | A screenshot note: grab part of the screen, then say or type what it's about |
| ⌥⇧C | Clips the text you've highlighted in any app, with where it came from |
| ⌥⇧A | Ask Broski about your notes and trackers |
| ⌥⇧H | Help with this: Broski looks at the window you're in |

You can change every shortcut in Settings. The menu bar menu has the rest: the dashboard, What Broski knows, the private vault, riffs, the check-in, and switches for the floating head, the pill at the top of the screen and the wake word. If you prefer the older behaviour, uncheck **Shortcut opens the conversation** in the menu: ⌥⇧B then opens a quick note again.

## Permissions

Broski asks for each permission when a feature first needs it. Everything except the microphone and speech recognition is optional.

| Permission | What it's for |
|---|---|
| Microphone | Talking to Broski and dictating notes. The mic is on only while you talk, unless you turn on the wake word. Call notes use it too. |
| Speech Recognition | Apple's live transcript while you talk, and the wake word. |
| Dictation (System Settings › Keyboard › Dictation) | Not a permission, but Apple's speech recognition only runs while Dictation is on, even on the device. |
| Accessibility | Holding fn to talk, clipping with ⌥⇧C in every app, and noting the window title and selected text. Right-click › Services › **Add to Broski** clips without it. |
| Screen Recording | Screenshot notes, the camera in the conversation, Help with this, and the other side of a call in call notes. |
| Automation (your browser) | The address of the page you're on, so a note remembers it. macOS asks once per browser. |
| Notifications | Automations that notify you. |
| Touch ID | Opening the private vault after the first unlock, if you want it. |

## Voice models

Broski turns speech into text on your Mac. Three engines take part:

- **Apple's dictation** shows the words as you talk (the live preview). It needs Dictation turned on.
- **Bark 3.0** (English, a 202 MB download, macOS 15 or later) runs on the Neural Engine: about 0.2 s per phrase, cooler than Whisper, and more accurate on meetings. After the download it prepares itself for your Mac once, which takes a few minutes; Broski uses Whisper or Apple's dictation meanwhile. A cleanup pass drops "um", snaps near-misses to your project names and punctuates.
- **Whisper** (large-v3-turbo, about 570 MB, Metal) handles every other language, is primed with your project names, and takes over whenever Bark can't run.

Download them in Settings › Voice. **Speech engine** picks between them: Automatic (the default) uses Bark for English once it's downloaded, and Whisper otherwise. The models are kept in `~/Library/Application Support/Broski/models/`. Bark's files are pinned to one published commit, and each is checked against its size and SHA-256 when it downloads.

On the iPhone, Bark needs iOS 18; see [The iPhone app](iphone.md).

## Where your files live

**Your Broski folder** holds everything Broski knows: notes, conversations, memory, decisions, project pages, the files you share, and settings. It's `~/Broski` by default. To use another folder (iCloud Drive, Dropbox, a Git repository), go to Settings › General › **Notes folder** › Choose. An empty folder gets your notes moved into it; a folder that already has Broski notes is used as it is. Broski restarts in the new place.

To share notes with the iPhone app, Settings › General › **Sync with iPhone** moves `~/Broski` into iCloud Drive › Broski (`~/Library/Mobile Documents/com~apple~CloudDocs/Broski`). Nothing is deleted.

**Project folders** are where your code lives. Add them in Settings › Projects. Each folder inside becomes a project you can name, and Broski only reads them.

**App data** stays on this Mac in `~/Library/Application Support/Broski`: your keys (`secrets.json`), the voice models, and earlier versions kept by `scripts/install-mac.sh`.

[Privacy](privacy.md) lists every file and what's in it. [Architecture](architecture.md) has the folder layout.

## Updating

Download the new release and replace the app in Applications. Your notes, settings and keys stay where they are. If you build from source, `scripts/install-mac.sh` keeps the previous version, and `scripts/rollback-mac.sh` puts it back.

## Uninstalling

1. Quit Broski from its menu.
2. Delete it from Applications.
3. Delete your Broski folder if you don't want your notes anymore.
4. Delete `~/Library/Application Support/Broski` to remove your keys and the voice models.

## Next

- [Talking to Broski](talking.md): what to say, and where notes go.
- [Choosing your AI](models.md): providers, roles and spending.
- [Troubleshooting](troubleshooting.md): when the mic hears nothing or a shortcut doesn't fire.
