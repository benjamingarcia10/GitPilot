#!/bin/bash
# One-command rehearsal of the full Sparkle update flow.
#
# What this does:
#   1. Builds GitPilot.app at $OLD_VERSION (the "currently installed" copy)
#   2. Stashes that copy at /tmp/GitPilot-test.app so a later rebuild won't
#      clobber it
#   3. Sets defaults on com.affirm.gitpilot to point at a local appcast
#   4. Starts a Python HTTP server in the repo root (so /appcast.xml and
#      /dist/* are reachable)
#   5. Builds + signs the $NEW_VERSION release and prepends an appcast entry
#      whose enclosure URL points back at the local HTTP server
#   6. Launches /tmp/GitPilot-test.app
#
# You then click "Check for Updates…" in the running app (Settings → Updates).
# Sparkle should prompt with $NEW_VERSION's release notes, download from the
# local HTTP server, verify the EdDSA signature, swap the bundle, and relaunch.
#
# Press Ctrl+C in this terminal when done. Cleanup reverts:
#   - kills the HTTP server and the test app
#   - removes the SUFeedURL / SUScheduledCheckInterval defaults overrides
#   - restores appcast.xml to its committed state
#   - removes /tmp/GitPilot-test.app
#
# Prerequisites (run once):
#   ./scripts/sparkle-keys.sh
#
# Usage:
#   ./scripts/test-update.sh                 # 0.1.0 -> 0.2.0 on port 8765
#   ./scripts/test-update.sh 0.1.0 0.5.0     # custom versions
#   PORT=9000 ./scripts/test-update.sh       # custom HTTP port

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OLD_VERSION="${1:-0.1.0}"
NEW_VERSION="${2:-0.2.0}"
PORT="${PORT:-8765}"
TARGET_ARCH="${TARGET_ARCH:-arm64}"

BUNDLE_ID="com.affirm.gitpilot"
APP_NAME="GitPilot"
TEST_APP="/tmp/$APP_NAME-test.app"
APPCAST="$ROOT/appcast.xml"
APPCAST_BACKUP="$ROOT/.appcast.xml.test-backup"
DIST_DIR="$ROOT/dist"
HTTP_LOG="/tmp/gitpilot-test-http.log"

# --- preflight ---

if [[ ! -s "$ROOT/scripts/sparkle-public-key.txt" ]]; then
    echo "Error: scripts/sparkle-public-key.txt is missing or empty." >&2
    echo "Run ./scripts/sparkle-keys.sh first to generate the EdDSA keypair." >&2
    exit 1
fi

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
    echo "Error: OLD_VERSION and NEW_VERSION must differ ($OLD_VERSION)." >&2
    exit 1
fi

# --- cleanup trap ---

HTTP_PID=""
CLEANED_UP=0
cleanup() {
    [[ "$CLEANED_UP" == "1" ]] && return
    CLEANED_UP=1
    set +e
    echo
    echo "==> Cleaning up"
    [[ -n "$HTTP_PID" ]] && kill "$HTTP_PID" 2>/dev/null
    pkill -f "$TEST_APP/Contents/MacOS/$APP_NAME" 2>/dev/null
    # Tear down all three defaults overrides, otherwise a leftover
    # SUEnableAutomaticChecks=true would shadow the production app's stored
    # preference (NSUserDefaults wins over Info.plist for Sparkle).
    defaults delete "$BUNDLE_ID" SUFeedURL 2>/dev/null
    defaults delete "$BUNDLE_ID" SUEnableAutomaticChecks 2>/dev/null
    defaults delete "$BUNDLE_ID" SUScheduledCheckInterval 2>/dev/null
    rm -rf "$TEST_APP"
    if [[ -f "$APPCAST_BACKUP" ]]; then
        mv "$APPCAST_BACKUP" "$APPCAST"
        echo "    Restored appcast.xml"
    fi
    echo "    Done."
}
# EXIT alone is enough — bash runs it on signal-caused exits too.
# Trapping INT/TERM separately would fire cleanup twice (signal handler + EXIT).
trap cleanup EXIT
# Ctrl+C is the documented "I'm done" signal here, so treat it as success.
trap 'cleanup; exit 0' INT TERM

# --- build the "old" version, copy out of the workspace ---

echo "==> Building v$OLD_VERSION (the 'installed' copy)"
VERSION="$OLD_VERSION" BUILD=1 TARGET_ARCH="$TARGET_ARCH" \
    "$ROOT/scripts/build-app.sh" >/dev/null

rm -rf "$TEST_APP"
cp -R "$ROOT/$APP_NAME.app" "$TEST_APP"

# --- preconfigure user defaults: local feed + bypass first-launch opt-in ---

echo "==> Configuring $BUNDLE_ID defaults for local feed"
defaults write "$BUNDLE_ID" SUFeedURL "http://127.0.0.1:$PORT/appcast.xml"
defaults write "$BUNDLE_ID" SUEnableAutomaticChecks -bool true
defaults write "$BUNDLE_ID" SUScheduledCheckInterval -int 60

# --- save appcast so we can restore on exit ---

cp "$APPCAST" "$APPCAST_BACKUP"

# --- start HTTP server before generating the release ---

echo "==> Starting HTTP server on http://127.0.0.1:$PORT"
python3 -m http.server "$PORT" --bind 127.0.0.1 >"$HTTP_LOG" 2>&1 &
HTTP_PID=$!
sleep 1

if ! kill -0 "$HTTP_PID" 2>/dev/null; then
    echo "Error: HTTP server died on start — check $HTTP_LOG" >&2
    exit 1
fi

# --- build + sign + appcast for $NEW_VERSION ---

NEW_BUILD="$(date +%s)"
NOTES_HTML="<p>Test build $NEW_VERSION (local rehearsal)</p>"

echo "==> Building v$NEW_VERSION (build $NEW_BUILD, $TARGET_ARCH)"
VERSION="$NEW_VERSION" BUILD="$NEW_BUILD" TARGET_ARCH="$TARGET_ARCH" \
    "$ROOT/scripts/package.sh" "$NEW_VERSION" >/dev/null

ZIP_NAME="$APP_NAME-$NEW_VERSION-$TARGET_ARCH.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
if [[ ! -f "$ZIP_PATH" ]]; then
    echo "Expected $ZIP_PATH but it doesn't exist" >&2
    exit 1
fi

echo "==> Signing update with Sparkle"
SPARKLE_DIR="$("$ROOT/scripts/lib/sparkle-tools.sh")"
SIGNATURE_LINE="$("$SPARKLE_DIR/bin/sign_update" "$ZIP_PATH")"
LENGTH="$(stat -f%z "$ZIP_PATH")"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"
DOWNLOAD_URL="http://127.0.0.1:$PORT/dist/$ZIP_NAME"

echo "==> Prepending appcast entry"
"$ROOT/scripts/lib/update-appcast.py" \
    --appcast "$APPCAST" \
    --version "$NEW_BUILD" \
    --short-version "$NEW_VERSION" \
    --url "$DOWNLOAD_URL" \
    --length "$LENGTH" \
    --signature-line "$SIGNATURE_LINE" \
    --pub-date "$PUB_DATE" \
    --description "$NOTES_HTML"

# --- launch the test app ---

echo "==> Launching test app at v$OLD_VERSION"
open "$TEST_APP"

cat <<EOF

==================================================================
  Ready. Test the update flow:

    1. In the menu bar, click GitPilot
    2. Open Settings (⌘,)
    3. Switch to the Updates tab
    4. Click "Check for Updates…"
    5. You should see a Sparkle prompt offering v$NEW_VERSION
    6. Click "Install Update"
    7. After relaunch, version should read $NEW_VERSION

  Logs:
    HTTP server: tail -f $HTTP_LOG
    Sparkle:     log stream --predicate 'subsystem == "org.sparkle-project.Sparkle"'

  Press Ctrl+C in THIS terminal to clean up.
==================================================================

EOF

# Block until Ctrl+C; the trap handles cleanup.
wait "$HTTP_PID"
