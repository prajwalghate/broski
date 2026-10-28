#!/bin/bash
# Unit tests (Swift Testing, Tests/BroskiCoreTests).
#   scripts/test.sh                       every test; a pass is recorded as a green run of the code as it is now
#   scripts/test.sh ChatBasicsTests ...   only these suites (type names, as regexes), for the red-green loop
# The agent hooks and the pre-commit hook only accept code that has had a green run (scripts/agent/lib.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/agent/lib.sh
use_xcode

if builds="$(running_builds)"; then
  echo "Another build is running ($builds). One at a time on this Mac: wait for it, then run this again." >&2
  exit 1
fi
if [[ $# -gt 0 ]]; then
  filter="$(IFS='|'; echo "$*")"
  exec swift test --filter "$filter"
fi
before="$(code_hash)"
swift test
record_green "$before" "scripts/test.sh"
echo "Green: every unit test passed."
