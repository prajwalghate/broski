#!/bin/bash
# Builds the iPhone app and installs it on the connected iPhone.
#   ./scripts/phone.sh            build + install + launch
#   ./scripts/phone.sh --build    build only
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Your bundle ID and Apple team: iOS/Local.env (copy iOS/Local.env.example; it's never committed).
[[ -f iOS/Local.env ]] && source iOS/Local.env
: "${BROSKI_BUNDLE_ID:?Set BROSKI_BUNDLE_ID in iOS/Local.env (see iOS/Local.env.example)}"
: "${BROSKI_TEAM_ID:?Set BROSKI_TEAM_ID in iOS/Local.env (see iOS/Local.env.example)}"
export BROSKI_BUNDLE_ID BROSKI_TEAM_ID

# The connected iPhone: CoreDevice id (for installing) and hardware UDID (for signing, which registers it with your team).
JSON=$(mktemp)
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
read -r DEVICE UDID < <(python3 - "$JSON" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1])).get("result", {}).get("devices", [])
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") == "iPhone" and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(d["identifier"], hw.get("udid", "")); break
else:
    print("", "")
PY
)
rm -f "$JSON"
[[ -z "$UDID" ]] && { echo "No iPhone connected (cable, unlocked, trusted)."; exit 1; }

(cd iOS && xcodegen generate --quiet)
xcodebuild -project iOS/BroskiPhone.xcodeproj -scheme BroskiPhone -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/phone \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet build
APP=build/phone/Build/Products/Debug-iphoneos/Broski.app
echo "Built $APP"
[[ "${1:-}" == "--build" ]] && exit 0

xcrun devicectl device install app --device "$DEVICE" "$APP" | tail -2
xcrun devicectl device process launch --device "$DEVICE" "$BROSKI_BUNDLE_ID" 2>&1 | tail -2 || true
