#!/bin/bash
# SessionStart hook (.claude/settings.json): a few lines of where things stand, so an agent starts oriented.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$BROSKI_ROOT"

mac="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist 2>/dev/null)"
phone="$(awk '/MARKETING_VERSION/ {print $2; exit}' iOS/project.yml 2>/dev/null)"
if ! code_changed && [[ ! -f "$GREEN_STAMP" ]]; then
  state="code as committed (no green run recorded on this checkout yet)"
elif code_green; then
  state="code green ($(cut -d' ' -f2,3 "$GREEN_STAMP"))"
else
  state="code changed since its last green run"
fi
builds="$(running_builds || echo none)"

context="Broski: Mac ${mac:-?}, iPhone ${phone:-?} on $(git branch --show-current 2>/dev/null). ${state}. Builds running: ${builds}.
Work test-first (skill tdd): failing test, scripts/test.sh <Suite>, code, scripts/test.sh; scripts/ci.sh before a commit; skill ship to release. Read AGENTS.md before changing anything."
jq -nc --arg c "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
