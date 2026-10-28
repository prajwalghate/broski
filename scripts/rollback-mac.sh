#!/bin/bash
# Puts a previous Broski back: one that scripts/install-mac.sh kept in ~/Library/Application Support/Broski/Previous.
#   scripts/rollback-mac.sh           the most recent one
#   scripts/rollback-mac.sh 0.10.2    that version
#   scripts/rollback-mac.sh --list    what's kept
# The version it replaces is kept too, so you can go forward again the same way.
set -euo pipefail
DEST=/Applications/Broski.app
KEEP="$HOME/Library/Application Support/Broski/Previous"
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1/Contents/Info.plist" 2>/dev/null || true; }
gui_pids() { pgrep -f '/Broski\.app/Contents/MacOS/Broski$' || true; }

if [[ "${1:-}" == "--list" ]]; then
  ls -1t "$KEEP" 2>/dev/null | sed 's/\.app$//' || true
  exit 0
fi
current="$(plist "$DEST" CFBundleShortVersionString)-$(plist "$DEST" CFBundleVersion)"
pick="$(ls -1dt "$KEEP"/Broski-"${1:-}"*.app 2>/dev/null | grep -v -- "-$current.app$" | head -1 || true)"
[[ -n "$pick" ]] || { echo "No kept version${1:+ matching $1} in $KEEP." >&2; exit 1; }

if [[ -d "$DEST" ]]; then
  rm -rf "$KEEP/Broski-$current.app"
  ditto "$DEST" "$KEEP/Broski-$current.app"
fi
pids="$(gui_pids)"
if [[ -n "$pids" ]]; then
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do [[ -z "$(gui_pids)" ]] && break; sleep 0.2; done
  [[ -n "$(gui_pids)" ]] && kill -9 $(gui_pids) 2>/dev/null || true
fi
rm -rf "$DEST"
ditto "$pick" "$DEST"
open "$DEST"
echo "Back on Broski $(plist "$DEST" CFBundleShortVersionString) ($(plist "$DEST" CFBundleVersion)). The one it replaced is kept as Broski-$current."
