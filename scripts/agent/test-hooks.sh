#!/bin/bash
# Tests for the guardrails: each case is what a hook is given and what it must decide. Part of scripts/ci.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
ROOT="$PWD"
agent="$ROOT/scripts/agent"
export BROSKI_FAKE_BUILDS=""
count=0
failed=0

check() {
  count=$((count + 1))
  if [[ "$1" != "$2" ]]; then
    failed=$((failed + 1))
    printf 'FAIL  %s\n      wanted %s, got %s\n' "$3" "$1" "$2"
  fi
}
decision() { jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null | grep . || echo allow; }

bash_case() {
  local got
  got="$(jq -nc --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}' | "$agent/guard-bash.sh" | decision)"
  check "$1" "$got" "bash: $2"
}
edit_case() {
  local got
  got="$(jq -nc --arg p "$2" --arg cwd "$ROOT" '{tool_name: "Edit", cwd: $cwd, tool_input: {file_path: $p}}' | "$agent/guard-edit.sh" | decision)"
  check "$1" "$got" "edit: $2"
}

# Everyday work goes through.
bash_case allow 'ls -la'
bash_case allow 'git status && git diff --stat'
bash_case allow 'git push origin main'
bash_case allow 'git checkout -b better-settings'
bash_case allow 'git restore --staged Sources/BroskiCore/Models.swift'
bash_case allow 'git config core.hooksPath .githooks'
bash_case allow 'grep -rn "\.env" Sources'
bash_case allow "find . -name '*.db' -maxdepth 2"
bash_case allow 'cat iOS/Local.env.example'
bash_case allow 'tail -50 ~/Library/Mobile\ Documents/com~apple~CloudDocs/Broski/.broski/broski.log'
bash_case allow 'git commit -m "Never read .env or tracker.db; git push --force is blocked"'
bash_case allow $'git commit -F - <<\'EOF\'\nThe hooks deny cat .env and rm -rf /Applications/Broski.app\nEOF'
bash_case allow 'swift build'
bash_case allow 'scripts/ci.sh --ios'

# Secrets and private data.
bash_case deny 'cat .env'
bash_case deny 'head -5 server/.env.local'
bash_case deny "sqlite3 data/tracker.db 'select 1'"
bash_case deny 'cat iOS/Local.env'
bash_case deny 'cat ~/Library/Application\ Support/Broski/secrets.json'
bash_case deny 'security find-generic-password -s broski -w'
bash_case deny 'sudo rm -rf /tmp/x'

# History on GitHub and the commit hooks.
bash_case deny 'git push --force origin main'
bash_case deny 'git push origin main -f'
bash_case deny 'git push --force-with-lease'
bash_case deny 'git push origin +main'
bash_case deny 'git push origin :old-branch'
bash_case deny 'git commit --no-verify -m "quick"'
bash_case deny 'git commit -n -m "quick"'
bash_case deny 'git config core.hooksPath /dev/null'
bash_case deny 'git -c core.hooksPath=/dev/null commit -m x'

# Work that's thrown away is the person's call.
bash_case ask 'git reset --hard HEAD~1'
bash_case ask 'git clean -fd'
bash_case ask 'git checkout -- Sources/Broski/Companion/HomeView.swift'
bash_case ask 'git stash drop'
bash_case ask 'git branch -D old-idea'
bash_case ask 'git rebase main'
bash_case ask 'git restore Sources/BroskiCore/Models.swift'

# The installed app and the real Broski folder.
bash_case deny 'rm -rf /Applications/Broski.app && ditto build/Broski.app /Applications/Broski.app'
bash_case deny 'ditto build/Broski.app /Applications/Broski.app'
bash_case ask 'pkill -x Broski'
bash_case ask 'rm -rf ~/Library/Mobile\ Documents/com~apple~CloudDocs/Broski/conversations'
bash_case ask 'echo "{}" > ~/Broski/config.json'
bash_case ask "sed -i '' 's/a/b/' ~/Broski/config.json"
bash_case ask 'defaults delete dev.broski.app'

# One build at a time.
export BROSKI_FAKE_BUILDS="4242 swift-build"
bash_case deny 'swift build'
bash_case deny 'swift test --filter ModelsTests'
bash_case deny 'scripts/ci.sh --ios'
bash_case deny 'cd iOS && xcodebuild -project BroskiPhone.xcodeproj build'
bash_case allow 'git status'
export BROSKI_FAKE_BUILDS=""

# Files agents don't change, and the guardrails a person approves.
edit_case deny 'iOS/Local.env'
edit_case deny "$ROOT/iOS/BroskiPhone.xcodeproj/project.pbxproj"
edit_case deny "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Broski/config.json"
edit_case deny "$HOME/Broski/memory/about-you.md"
edit_case deny "$HOME/Library/Application Support/Broski/secrets.json"
edit_case deny '/Applications/Broski.app/Contents/Info.plist'
edit_case deny "$ROOT/.env"
edit_case deny "$ROOT/tracker.db"
edit_case ask "$ROOT/.claude/settings.json"
edit_case ask "$ROOT/scripts/agent/lib.sh"
edit_case ask "$ROOT/.githooks/pre-commit"
edit_case allow "$ROOT/Sources/BroskiCore/Models.swift"
edit_case allow 'Tests/BroskiCoreTests/ModelsTests.swift'
edit_case allow "$ROOT/iOS/Local.env.example"
edit_case allow "$ROOT/AGENTS.md"

# The Stop hook and the commit check, in a throwaway repository.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/Sources"
cp -R "$agent" "$tmp/scripts/agent"
(
  cd "$tmp"
  git init -q && git config user.email t@example.com && git config user.name t
  echo 'let a = 1' > Sources/a.swift && echo '# Docs' > README.md
  git add -A && git commit -qm init
)
stop() { echo "${1:-{\}}" | "$tmp/scripts/agent/check-green.sh" | jq -r '.decision // empty' | grep . || echo allow; }
commit_check() { (cd "$tmp" && scripts/agent/check-commit.sh >/dev/null 2>&1) && echo allow || echo refuse; }
green() { (cd "$tmp" && source scripts/agent/lib.sh && record_green "$(code_hash)" test); }

check allow "$(stop)" "stop: nothing changed"
echo 'let a = 2' > "$tmp/Sources/a.swift"
check block "$(stop)" "stop: code changed, never tested"
check allow "$(stop '{"stop_hook_active": true}')" "stop: sent back once already"
(cd "$tmp" && git add Sources/a.swift)
check refuse "$(commit_check)" "commit: untested code"
green
check allow "$(stop)" "stop: code green"
check allow "$(commit_check)" "commit: green code"
echo '# More docs' >> "$tmp/README.md"
check allow "$(stop)" "stop: only docs changed after the green run"
echo 'let b = 3' > "$tmp/Sources/b.swift"
check block "$(stop)" "stop: a new file after the green run"
git -C "$tmp" reset -q && git -C "$tmp" add README.md
check allow "$(commit_check)" "commit: docs only, with untested code left unstaged"

if [[ $failed -eq 0 ]]; then
  echo "Guardrails: all $count checks passed."
else
  echo "Guardrails: $failed of $count checks failed."
  exit 1
fi
