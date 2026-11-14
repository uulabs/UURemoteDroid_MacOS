#!/bin/bash
# Builds Resources/AppIcon-1024.png and Resources/AppIcon.icns from
# Resources/AppIcon-source.webp (the supplied artwork).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${REMOTEDROID_BUILD_DIR:-$ROOT/.build}"
ICONSET="$SCRATCH/AppIcon.iconset"
MASTER="$ROOT/Resources/AppIcon-1024.png"

swift "$ROOT/scripts/import-icon.swift" "$ROOT/Resources/AppIcon-source.webp" "$MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Built $ROOT/Resources/AppIcon.icns"
