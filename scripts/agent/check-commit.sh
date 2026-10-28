#!/bin/bash
# Run by .githooks/pre-commit: a commit that changes code goes in only once that code has passed its tests (a green
# scripts/test.sh or scripts/ci.sh of the code exactly as it is now). Code the iPhone app builds (iOS/ and the shared
# BroskiCore) needs a green scripts/ci.sh --ios, which builds the iPhone app too. Docs and other files go straight in.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$BROSKI_ROOT"

[[ -z "$(git diff --cached --name-only -- "${CODE_PATHS[@]}")" ]] && exit 0
if ! code_green; then
  cat >&2 <<'EOF'
This commit changes code that hasn't passed its tests as it is now.
Run scripts/test.sh (or scripts/ci.sh, which also builds the iPhone app with --ios), then commit again.
EOF
  exit 1
fi
if [[ -n "$(git diff --cached --name-only -- iOS Sources/BroskiCore)" ]] && ! grep -q -- '--ios' "$GREEN_STAMP"; then
  cat >&2 <<'EOF'
This commit changes code the iPhone app builds (iOS/ or the shared BroskiCore), and its last green run didn't build
the iPhone app. Run scripts/ci.sh --ios, then commit again.
EOF
  exit 1
fi
exit 0
