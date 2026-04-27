#!/usr/bin/env bash
# Build a proper .app bundle so notification action buttons work.
# UNUserNotification requires a bundled, code-signed app to register categories.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="GitPilot"
BUNDLE_ID="com.affirm.gitpilot"
APP_DIR="$ROOT/$APP_NAME.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/gitpilot"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>          <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>   <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>   <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>       <string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key>           <true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing"
codesign --force --sign - --deep "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "Run with: open '$APP_DIR'"
