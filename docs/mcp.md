# Claude Code and MCP

Broski includes a Model Context Protocol (MCP) server, so Claude Code, Claude Desktop or any other MCP client can read your notes, project pages, decisions and trackers while you work. Ask Claude Code "what's open in my Broski notes for this project?" or "what's waiting on me across my projects?".

The server is the Broski app itself, started with `--mcp`. It speaks JSON-RPC over standard input and output, one message per line, and calls no model.

## What it can and can't do

- It reads your Broski folder in place. It doesn't copy anything anywhere.
- It's read-only, with one exception: `tracker_add` and `tracker_set_status` add items to, or change an item's status in, a tracker Broski keeps for a project that has none of its own. They never write to a project's own tracker, never delete or overwrite anything, and are refused for local-only projects.
- Local-only projects are hidden from every tool: their notes, records, decisions, conversation turns and commit messages. The local-only list is read again on every call, so a project you just marked is hidden at once.
- It never reads the private vault.
- Long answers are cut at 40,000 characters, and call-note transcripts are left out unless asked for.
- Trackers are read again when the last read is more than two minutes old.

## Connect Claude Code

The easy way: Settings › Connections › **Connect** (Claude Code) in Broski. It runs Claude Code's own `claude mcp add` for you and replaces an older registration if Broski moved. Then, in Claude Code, `/mcp` lists "broski".

Or run it yourself in Terminal:

```bash
claude mcp add --scope user broski -- /Applications/Broski.app/Contents/MacOS/Broski --mcp
```

Move Broski to Applications and open it from there first. A copy that runs from a disk image or Downloads gets a temporary path, and the connection breaks when it changes.

## Connect Claude Desktop and other MCP clients

Settings › Connections › **Copy config** copies this entry. Paste it into the client's MCP servers list (for Claude Desktop, under `mcpServers` in `claude_desktop_config.json`):

```json
"broski": {
  "command": "/Applications/Broski.app/Contents/MacOS/Broski",
  "args": ["--mcp"]
}
```

If a tool answers "Can't read Broski's notes", macOS is stopping the app that runs the client from reading your Broski folder. Allow it in System Settings › Privacy & Security › Files and Folders.

## Tools

| Tool | What it returns |
|---|---|
| `list_projects` | Every project: real name, code folders, trackers, open counts per section, and its one-line summary |
| `get_project_page` | A project's living page (where it stands, bugs, todos, ideas, decisions, open questions, suggested actions), each line citing note ids, with when it was written |
| `search_notes` | The best matches across notes, session observations and tracker records, with ids and snippets |
| `get_note` | One note in full (or one session observation, with its screenshots), by id |
| `get_record` | One tracker record or note in full, by id |
| `list_open_items` | Open bugs, todos or ideas, highest priority first |
| `recent_notes` | Notes captured in the last few days, newest first |
| `tracker_query` | Records from a project's tracker, filtered by section, kind, status and owner |
| `waiting_on` | What's waiting on you across projects, plus unread messages between threads |
| `journal` | What changed: decisions, findings opened and closed, messages, notes and commits |
| `changes_since` | What changed in the trackers between Broski's reads, each with its record id |
| `tracker_health` | Whether Broski's map of a tracker still fits it (drift) |
| `check_onboarding` | An onboarding run's answers, with every piece of evidence checked |
| `search_conversations` | What you and Broski said in the conversation, on every device |
| `decisions` | Decisions you saved, with dates: the ones standing, and the ones a later decision replaced |
| `memory` | What Broski knows about you: the about-you file and what you asked it to remember |
| `tracker_add` | Adds a task, bug, risk, finding, idea or decision to a tracker Broski keeps. Writes. |
| `tracker_set_status` | Changes an item's status in a tracker Broski keeps. Writes. |

Note ids look like `2026-10-16-0452-login-bug`. Tracker record ids carry their tracker's id, like `recipe-box:DEC-14`. Live state, such as whether a launch step is ready, comes only from a tracker's own board; the tools say so rather than state it from the files.

Every tool is marked read-only for the client except the two that write, which are marked as not destructive.

## Protocol details

- Transport: standard input and output, one JSON-RPC object per line. Notifications get no reply.
- Protocol versions: 2025-11-25, 2025-06-18, 2025-03-26 and 2024-11-05. The server answers with the version the client asks for, or the newest.
- Capabilities: tools only.

[Trackers](trackers.md) explains how trackers are read, and [Privacy](privacy.md) what never leaves your device.
