#!/bin/bash
# Ensure Sparkle's CLI tools are available locally.
#
# The Swift Package Manager dep already gives us Sparkle.framework for embedding
# (build-app.sh copies it from .build/), but `sign_update` and `generate_keys`
# only ship in the regular Mac tarball release. We download once per version
# and cache under .cache/sparkle/.
#
# Outputs:
#   .cache/sparkle/<version>/bin/sign_update    — used at release time
#   .cache/sparkle/<version>/bin/generate_keys  — used at first-time key setup
#
# Pin to a version that's >= the Package.swift dep so signature formats match.
# Update SPARKLE_VERSION here when bumping Sparkle in Package.swift.

set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"

# SHA256 of Sparkle-<version>.tar.xz from sparkle-project's GitHub releases.
# When you bump SPARKLE_VERSION, also add a `case` branch here. The expected
# hash is published on the Sparkle release page; you can also compute it via:
#     curl -fL "$TARBALL_URL" | shasum -a 256
# If no entry matches, verification is skipped and a loud warning is printed
# (acceptable for first-time bumps where you don't yet have the hash; not
# acceptable for CI). CI fails closed when the sha is unset (see
# SPARKLE_REQUIRE_SHA below).
#
# Use a case statement rather than a `declare -A` associative array — macOS
# ships bash 3.2 at /bin/bash, which doesn't support associative arrays, and
# every script in this repo invokes /bin/bash directly via shebang.
_sparkle_expected_sha256() {
    case "$1" in
        2.9.1) echo "c0dde519fd2a43ddfc6a1eb76aec284d7d888fe281414f9177de3164d98ba4c7" ;;
        *) echo "" ;;
    esac
}
EXPECTED_SHA256="$(_sparkle_expected_sha256 "$SPARKLE_VERSION")"

# Two `..` because this script lives at scripts/lib/, not scripts/.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CACHE_DIR="$ROOT/.cache/sparkle/$SPARKLE_VERSION"
TARBALL_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

if [[ -x "$CACHE_DIR/bin/sign_update" && -x "$CACHE_DIR/bin/generate_keys" ]]; then
    # Already populated. We trust the cache; the hash check ran when it was
    # first populated.
    echo "$CACHE_DIR"
    exit 0
fi

mkdir -p "$CACHE_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading Sparkle $SPARKLE_VERSION" >&2
curl -fL --silent --show-error -o "$TMP/sparkle.tar.xz" "$TARBALL_URL"

ACTUAL_SHA256="$(shasum -a 256 "$TMP/sparkle.tar.xz" | awk '{print $1}')"

if [[ -n "$EXPECTED_SHA256" ]]; then
    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "==> Sparkle tarball SHA256 mismatch — refusing to extract." >&2
        echo "    Expected: $EXPECTED_SHA256" >&2
        echo "    Actual:   $ACTUAL_SHA256" >&2
        echo "    URL:      $TARBALL_URL" >&2
        echo "    If you intentionally bumped SPARKLE_VERSION, add a case" >&2
        echo "    branch to _sparkle_expected_sha256() in scripts/lib/sparkle-tools.sh." >&2
        exit 1
    fi
    echo "==> Verified SHA256 ($ACTUAL_SHA256)" >&2
elif [[ -n "${SPARKLE_REQUIRE_SHA:-}" ]]; then
    echo "==> SPARKLE_REQUIRE_SHA is set but _sparkle_expected_sha256() has no" >&2
    echo "    entry for $SPARKLE_VERSION. Add a case branch in scripts/lib/sparkle-tools.sh." >&2
    echo "    Computed: $ACTUAL_SHA256" >&2
    exit 1
else
    echo "==> WARNING: no expected SHA256 for Sparkle $SPARKLE_VERSION." >&2
    echo "    Computed: $ACTUAL_SHA256" >&2
    echo "    Add a case branch to _sparkle_expected_sha256() in scripts/lib/sparkle-tools.sh." >&2
fi

echo "==> Extracting CLI tools" >&2
tar -xf "$TMP/sparkle.tar.xz" -C "$TMP"

mkdir -p "$CACHE_DIR/bin"
cp "$TMP/bin/sign_update" "$CACHE_DIR/bin/sign_update"
cp "$TMP/bin/generate_keys" "$CACHE_DIR/bin/generate_keys"
chmod +x "$CACHE_DIR/bin/sign_update" "$CACHE_DIR/bin/generate_keys"

echo "$CACHE_DIR"
