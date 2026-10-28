@AGENTS.md

# Claude Code here

- **Hooks** (`.claude/settings.json`, scripts in `scripts/agent/`): a guard before every Bash command and file edit, a Stop check that the code you changed has passed `scripts/test.sh`, and a short status at session start. If a hook refuses something, read its reason and do what it says; don't look for a way around it.
- **Skills** (`.claude/skills/`): `tdd` before any behavior change or bug fix, `broski-ui` before touching a screen, `model-provider` before touching models or anything that sends text, `ship` to release, `diagnose` when the installed app misbehaves.
- **Subagents** (`.claude/agents/`): `reviewer` reads your diff against these rules before you commit; `ui-critic` reviews `--snapshot` screenshots. Subagents never build; only the main session does, one build at a time.
- **Verify before you say it's done**, and say plainly what you didn't verify.
