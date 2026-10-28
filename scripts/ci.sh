#!/bin/bash
# Everything CI runs, on your Mac: secret scan, guardrail tests, the website, build, unit tests, self-tests, the chat check.
#   scripts/ci.sh          the Swift package (Mac app, BroskiCore, tools)
#   scripts/ci.sh --ios    also builds the iPhone app, unsigned
# A pass is recorded as a green run of the code as it is now (scripts/agent/lib.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/agent/lib.sh
use_xcode
step() { printf '\n== %s\n' "$1"; }

# One build at a time is for the 8 GB Mac; a CI runner may have Xcode's own background work going, and is ours alone.
if [[ -z "${GITHUB_ACTIONS:-}" ]] && builds="$(running_builds)"; then
  echo "Another build is running ($builds). One at a time on this Mac: wait for it, then run this again." >&2
  exit 1
fi
before="$(code_hash)"

step "Secret scan"
scripts/check-secrets.sh

step "Guardrails (agent and git hooks)"
scripts/agent/test-hooks.sh

step "Website (the builder's tests, then every page, link and structured data)"
scripts/site.sh

step "Build"
swift build

step "Unit tests"
swift test

step "Self-tests"
swift run BroskiSelfTest

step "Chat check (the real message box and conversation, off screen)"
report="$(mktemp -t broski-chat-check)"
if ! .build/debug/Broski --chat-check "$report" >/dev/null 2>&1; then cat "$report"; exit 1; fi
tail -1 "$report"

if [[ "${1:-}" == "--ios" ]]; then
  step "iPhone app (unsigned)"
  [[ -f iOS/Local.env ]] && source iOS/Local.env
  export BROSKI_BUNDLE_ID="${BROSKI_BUNDLE_ID:-com.example.broski}" BROSKI_TEAM_ID="${BROSKI_TEAM_ID:-}"
  (cd iOS && xcodegen generate --quiet)
  xcodebuild -project iOS/BroskiPhone.xcodeproj -scheme BroskiPhone -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath build/ci-ios CODE_SIGNING_ALLOWED=NO -quiet build
fi

record_green "$before" "scripts/ci.sh${1:+ $1}"
step "All green"
