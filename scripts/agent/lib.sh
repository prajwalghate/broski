#!/bin/bash
# Shared by the agent hooks (.claude/settings.json), the git hooks and the test scripts.
# A "green run" is scripts/test.sh (no filter) or scripts/ci.sh passing; it records a hash of the code it tested in
# .build/agent/green, so a hook can tell whether the code as it is now has passed.

BROSKI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GREEN_STAMP="$BROSKI_ROOT/.build/agent/green"

# What a green run vouches for. Ignored files (the generated Xcode project, iOS/Local.env) don't count.
CODE_PATHS=(Sources Tests iOS Package.swift Package.resolved)

# The commands that compile: on an 8 GB Mac two at once fail or overheat it.
BUILD_RE='(^|[;&|(`[:space:]])(swift[[:space:]]+(build|test|run)([[:space:]]|$)|xcodebuild([[:space:]]|$)|(\./)?scripts/(ci|test|build-app|phone|package|install-mac)\.sh)'

# Points the Swift tools at the full Xcode when there's one (the Command Line Tools can't build everything).
use_xcode() {
  if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  fi
}

# A hash of the code as it is in the working tree: tracked and untracked files, names and contents.
code_hash() {
  (cd "$BROSKI_ROOT" && git ls-files -z -co --exclude-standard -- "${CODE_PATHS[@]}" 2>/dev/null \
    | sort -z | xargs -0 shasum 2>/dev/null | shasum | cut -d' ' -f1)
}

# True when the code differs from the last commit (or there's code git doesn't know yet).
code_changed() {
  [[ -n "$(cd "$BROSKI_ROOT" && git status --porcelain -- "${CODE_PATHS[@]}" 2>/dev/null)" ]]
}

# True when the code as it is now has passed a green run.
code_green() {
  [[ -f "$GREEN_STAMP" && "$(cut -d' ' -f1 "$GREEN_STAMP")" == "$(code_hash)" ]]
}

# Records a green run of the code whose hash was $1 when the run started, unless it changed during the run.
record_green() {
  local before="$1" what="$2" after
  after="$(code_hash)"
  if [[ "$before" != "$after" ]]; then
    echo "The code changed while the tests ran, so this run isn't recorded as green. Run them again." >&2
    return 1
  fi
  mkdir -p "$(dirname "$GREEN_STAMP")"
  printf '%s %s %s\n' "$after" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$what" > "$GREEN_STAMP"
}

# The builds running now (pid and name), or nothing; true when there's one. Tests set BROSKI_FAKE_BUILDS.
running_builds() {
  if [[ -n "${BROSKI_FAKE_BUILDS+set}" ]]; then
    [[ -n "$BROSKI_FAKE_BUILDS" ]] && { echo "$BROSKI_FAKE_BUILDS"; return 0; }
    return 1
  fi
  local found
  found="$(pgrep -fl 'swift-build|swift-test|swift-run|xcodebuild' 2>/dev/null | grep -v -e pgrep -e 'scripts/agent' | head -3 | cut -c1-80)"
  [[ -n "$found" ]] && { echo "$found" | tr '\n' ';' | sed 's/;$//'; return 0; }
  return 1
}
