#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${REMOTEDROID_BUILD_DIR:-$ROOT/.build}"
APP="$ROOT/dist/UU RemoteDroid.app"
BUNDLE="$APP/Contents"
PLIST="$ROOT/Support/Info.plist"

if [[ ! -f "$ROOT/Resources/scrcpy-server-v5.0.1" ]]; then
  echo "Missing Resources/scrcpy-server-v5.0.1" >&2
  exit 1
fi
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "Missing Resources/AppIcon.icns; run scripts/make-icon.sh" >&2
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
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$BUNDLE/Resources/THIRD_PARTY_NOTICES.md"

plutil -lint "$BUNDLE/Info.plist" >/dev/null

# Sign with a Developer ID if one is installed, otherwise the UULabs Apple
# Development certificate. The in-app updater only installs builds whose
# signature carries the UULabs Team ID, so ad-hoc signing is a last resort for
# local builds and is refused by scripts/build-release.sh.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk -F'"' '/Developer ID Application:/ {print $2; exit}')"
  if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | /usr/bin/awk -F'"' '/Apple Development:/ {print $2; exit}')"
  fi
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "warning: no signing identity found; signing ad hoc" >&2
  SIGN_IDENTITY="-"
fi
/usr/bin/codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP"
echo "Built $APP"
