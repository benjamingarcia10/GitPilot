#!/bin/bash
# Dev loop: watch Sources, rebuild bundle on change, relaunch app, tee stderr.
# Ctrl+C exits cleanly.
#
# /bin/bash (universal) rather than /usr/bin/env bash because some user PATHs
# lead with an Intel-only Homebrew bash, which would launch this script under
# Rosetta and silently produce an x86_64 binary.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="GitPilot"
APP_DIR="$ROOT/$APP_NAME.app"
APP_BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
APP_PID=""

prefix() {
  # Prefixes each line of stdin with a tag so logs from build vs app are distinguishable.
  local tag="$1"
  while IFS= read -r line; do
    printf '%s %s\n' "$tag" "$line"
  done
}

kill_app() {
  if [[ -n "$APP_PID" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    # Give it a moment to exit cleanly before we move on.
    for _ in 1 2 3 4 5; do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -9 "$APP_PID" 2>/dev/null || true
  fi
  # Also catch any other GitPilot instance launched outside this script.
  pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
  APP_PID=""
}

cleanup() {
  echo
  echo "[dev] shutting down"
  kill_app
  exit 0
}
trap cleanup INT TERM

rebuild_and_run() {
  echo "[dev] $(date +%H:%M:%S) rebuilding"
  kill_app
  if "$ROOT/scripts/build-app.sh" 2>&1 | prefix "[build]"; then
    echo "[dev] $(date +%H:%M:%S) launching"
    # Run the binary directly so we can tee its stderr. GITPILOT_DEBUG=1 enables
    # the verbose Log.debug timings during development.
    GITPILOT_DEBUG=1 "$APP_BIN" 2>&1 | prefix "[app]" &
    APP_PID=$!
  else
    echo "[dev] build failed — leaving previous app down. Fix and save again."
  fi
}

# Hash file mtimes to detect changes. Avoids requiring fswatch as a dependency.
hash_sources() {
  find "$ROOT/Sources" "$ROOT/scripts" "$ROOT/Package.swift" \
    -type f \( -name '*.swift' -o -name '*.sh' \) \
    -exec stat -f '%m %N' {} \; 2>/dev/null | sort | shasum | awk '{print $1}'
}

last_hash=""
echo "[dev] watching Sources/ and scripts/ — Ctrl+C to stop"

while true; do
  current_hash="$(hash_sources)"
  if [[ "$current_hash" != "$last_hash" ]]; then
    last_hash="$current_hash"
    rebuild_and_run
  fi
  sleep 1
done
