#!/usr/bin/env bash
# Generates AppIcon.icns from a single 1024x1024 PNG.
# Uses macOS built-ins: sips for resizing, iconutil for icns packaging.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE_PNG="$ROOT/icon-1024.png"
ICONSET="$ROOT/AppIcon.iconset"
ICNS="$ROOT/AppIcon.icns"

echo "==> Rendering base PNG"
swift "$ROOT/scripts/render-icon.swift" "$BASE_PNG"

echo "==> Building iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16   16   "$BASE_PNG" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32   32   "$BASE_PNG" --out "$ICONSET/icon_16x16@2x.png"  >/dev/null
sips -z 32   32   "$BASE_PNG" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 64   64   "$BASE_PNG" --out "$ICONSET/icon_32x32@2x.png"  >/dev/null
sips -z 128  128  "$BASE_PNG" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256  256  "$BASE_PNG" --out "$ICONSET/icon_128x128@2x.png">/dev/null
sips -z 256  256  "$BASE_PNG" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512  512  "$BASE_PNG" --out "$ICONSET/icon_256x256@2x.png">/dev/null
sips -z 512  512  "$BASE_PNG" --out "$ICONSET/icon_512x512.png"   >/dev/null
cp "$BASE_PNG" "$ICONSET/icon_512x512@2x.png"

echo "==> Packing .icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

echo "==> Done: $ICNS"
