#!/bin/bash
# Stop hook (.claude/settings.json): an agent doesn't finish with code that hasn't passed its tests. When the code
# differs from the last green run, the agent is sent back once to run them (or to say plainly why it couldn't).
# Reads the hook's JSON on stdin.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

input="$(cat)"
# Sent back once already: let it stop, so a run that can't pass never loops.
[[ "$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)" == "true" ]] && exit 0
code_changed || exit 0
code_green && exit 0

reason="The code changed since its last green run. Run scripts/test.sh (every unit test) and fix what fails before you finish; after UI changes run scripts/ci.sh too (it drives the real chat views off screen). If you can't run them, say so plainly in your reply."
if builds="$(running_builds)"; then
  reason="The code changed since its last green run and a build is still going ($builds). Wait for it, check it passed, and say what it showed."
fi
jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
