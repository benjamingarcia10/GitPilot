#!/bin/bash
# Package GitPilot for distribution to coworkers.
# Produces:
#   - GitPilot-<version>-<arch>.zip       — drag-into-/Applications artifact
#   - GitPilot-<version>-<arch>.zip.sha256 — checksum for verification
#
# The architecture suffix (arm64 today; could be x86_64 or universal in
# future) is in the filename so the appcast can offer the right artifact for
# the user's machine and so a teammate on a different arch can spot the
# mismatch before installing.
#
# Usage:
#   ./scripts/package.sh                # uses version from Info.plist
#   ./scripts/package.sh 0.2.0          # overrides version
#
# The bundle is ad-hoc code-signed. Recipients will see a Gatekeeper warning
# the first time they open it; they can bypass by right-clicking the .app and
# choosing "Open" from the context menu (rather than double-clicking). This is
# the standard "internal tool, no Apple Developer ID" tradeoff. If you want to
# avoid it, sign with a Developer ID Application cert and notarize via
# `xcrun notarytool submit`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="GitPilot"
APP_DIR="$ROOT/$APP_NAME.app"
DIST_DIR="$ROOT/dist"

# Version: positional arg > VERSION env > Info.plist (post-build) > "0.0.0-dev".
# Forwarded to build-app.sh via env so the rebuild produces the *correct*
# CFBundleShortVersionString and CFBundleVersion. Without this, CI was rebuilding
# with default 0.1.0/1 right after the build step had baked in the real values —
# producing a zip named v0.2.0 that contained a 0.1.0 bundle, which Sparkle would
# then offer as "an update available" forever.
VERSION="${VERSION:-${1:-}}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"

echo "==> Building bundle"
VERSION="$VERSION" BUILD="${BUILD:-}" TARGET_ARCH="$TARGET_ARCH" "$ROOT/scripts/build-app.sh" >/dev/null

if [[ -z "$VERSION" ]]; then
    if [[ -f "$APP_DIR/Contents/Info.plist" ]]; then
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo '')"
    fi
fi
VERSION="${VERSION:-0.0.0-dev}"

# Tag the zip with the architecture so an Intel Mac user receiving an arm64
# zip (or vice versa) sees it before installing. Sparkle's appcast doesn't
# multiplex by arch on its own; encoding it in the filename keeps the option
# open to ship multiple artifacts later if anyone joins the team on Intel.
echo "==> Packaging $APP_NAME v$VERSION ($TARGET_ARCH)"
mkdir -p "$DIST_DIR"
ZIP_NAME="$APP_NAME-$VERSION-$TARGET_ARCH.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

# Use ditto rather than `zip` so quarantine + extended attributes round-trip
# cleanly and the .app stays runnable on the receiving machine.
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

CHECKSUM="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "$CHECKSUM  $ZIP_NAME" > "$ZIP_PATH.sha256"

SIZE="$(du -h "$ZIP_PATH" | awk '{print $1}')"

echo
echo "==> Done"
echo "    File:    $ZIP_PATH ($SIZE)"
echo "    SHA-256: $CHECKSUM"
echo
echo "Send the zip + sha256 to coworkers along with these install steps:"
cat <<INSTRUCTIONS

  1. Verify (optional):  shasum -a 256 $ZIP_NAME
  2. Unzip:              unzip $ZIP_NAME
  3. Move to Applications: mv GitPilot.app /Applications/
  4. First launch:       System Settings → Privacy & Security → "Open Anyway"
                         next to GitPilot (Gatekeeper blocks ad-hoc-signed
                         apps once on first launch).
  5. Prereq:             brew install gh && gh auth login

  This build targets $TARGET_ARCH. On Apple Silicon you should be running
  the arm64 zip; an x86_64 zip will need Rosetta to launch.

INSTRUCTIONS
