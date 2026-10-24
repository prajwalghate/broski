#!/usr/bin/env bash
# Builds a beta release: dist/Broski-<version>.dmg and dist/Broski-<version>.zip.
#
#   ./scripts/package.sh
#
# Without an Apple Developer ID, the build is ad-hoc signed: testers have to approve it once in
# System Settings › Privacy & Security ("Open Anyway"). See BETA.md.
#
# With a Developer ID ($99/year Apple Developer Program), set these and it signs and notarizes,
# so it opens like any downloaded app:
#   BROSKI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   BROSKI_NOTARY_PROFILE=broski   # made once with: xcrun notarytool store-credentials broski
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product BroskiSelfTest
"$(swift build --show-bin-path)/BroskiSelfTest" >/dev/null || { echo "Self-test failed; not packaging." >&2; exit 1; }

./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Broski.app/Contents/Info.plist)
NAME="Broski-$VERSION"
mkdir -p dist
rm -f "dist/$NAME.dmg" "dist/$NAME.zip"

# Disk image with the usual drag-to-Applications layout.
STAGE=build/dmg
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R build/Broski.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp BETA.md "$STAGE/Read me first.md"
hdiutil create -volname "Broski $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/$NAME.dmg" >/dev/null

if [[ -n "${BROSKI_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$BROSKI_SIGN_IDENTITY" "dist/$NAME.dmg"
  if [[ -n "${BROSKI_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "dist/$NAME.dmg" --keychain-profile "$BROSKI_NOTARY_PROFILE" --wait
    xcrun stapler staple "dist/$NAME.dmg"
    xcrun stapler staple build/Broski.app
  fi
fi

ditto -c -k --keepParent build/Broski.app "dist/$NAME.zip"
shasum -a 256 "dist/$NAME.dmg" "dist/$NAME.zip"
echo "Packaged dist/$NAME.dmg and dist/$NAME.zip"
