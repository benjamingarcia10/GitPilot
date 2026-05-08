#!/bin/bash
# Build a proper .app bundle so notification action buttons work.
# UNUserNotification requires a bundled, code-signed app to register categories.
#
# Note the explicit /bin/bash shebang (not /usr/bin/env bash): if PATH leads
# with an Intel-only bash (e.g. an x86_64 Homebrew at /usr/local/bin/bash),
# `env bash` runs the script under Rosetta, which then spawns swift as x86_64,
# which silently builds an x86_64 binary. /bin/bash is the universal system
# bash and runs natively on the host arch.
#
# Inputs (env or args):
#   VERSION            CFBundleShortVersionString to embed (default 0.1.0)
#   BUILD              CFBundleVersion to embed             (default 1)
#   TARGET_ARCH        Architecture to build for           (default arm64)
#                      We only ship arm64 today (Apple Silicon team). Override
#                      to e.g. x86_64 for an Intel build, or set to "universal"
#                      to fat-binary both via lipo (not yet implemented).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TARGET_ARCH="${TARGET_ARCH:-arm64}"

APP_NAME="GitPilot"
BUNDLE_ID="com.affirm.gitpilot"
APP_DIR="$ROOT/$APP_NAME.app"
SPARKLE_PUBLIC_KEY_FILE="$ROOT/scripts/sparkle-public-key.txt"
SPARKLE_FEED_URL="https://raw.githubusercontent.com/benjamingarcia10/GitPilot/main/appcast.xml"

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
# TARGET_ARCH is set above (before the re-exec). After re-exec, uname -m
# matches TARGET_ARCH; this remains a guard against an explicit override that
# disagrees with the host (e.g. TARGET_ARCH=x86_64 on an arm64 machine).
HOST_ARCH="$(uname -m)"
if [[ "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
  echo "Refusing to build: TARGET_ARCH=$TARGET_ARCH but host is $HOST_ARCH." >&2
  echo "Override TARGET_ARCH=$HOST_ARCH explicitly if you really want a foreign-arch bundle." >&2
  exit 1
fi

echo "==> swift build --arch $TARGET_ARCH -c release"
swift build --arch "$TARGET_ARCH" -c release

# Resolve the build path explicitly via --show-bin-path (with the same --arch)
# so we never read from `.build/release`, which is a symlink that can be
# pointed at any arch tree by a previous foreign-arch invocation.
BUILD_BIN_DIR="$(swift build --arch "$TARGET_ARCH" -c release --show-bin-path)"
BIN_PATH="$BUILD_BIN_DIR/gitpilot"
SPARKLE_FRAMEWORK_SRC="$BUILD_BIN_DIR/Sparkle.framework"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Built binary not found at $BIN_PATH" >&2
  exit 1
fi
if [[ ! -d "$SPARKLE_FRAMEWORK_SRC" ]]; then
  echo "Sparkle.framework not found at $SPARKLE_FRAMEWORK_SRC — SPM artifacts moved?" >&2
  exit 1
fi

# Belt-and-suspenders: confirm the produced binary is actually the arch we
# asked for. `file -b` prints e.g. "Mach-O 64-bit executable arm64".
ACTUAL_ARCH="$(file -b "$BIN_PATH" | grep -oE 'arm64|x86_64' | head -1)"
if [[ "$ACTUAL_ARCH" != "$TARGET_ARCH" ]]; then
  echo "Built binary is $ACTUAL_ARCH but expected $TARGET_ARCH at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_NAME.app v$VERSION ($BUILD)"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Frameworks"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Embed Sparkle.framework. We copy the framework SPM linked against (rather
# than re-downloading) so the embedded version is guaranteed to match what the
# binary expects. ditto preserves symlinks inside the versioned bundle —
# Versions/A → Versions/Current → ... — which cp -R would break, invalidating
# the framework's signature.
echo "==> Embedding Sparkle.framework"
ditto "$SPARKLE_FRAMEWORK_SRC" "$APP_DIR/Contents/Frameworks/Sparkle.framework"

# Generate icon if it doesn't already exist. (Re-run scripts/generate-icon.sh
# manually to refresh the design.)
if [[ ! -f "$ROOT/AppIcon.icns" ]]; then
  echo "==> Generating AppIcon.icns"
  "$ROOT/scripts/generate-icon.sh"
fi
cp "$ROOT/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Sparkle Info.plist keys. We always emit SUFeedURL + SUEnableAutomaticChecks;
# SUPublicEDKey is only emitted if scripts/sparkle-public-key.txt exists. That
# lets a fresh checkout still build (you'll just get a runtime warning at first
# update check until you run scripts/sparkle-keys.sh).
SPARKLE_PUBLIC_KEY=""
if [[ -f "$SPARKLE_PUBLIC_KEY_FILE" ]]; then
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < "$SPARKLE_PUBLIC_KEY_FILE")"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>          <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>   <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>      <string>AppIcon</string>
    <key>CFBundlePackageType</key>   <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>       <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key>           <true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>SUFeedURL</key>             <string>$SPARKLE_FEED_URL</string>
    <key>SUEnableAutomaticChecks</key><true/>
$( [[ -n "$SPARKLE_PUBLIC_KEY" ]] && printf '    <key>SUPublicEDKey</key>        <string>%s</string>\n' "$SPARKLE_PUBLIC_KEY" )
</dict>
</plist>
PLIST

if [[ -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "    NOTE: scripts/sparkle-public-key.txt missing — Sparkle public key not embedded." >&2
    echo "          Run scripts/sparkle-keys.sh once to generate keys before cutting a release." >&2
fi

# Code signing: strictly innermost-first, one item per `codesign` call. Each
# inner seal must finish before the next layer is sealed, otherwise the
# enclosing seal can be computed against an unsigned-or-stale interior.
#
# We deliberately DO NOT pass --options=runtime here. The Hardened Runtime
# flag is only meaningful for notarized Developer-ID-signed apps; combining
# it with ad-hoc signing enables library validation, which then refuses to
# load Sparkle.framework with the cryptic error "mapping process and mapped
# file (non-platform) have different Team IDs". Without Hardened Runtime,
# the ad-hoc-signed framework loads cleanly. If you ever switch to a paid
# Developer ID + notarization, re-add --options=runtime everywhere.
#
# Sparkle is particularly picky here:
#   - XPCServices/{Downloader,Installer}.xpc — sandboxed helpers used during
#     update install. Sparkle's signing docs list these first.
#   - Autoupdate — the relauncher binary that swaps the bundle.
#   - Updater.app — the user-facing "downloading…" progress UI.
#   - Sparkle.framework outer seal — must come AFTER all of the above.
#   - Main executable.
#   - .app outer seal.
echo "==> Code signing (ad-hoc)"
SPARKLE_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"

# Resolve the canonical inner-version directory rather than hardcoding the
# letter. Sparkle 2.x currently ships "Versions/B", but that's an internal
# layout detail not part of any API contract — using `Versions/Current` lets
# this script keep working if Sparkle ever bumps to "Versions/C".
SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/Current"
XPC_SERVICES="$SPARKLE_VERSION_DIR/XPCServices"

# XPC services are present when Sparkle ships sandboxed-helper builds. Guard
# in case a future Sparkle drop omits them.
if [[ -d "$XPC_SERVICES/Installer.xpc" ]]; then
    codesign --force --sign - "$XPC_SERVICES/Installer.xpc"
fi
if [[ -d "$XPC_SERVICES/Downloader.xpc" ]]; then
    codesign --force --sign - "$XPC_SERVICES/Downloader.xpc"
fi

codesign --force --sign - "$SPARKLE_VERSION_DIR/Autoupdate"
codesign --force --sign - "$SPARKLE_VERSION_DIR/Updater.app"
codesign --force --sign - "$SPARKLE_FRAMEWORK"
codesign --force --sign - "$APP_DIR/Contents/MacOS/$APP_NAME"
codesign --force --sign - "$APP_DIR"

# Verify the full nested signature chain. A failure here means Sparkle will
# reject the update on the user's machine ("update is improperly signed"),
# effectively bricking the release — so let `set -e` propagate the failure
# rather than swallowing it.
echo "==> Verifying signature chain"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Done: $APP_DIR"
echo "Run with: open '$APP_DIR'"
