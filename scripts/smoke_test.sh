#!/bin/bash
# Launches the packaged app with --smoke-test and fails on crash, non-zero exit, or timeout.
set -uo pipefail

APP="${1:-dist/MacMint.app}"
TIMEOUT="${SMOKE_TIMEOUT:-120}"
BIN="$APP/Contents/MacOS/MacMint"
[[ -x "$BIN" ]] || { echo "No executable at $BIN" >&2; exit 1; }

"$BIN" --smoke-test &
PID=$!
for ((i = 0; i < TIMEOUT; i++)); do
  if ! kill -0 "$PID" 2>/dev/null; then
    wait "$PID"
    STATUS=$?
    [[ $STATUS -eq 0 ]] && echo "✓ Smoke test exited cleanly" || echo "✗ Smoke test exited with $STATUS"
    exit "$STATUS"
  fi
  sleep 1
done
echo "✗ Smoke test timed out after ${TIMEOUT}s" >&2
kill -9 "$PID" 2>/dev/null
exit 1
