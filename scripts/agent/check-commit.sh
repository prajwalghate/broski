#!/bin/bash
# Run by .githooks/pre-commit: a commit that changes code goes in only once that code has passed its tests (a green
# scripts/test.sh or scripts/ci.sh of the code exactly as it is now). Commits of docs and other files go straight in.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$BROSKI_ROOT"

[[ -z "$(git diff --cached --name-only -- "${CODE_PATHS[@]}")" ]] && exit 0
code_green && exit 0

cat >&2 <<'EOF'
This commit changes code that hasn't passed its tests as it is now.
Run scripts/test.sh (or scripts/ci.sh, which also builds the iPhone app with --ios), then commit again.
EOF
exit 1
