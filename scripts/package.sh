#!/usr/bin/env bash
# Package GitPilot for distribution to coworkers.
# Produces:
#   - GitPilot-<version>.zip       — drag-into-/Applications artifact
#   - GitPilot-<version>.zip.sha256 — checksum for verification
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

# Version: argument > Info.plist > "0.0.0-dev" fallback. We re-build first to
# ensure the bundled Info.plist is current.
VERSION="${1:-}"

echo "==> Building bundle"
"$ROOT/scripts/build-app.sh" >/dev/null

if [[ -z "$VERSION" ]]; then
    if [[ -f "$APP_DIR/Contents/Info.plist" ]]; then
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo '')"
    fi
fi
VERSION="${VERSION:-0.0.0-dev}"

echo "==> Packaging $APP_NAME v$VERSION"
mkdir -p "$DIST_DIR"
ZIP_NAME="$APP_NAME-$VERSION.zip"
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
cat <<'INSTRUCTIONS'

  1. Verify (optional):  shasum -a 256 GitPilot-X.Y.Z.zip
  2. Unzip:              unzip GitPilot-X.Y.Z.zip
  3. Move to Applications: mv GitPilot.app /Applications/
  4. First launch:       right-click GitPilot.app → Open (Gatekeeper requires
                         this once because the app is ad-hoc signed, not via
                         an Apple Developer ID).
  5. Prereq:             brew install gh && gh auth login

INSTRUCTIONS
