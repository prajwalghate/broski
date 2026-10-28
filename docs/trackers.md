# Projects and trackers

Broski keeps one view over all your projects: your notes about each one, and each project's own tracker, read where it lives. This page covers where projects come from, how trackers are read, and how to onboard a project so Broski reads its tracker correctly.

## Where projects come from

- **Your project folders.** Every folder inside the folders you add in Settings › Projects (like `~/Developer`) is a project you can name.
- **Your Broski folder.** Every folder in `projects/` is a project, whether or not it has code.
- **`projects.json`** in your Broski folder records each project's real name, its code folders, its trackers and the names it used to have, so "the old name" still finds it.

### New projects by talking

Describe something new in the conversation and Broski proposes a project. One tap on **Create project** sets up:

- its folder in `projects/<id>/`, and an entry in `projects.json`;
- a tracker Broski keeps, with the sections of the packs that fit;
- a first note with the summary, first goals and open questions;
- setup drafts in `projects/<id>/setup/`: `CLAUDE.md`, `command-center.json`, `prompts/` and `agents/`, for Claude Code to apply to a repository later.

Repositories are never touched.

"connect ~/code/recipe-box" ties a code folder to the current project. Broski suggests packs from the files at its top (a `package.json` suggests web, a `foundry.toml` web3, a `project.yml` or `.xcodeproj` mobile, `evals/` or `prompts/` ai) and, if it finds a tracker there, reads it in place, read-only.

### Packs

A pack is what a kind of project adds to its tracker and command center, as data: sections and widgets. The built-in packs are core (every project), web, web3, ai, mobile and personal. Say "new pack: game dev" (or "make a pack for …") and the deep model drafts the sections and widgets that kind of project needs into `packs/<id>.json`; with no model, you get a template to fill in. A new pack never replaces one that's there or a built-in one; edit the file to change it.

### The command center

Each project's **Command center** tab in the dashboard has a tile per widget, from `setup/command-center.json` (or, for a connected repository, from core and the packs its folders suggest). Tiles are filled from what Broski knows: open todos and bugs, standing decisions with their dates, the next open milestone, and the newest records in a pack's tracker section. A widget with nothing to read says so rather than showing made-up numbers.

## Trackers, read in place

Broski reads each project's own tracker where it lives, and never copies it or writes to it. For example, it reads a command center from a pinned `main` commit, a register of items, a `WORK-BOARD.md`, or plain docs.

- **Read-only, always.** Broski never writes into a project's repository or runs its code.
- **Git plumbing only.** When a tracker is read at a git ref, Broski uses `rev-parse`, `ls-tree` and `cat-file`, so a sync in the middle of a read can't give a half-updated state and uncommitted edits are left out. It never fetches, pulls, pushes or makes worktrees. Otherwise it reads the working tree.
- **Only what it needs.** Markdown, JSON, JSONL and TSV files up to 4 MB. Never `.env*`, `*.db`, `*.sqlite`, `*.pem`, `*.key`, `*.p12` or `secrets.json`, whatever a manifest says, and never folders like `node_modules`, `.git` or build output.
- **The same sections everywhere.** Every tracker maps onto the same core sections (ship, launch, ops, decisions, threads, findings), plus a project layer for what's unique to it (protocol parameters, backtests, courses).
- **Live state stays live.** Step readiness, prices and health come only from the tracker's own board, with the time they were read. When the board is down, Broski says the state is unknown instead of guessing.

### How a tracker's shape is known

A manifest says how to read a tracker. Broski uses the first it finds:

1. An overlay in your Broski folder: `trackers/<id>.broski.json`. A project with its own tracker shape keeps its manifest here, not in Broski's code.
2. A `broski.json` inside the tracker.
3. A preset picked from what's in the folder: a register of items, a `WORK-BOARD.md`, a tracker made from Broski's template, or generic markdown for any repository.

To start an overlay from the manifest Broski uses today, export it (all on one line):

```bash
/Applications/Broski.app/Contents/MacOS/Broski --diagnose /dev/null /tmp/report.txt --export-manifest ~/code/recipe-box recipe-box ~/Desktop/recipe-box.broski.json
```

### It stays current

Every read checks for drift: files no mapping reads, mappings that find nothing, status words nobody mapped, and new threads. The Tracker tab says so, and **Ask the threads** asks only about what changed.

Every change Broski sees between reads (findings opened or closed, decisions made, steps attested) goes into a per-project change stream, `projects/<p>/stream.<device>.jsonl` (each device writes its own; the shared `stream.jsonl` older versions wrote is still read). Claude Code reads it with `changes_since`, and automations act on it.

### Waiting on you

"What's waiting on me" needs to know which names your trackers use for you. List them in `config.json` as `ownerAliases` (for example `["sam", "founder"]`).

## A tracker Broski keeps

A project with no tracker gets **Create a Broski tracker** (Tracker › Onboard). It's plain markdown under `projects/<p>/tracker/` that threads, people and Broski all edit:

```
TRACKER.md          what the project is, and how the tracker is laid out
VISION.md
ids.tsv             every item id
ship/PLAN.md        milestones, with exit criteria; ship/releases/ one file per release
launch/GO-LIVE.md   go-live steps: "- [ ] L-1 What — owner"
ops/                runbooks/, incidents/, journal/
decisions/          one file per decision (DEC-n)
items/              bugs, tasks, risks, findings and ideas, one file each
threads/THREADS.md  who works on what
layers/             what doesn't fit the sections above, one folder per pack section
```

Broski edits only trackers it keeps (the **New** and status buttons on the Tracker tab), and so can Claude Code through MCP (`tracker_add`, `tracker_set_status`). This is the only kind of tracker Broski ever writes to.

## Onboard a project

Onboarding asks a project's threads (its Claude Code sessions) where everything lives, so Broski can draft how to read that tracker. Every answer must cite a real file, commit, record or transcript.

1. Dashboard › the project › **Tracker** › **Onboard** › **Start a run**. Or from Terminal:

   ```bash
   /Applications/Broski.app/Contents/MacOS/Broski --start-onboarding "My Project"
   ```

2. For each thread, **Copy command** and paste it in Terminal. It forks that thread's newest Claude Code session and asks it its questions. The thread reads only. It writes its answers into the run folder and checks them itself.
3. **Check answers.** Every evidence ref is verified: the file exists and contains the quote, the commit exists and its message contains the quote, the record id exists, the transcript exists, or the glob finds nothing for a claimed gap. Paths outside the repository and secret files are refused.

   ```bash
   /Applications/Broski.app/Contents/MacOS/Broski --check-onboarding "<run folder>"
   ```

4. **Draft manifest**, review it, then **Approve draft**. Broski reads the tracker with it from then on, and keeps the previous one beside it (`trackers/<id>.broski.previous.json`).

When the tracker drifts later, a delta run asks only about what changed:

```bash
/Applications/Broski.app/Contents/MacOS/Broski --start-onboarding "My Project" --delta
```

Other commands: `--onboarding-health <project>` reports drift and stale answers, `--assemble-onboarding <run folder>` writes the draft manifest, and `--new-tracker <project>` creates a Broski tracker.

## What's kept in your Broski folder

```
projects.json                       every project: real name, code folders, trackers, earlier names
trackers/<id>.broski.json           how to read a tracker (written only when you approve an onboarding draft)
trackers/<id>.broski.draft.json     a draft waiting for your review
trackers/state/<id>.json            what a tracker held at its last read, to tell what changed
projects/<p>/tracker/               a tracker Broski keeps, for projects that have none
projects/<p>/stream.<device>.jsonl  what changed in the project's trackers, read after read
projects/<p>/onboarding/<run>/      a run's questions, prompts, the threads' answers and CHECK.md
packs/<id>.json                     your own packs
```
