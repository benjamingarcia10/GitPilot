#!/bin/bash
# One-shot installer for GitPilot.
#
# What this does:
#   1. Sanity checks (macOS 13+, arm64, /Applications writable)
#   2. Resolves the latest release tag via the github.com/.../releases/latest redirect
#   3. Downloads the matching arm64 zip + .sha256 from the release assets
#   4. Verifies the checksum
#   5. Quits any running GitPilot and replaces /Applications/GitPilot.app
#   6. Strips xattrs so Gatekeeper doesn't ask "Open Anyway" on first launch
#      (curl-downloaded files aren't quarantined to begin with, but ditto can
#      propagate xattrs out of the zip — clear them defensively)
#   7. Launches the app
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/benjamingarcia10/GitPilot/main/scripts/install.sh | bash
#
# To inspect first (recommended):
#   curl -fsSL https://raw.githubusercontent.com/benjamingarcia10/GitPilot/main/scripts/install.sh -o gitpilot-install.sh
#   less gitpilot-install.sh
#   bash gitpilot-install.sh

set -euo pipefail

REPO="benjamingarcia10/GitPilot"
APP_NAME="GitPilot"
INSTALL_DIR="/Applications"
APP_PATH="$INSTALL_DIR/$APP_NAME.app"

if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    DIM=$'\033[2m'; RESET=$'\033[0m'
else
    BOLD=""; RED=""; GREEN=""; DIM=""; RESET=""
fi

err()  { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }
log()  { printf '%s\n' "${BOLD}==>${RESET} $*"; }

# --- preflight ---

[[ "$(uname)" == "Darwin" ]] || err "GitPilot is macOS-only (detected: $(uname))."

# Check hardware capability, not `uname -m`. uname reports the *process* arch,
# so an x86_64 bash (Rosetta-translated, or an Intel-prefix Homebrew bash
# earlier in PATH) reports x86_64 even on Apple Silicon — and the installer
# would falsely reject a Mac that can run the binary just fine.
if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]]; then
    err "GitPilot only ships arm64 builds — this Mac is Intel."
fi

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if (( OS_MAJOR < 13 )); then
    err "GitPilot requires macOS 13 or later (detected: $OS_VERSION)."
fi

# /Applications is writable for admin users on personal Macs without sudo.
# Standard users would need sudo bash <(curl ...) — surface that explicitly
# rather than failing midway through the download.
if [[ ! -w "$INSTALL_DIR" ]]; then
    err "$INSTALL_DIR is not writable for $(whoami).
    Re-run with sudo:
      ${DIM}curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | sudo bash${RESET}"
fi

# --- resolve latest version ---
#
# github.com/<repo>/releases/latest 302-redirects to the canonical
# /releases/tag/<tag> URL. We follow the redirect chain with -L and read the
# final URL via -w. This avoids hitting api.github.com (which has a 60/hr
# unauthenticated limit per IP) and avoids depending on jq/python3 to parse
# JSON — both of which a fresh-install Mac may not have until they install
# the Xcode Command Line Tools.

log "Resolving latest release"
# Wrap in `if !` so we can swap curl's terse "404 Not Found" for a friendlier
# message when no release has been published yet (or the network is down).
# Without this guard, `set -e` would abort with curl's raw error.
if ! RESOLVED_URL="$(curl -fsLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest" 2>/dev/null)"; then
    err "Could not resolve the latest release for $REPO.
    Either no release has been published yet, or GitHub is unreachable.
    See https://github.com/$REPO/releases for the current state."
fi

TAG="${RESOLVED_URL##*/}"
VERSION="${TAG#v}"

# Defensive: if the redirect chain somehow didn't resolve to a /tag/<x> URL
# (e.g. the user's network injected a captive-portal redirect), TAG would be
# the literal "latest" or empty.
if [[ -z "$VERSION" || "$TAG" == "latest" ]]; then
    err "Could not determine latest version. Got: $RESOLVED_URL"
fi

ZIP_NAME="$APP_NAME-$VERSION-arm64.zip"
SHA_NAME="$ZIP_NAME.sha256"
ZIP_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
SHA_URL="https://github.com/$REPO/releases/download/$TAG/$SHA_NAME"

log "Latest version: ${BOLD}$VERSION${RESET} ($TAG)"

# --- download to a temp dir, atomic install at the end ---

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log "Downloading $ZIP_NAME"
curl -fL --progress-bar -o "$TMP_DIR/$ZIP_NAME" "$ZIP_URL"

log "Downloading checksum"
curl -fsSL -o "$TMP_DIR/$SHA_NAME" "$SHA_URL"

log "Verifying SHA-256"
EXPECTED="$(awk '{print $1}' "$TMP_DIR/$SHA_NAME")"
ACTUAL="$(shasum -a 256 "$TMP_DIR/$ZIP_NAME" | awk '{print $1}')"
if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    err "Checksum mismatch — refusing to install.
    Expected: $EXPECTED
    Actual:   $ACTUAL"
fi
printf '    %sOK%s (%s)\n' "$GREEN" "$RESET" "$ACTUAL"

log "Unzipping"
ditto -x -k "$TMP_DIR/$ZIP_NAME" "$TMP_DIR"
[[ -d "$TMP_DIR/$APP_NAME.app" ]] || err "Expected $APP_NAME.app inside the zip, didn't find it."

# --- replace existing install ---

if [[ -d "$APP_PATH" ]]; then
    log "Quitting any running $APP_NAME"
    pkill -x "$APP_NAME" 2>/dev/null || true
    # Brief grace period for the app to release file handles and flush its
    # persisted state. Without this, the rm below can race with an in-flight
    # state-save and leave a partial JSON file.
    sleep 1
    rm -rf "$APP_PATH"
fi

log "Installing to $APP_PATH"
ditto "$TMP_DIR/$APP_NAME.app" "$APP_PATH"

# Strip xattrs defensively — clears com.apple.quarantine if it was set, and
# anything else that might trip Gatekeeper. ad-hoc-signed binaries pass
# Gatekeeper's notarization check only when not quarantined.
log "Clearing quarantine attributes"
xattr -cr "$APP_PATH" 2>/dev/null || true

# --- gh CLI status ---
#
# GitPilot reads its GitHub token via `gh auth token`, so the app shows a
# reauth banner if gh is missing or not logged in. Surface that here so the
# user knows the next concrete step before they open the app and wonder why
# nothing's loading.
#
# We deliberately do NOT install Homebrew or run `gh auth login` ourselves:
#   - Installing brew unprompted is too invasive for a curl|bash flow.
#   - `gh auth login` is interactive and opens a browser — chaining it inside
#     the install script means the script blocks indefinitely waiting for the
#     user to finish auth in another window. Better to print the command and
#     let the user run it deliberately.

GH_STATUS_LINE=""
if ! command -v gh >/dev/null 2>&1; then
    GH_STATUS_LINE="${RED}✗${RESET} ${BOLD}gh is not installed${RESET} — install it before opening GitPilot:
      ${DIM}brew install gh && gh auth login${RESET}
    (or grab a binary from https://cli.github.com/)"
elif ! gh auth status >/dev/null 2>&1; then
    GH_STATUS_LINE="${RED}✗${RESET} ${BOLD}gh is installed but not authenticated${RESET} — log in before opening GitPilot:
      ${DIM}gh auth login${RESET}"
else
    # gh auth status prints "Logged in to github.com account <name>" — pluck
    # the account name out for a friendlier confirmation. Falls back gracefully
    # if the format ever changes.
    GH_USER="$(gh auth status 2>&1 | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)"
    if [[ -n "$GH_USER" ]]; then
        GH_STATUS_LINE="${GREEN}✓${RESET} gh authenticated as ${BOLD}$GH_USER${RESET}"
    else
        GH_STATUS_LINE="${GREEN}✓${RESET} gh authenticated"
    fi
fi

log "Launching $APP_NAME"
open "$APP_PATH"

cat <<EOF

${GREEN}${BOLD}Installed: $APP_NAME $VERSION${RESET}

GitHub CLI:
    $GH_STATUS_LINE

Next steps:
  - First launch will ask for notification permission — allow it.
  - Future updates install in-app via Sparkle. No more downloads.

EOF
