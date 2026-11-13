#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/RemoteDroid.app"
DMG="${1:-$ROOT/dist/RemoteDroid.dmg}"
STAGING="${REMOTEDROID_DMG_STAGING:-$ROOT/.build/dmg-staging}"

if [[ ! -d "$APP" ]]; then
  echo "Build the app first: scripts/build-app.sh" >&2
  exit 1
fi

# Refuse to clear a path that is not the dedicated staging directory.
case "$STAGING" in
  "$ROOT/.build/dmg-staging"|/Volumes/970P/*/Scratch/*) ;;
  *)
    echo "Refusing to replace unexpected staging path: $STAGING" >&2
    exit 1
    ;;
esac

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/RemoteDroid.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create \
  -volname "RemoteDroid" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "Created $DMG"
