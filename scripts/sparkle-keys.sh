#!/bin/bash
# One-time setup: generate the EdDSA key pair Sparkle uses to sign updates.
#
# Sparkle's `generate_keys` stores the private key in the macOS Keychain. This
# script:
#   1. Runs generate_keys (no args) to ensure a keypair exists. This is
#      idempotent — if a key already exists in your Keychain, it's reused.
#   2. Extracts the public key via `-p` (lookup-only mode) into a committed
#      file scripts/sparkle-public-key.txt — public keys are public, so it's
#      safe to ship in the repo.
#   3. Exports the private key via `-x` into a temp file, prints it for you
#      to paste into the GitHub Actions secret SPARKLE_ED_PRIVATE_KEY, then
#      shreds the temp file.
#
# Run this ONCE. After that, build-app.sh reads the public key from the
# committed file and CI signs releases using the GitHub secret.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC_KEY_FILE="$ROOT/scripts/sparkle-public-key.txt"

SPARKLE_DIR="$("$ROOT/scripts/lib/sparkle-tools.sh")"
GENERATE_KEYS="$SPARKLE_DIR/bin/generate_keys"

echo "==> Ensuring Sparkle EdDSA keypair exists in Keychain"
echo
echo "    macOS may prompt for Keychain access — click \"Always Allow\" to"
echo "    avoid being asked again."
echo

# Idempotent: creates if missing, no-op if present. The first run prints
# instructions and the public key; we ignore stdout because we re-extract it
# with -p next (cleaner output).
"$GENERATE_KEYS" >/dev/null

echo "==> Reading public key"
PUBLIC_KEY="$("$GENERATE_KEYS" -p)"
PUBLIC_KEY="${PUBLIC_KEY//[$'\t\r\n ']/}"  # strip whitespace just in case

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "Failed to read public key from generate_keys -p" >&2
    exit 1
fi

printf '%s\n' "$PUBLIC_KEY" > "$PUBLIC_KEY_FILE"
echo "    Public key written:  $PUBLIC_KEY"
echo "    File:                $PUBLIC_KEY_FILE"
echo

echo "==> Exporting private key (for the GitHub Actions secret)"
# generate_keys -x refuses to overwrite an existing file, so we can't pass a
# path created by `mktemp` (which creates the file empty). Use a temp DIR
# instead — mktemp -d makes it 0700, so the path inside is safe to write to.
PRIVATE_KEY_DIR="$(mktemp -d)"
PRIVATE_KEY_TMP="$PRIVATE_KEY_DIR/private-key"
trap 'rm -rf "$PRIVATE_KEY_DIR"' EXIT

"$GENERATE_KEYS" -x "$PRIVATE_KEY_TMP" >/dev/null

echo
echo "    Add the following as a GitHub Actions secret named:"
echo "      SPARKLE_ED_PRIVATE_KEY"
echo
echo "    (Settings → Secrets and variables → Actions → New repository secret)"
echo
echo "    ----- PRIVATE KEY (copy this) -----"
# Sparkle's exported key file has no trailing newline; printf '%s\n' adds one
# so the closing marker doesn't end up on the same line as the key.
printf '%s\n' "$(cat "$PRIVATE_KEY_TMP")"
echo "    ----- end -----"
echo
echo "==> Done"
echo "    Commit scripts/sparkle-public-key.txt."
echo "    NEVER commit the private key — it's only ever in your Keychain and"
echo "    in the GitHub Actions secret."
