#!/bin/bash
# Everything CI runs, on your Mac: secret scan, build, unit tests, self-tests.
#   scripts/ci.sh          the Swift package (Mac app, BroskiCore, tools)
#   scripts/ci.sh --ios    also builds the iPhone app, unsigned
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
step() { printf '\n== %s\n' "$1"; }

step "Secret scan"
scripts/check-secrets.sh

step "Build"
swift build

step "Unit tests"
swift test

step "Self-tests"
swift run BroskiSelfTest

if [[ "${1:-}" == "--ios" ]]; then
  step "iPhone app (unsigned)"
  [[ -f iOS/Local.env ]] && source iOS/Local.env
  export BROSKI_BUNDLE_ID="${BROSKI_BUNDLE_ID:-com.example.broski}" BROSKI_TEAM_ID="${BROSKI_TEAM_ID:-}"
  (cd iOS && xcodegen generate --quiet)
  xcodebuild -project iOS/BroskiPhone.xcodeproj -scheme BroskiPhone -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath build/ci-ios CODE_SIGNING_ALLOWED=NO -quiet build
fi

step "All green"
