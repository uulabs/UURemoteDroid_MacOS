#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${REMOTEDROID_BUILD_DIR:-$ROOT/.build}"
APP="$ROOT/dist/RemoteDroid.app"
BUNDLE="$APP/Contents"
PLIST="$ROOT/Support/Info.plist"

if [[ ! -f "$ROOT/Resources/scrcpy-server-v5.0.1" ]]; then
  echo "Missing Resources/scrcpy-server-v5.0.1" >&2
  exit 1
fi
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "Missing Resources/AppIcon.icns; run scripts/make-icon.py" >&2
  exit 1
fi

echo "Building release into $SCRATCH"
swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH"

BIN="$SCRATCH/out/Products/release/RemoteDroid"
if [[ ! -x "$BIN" ]]; then
  BIN="$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)/RemoteDroid"
fi
if [[ ! -x "$BIN" ]]; then
  echo "Release executable not found" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"
cp "$BIN" "$BUNDLE/MacOS/RemoteDroid"
chmod +x "$BUNDLE/MacOS/RemoteDroid"
cp "$PLIST" "$BUNDLE/Info.plist"
printf 'APPL????' > "$BUNDLE/PkgInfo"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Resources/AppIcon.icns"
cp "$ROOT/Resources/scrcpy-server-v5.0.1" "$BUNDLE/Resources/scrcpy-server-v5.0.1"
cp "$ROOT/Resources/SCRCPY-LICENSE.txt" "$BUNDLE/Resources/SCRCPY-LICENSE.txt"

plutil -lint "$BUNDLE/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"
