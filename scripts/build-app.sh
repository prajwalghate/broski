#!/usr/bin/env bash
# Builds build/Broski.app from the Swift package. Needs only the Xcode Command Line Tools.
#   ./scripts/build-app.sh          build
#   ./scripts/build-app.sh --open   build, then (re)start Broski
#
# Signing:
#   BROSKI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"  sign for distribution
#                                                                         (hardened runtime, notarizable)
#   unset                                                                 ad-hoc signature, for you and friendly testers
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/agent/lib.sh
use_xcode
# The code this app is built from, so scripts/install-mac.sh installs only an app built from green code.
code="$(code_hash)"

swift build -c release --product Broski
BIN="$(swift build -c release --show-bin-path)/Broski"

APP=build/Broski.app
rm -rf "$APP" build/icon
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon
cp "$BIN" "$APP/Contents/MacOS/Broski"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :BroskiCodeHash string $code" "$APP/Contents/Info.plist"

# Local Whisper ships as a framework next to the binary; bundle it and point the app at it.
mkdir -p "$APP/Contents/Frameworks"
ditto "$(dirname "$BIN")/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Broski"

# The icon is drawn by BroskiArt.swift. Drop a PNG at assets/AppIcon.png to use your own art instead.
if [[ -f assets/AppIcon.png ]]; then
  ICONSET=build/icon/AppIcon.iconset
  mkdir -p "$ICONSET"
  W=$(sips -g pixelWidth assets/AppIcon.png | awk '/pixelWidth/ {print $2}')
  H=$(sips -g pixelHeight assets/AppIcon.png | awk '/pixelHeight/ {print $2}')
  SIDE=$(( W < H ? W : H ))
  sips --cropToHeightWidth "$SIDE" "$SIDE" assets/AppIcon.png --out build/icon/square.png >/dev/null
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" build/icon/square.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon/square.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
else
  "$BIN" --export-icons build/icon
fi
iconutil -c icns build/icon/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Sign the framework first, then the app (no --deep).
if [[ -n "${BROSKI_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$BROSKI_SIGN_IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Broski.entitlements \
    --sign "$BROSKI_SIGN_IDENTITY" "$APP"
else
  # Ad-hoc, with a designated requirement that only names the bundle ID, so macOS privacy
  # permissions (mic, speech, Documents) carry over between builds.
  codesign --force --sign - "$APP/Contents/Frameworks/whisper.framework"
  codesign --force --sign - --requirements '=designated => identifier "dev.broski.app"' "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"))"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x Broski 2>/dev/null && sleep 0.5 || true
  open "$APP"
fi
