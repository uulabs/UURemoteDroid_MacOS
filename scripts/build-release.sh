#!/bin/bash
# Builds and verifies the GitHub release assets:
#   UU-RemoteDroid-<version>.zip (+ .sha256)  consumed by the in-app updater
#   UU-RemoteDroid-<version>.dmg (+ .sha256)  for first-time installation
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
TEAM_ID="V726L7NR7H"
BUNDLE_ID="au.com.uulabs.remotedroid"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/Support/Info.plist")"
APP="$DIST/UU RemoteDroid.app"
ZIP="$DIST/UU-RemoteDroid-$VERSION.zip"
DMG="$DIST/UU-RemoteDroid-$VERSION.dmg"

"$ROOT/scripts/build-app.sh"

/usr/bin/codesign --verify --deep --strict "$APP"
DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
if ! grep -q "TeamIdentifier=$TEAM_ID" <<<"$DETAILS" || ! grep -q "Identifier=$BUNDLE_ID" <<<"$DETAILS"; then
  echo "Release refused: the app is not signed with team $TEAM_ID as $BUNDLE_ID" >&2
  exit 1
fi
BUILT_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
[[ "$BUILT_VERSION" == "$VERSION" ]] || { echo "Version mismatch: $BUILT_VERSION vs $VERSION" >&2; exit 1; }

# Keep the bundle as the top-level item in the update archive.
rm -f "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
"$ROOT/scripts/package-dmg.sh" "$DMG"
(cd "$DIST" && /usr/bin/shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
(cd "$DIST" && /usr/bin/shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "Release assets for $VERSION:"
ls -lh "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256"
