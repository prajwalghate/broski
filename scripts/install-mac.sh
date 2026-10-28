#!/bin/bash
# Installs build/Broski.app over /Applications/Broski.app without risking the person's setup:
#   1. the build must be of green code (scripts/test.sh or scripts/ci.sh passed for exactly the code it was built from);
#   2. the new build runs the chat check off screen, then reads the real Broski folder without writing anything
#      (--check-folder), and must read at least as much of it as the installed version does;
#   3. the installed version is kept in ~/Library/Application Support/Broski/Previous (the last three);
#   4. Broski is quit, replaced and started; if the new version doesn't report that it started, the old one goes back.
#   scripts/install-mac.sh            install build/Broski.app
#   scripts/install-mac.sh --force    skip the green check (a build checked some other way)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/agent/lib.sh

NEW=build/Broski.app
DEST=/Applications/Broski.app
KEEP="$HOME/Library/Application Support/Broski/Previous"
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null || true; }
fail() { printf 'Not installed: %s\n' "$*" >&2; exit 1; }
gui_pids() { pgrep -f '/Broski\.app/Contents/MacOS/Broski$' || true; }

[[ -d "$NEW" ]] || fail "there's no $NEW. Run scripts/build-app.sh first."
new_version="$(plist "$NEW" CFBundleShortVersionString) ($(plist "$NEW" CFBundleVersion))"
if [[ "${1:-}" != "--force" ]]; then
  code_green || fail "the code isn't green as it is now. Run scripts/ci.sh, then scripts/build-app.sh, then this."
  [[ "$(plist "$NEW" BroskiCodeHash)" == "$(code_hash)" ]] \
    || fail "$NEW wasn't built from the code as it is now. Run scripts/build-app.sh again."
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Checking $new_version before installing…"
if ! "$NEW/Contents/MacOS/Broski" --chat-check "$work/chat.txt" >/dev/null 2>&1; then
  cat "$work/chat.txt" 2>/dev/null
  fail "the new build's chat check failed."
fi
# The installed version reads first (if it can), then the new one: data only grows in between.
old_report=""
if [[ -x "$DEST/Contents/MacOS/Broski" ]] && grep -qa -- '--check-folder' "$DEST/Contents/MacOS/Broski"; then
  "$DEST/Contents/MacOS/Broski" --check-folder "$work/old.json" >/dev/null 2>&1 && old_report="$work/old.json"
fi
if ! "$NEW/Contents/MacOS/Broski" --check-folder "$work/new.json" >/dev/null 2>&1; then
  jq -r '.problems[]?' "$work/new.json" 2>/dev/null
  fail "the new build couldn't read your Broski folder."
fi
jq -r '"Your Broski folder: " + ([.formats | to_entries[] | "\(.value.read) \(.key)"] | join(", "))' "$work/new.json"
if [[ -n "$old_report" ]]; then
  worse="$(jq -nr --slurpfile old "$old_report" --slurpfile new "$work/new.json" '
    $old[0].formats | to_entries[] | . as $o | ($new[0].formats[$o.key] // {read: 0, unreadable: 0}) as $n
    | select($n.read < $o.value.read or $n.unreadable > $o.value.unreadable)
    | "\($o.key): the installed version reads \($o.value.read) (\($o.value.unreadable) unreadable), the new one \($n.read) (\($n.unreadable) unreadable)"')"
  [[ -z "$worse" ]] || { echo "$worse"; fail "the new build reads less of your data than the installed one."; }
fi
log="$(jq -r '.root' "$work/new.json")/.broski/broski.log"

# Keep the installed version.
mkdir -p "$KEEP"
backup=""
if [[ -d "$DEST" ]]; then
  backup="$KEEP/Broski-$(plist "$DEST" CFBundleShortVersionString)-$(plist "$DEST" CFBundleVersion).app"
  rm -rf "$backup"
  ditto "$DEST" "$backup"
  ls -1dt "$KEEP"/Broski-*.app 2>/dev/null | tail -n +4 | while IFS= read -r old; do rm -rf "$old"; done
fi

quit_broski() {
  local pids
  pids="$(gui_pids)"
  [[ -z "$pids" ]] && return 0
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do [[ -z "$(gui_pids)" ]] && return 0; sleep 0.2; done
  kill -9 $(gui_pids) 2>/dev/null || true
}
# How many times the log says this version started from /Applications (grep -c prints 0 and fails on none).
started() {
  local count
  count="$(grep -c "Broski $(plist "$1" CFBundleShortVersionString) started from $DEST" "$log" 2>/dev/null)" || true
  echo "${count:-0}"
}

before="$(started "$NEW")"
quit_broski
rm -rf "$DEST"
ditto "$NEW" "$DEST"
open "$DEST"
for _ in $(seq 1 60); do
  [[ "$(started "$NEW")" -gt "$before" ]] && break
  sleep 0.5
done
sleep 3
if [[ "$(started "$NEW")" -gt "$before" && -n "$(gui_pids)" ]]; then
  echo "Installed Broski $new_version.${backup:+ The previous version is kept: scripts/rollback-mac.sh puts it back.}"
  exit 0
fi

echo "Broski $new_version didn't start properly." >&2
if [[ -n "$backup" ]]; then
  quit_broski
  rm -rf "$DEST"
  ditto "$backup" "$DEST"
  open "$DEST"
  fail "put the previous version back ($(basename "$backup" .app)). Check $log."
fi
fail "there was no previous version to put back. Check $log."
