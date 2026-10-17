#!/bin/bash
# Real-scene startup regression gate for a fresh graphical macOS CI runner.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The native startup probe requires macOS and a graphical WindowServer session." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/MacMint.app}"
[[ -x "$APP/Contents/MacOS/MacMint" ]] || { echo "No packaged MacMint executable at $APP" >&2; exit 1; }
mkdir -p "$ROOT/.build"
PROBE="$ROOT/.build/native-startup-test"
DIAGNOSTICS="$ROOT/.build/native-startup-diagnostics"
STARTED="$(mktemp "$ROOT/.build/native-startup-test-start.XXXXXX")"
mkdir -p "$DIAGNOSTICS"

collect_probe_diagnostics() {
  local result=$?
  trap - EXIT
  if [[ "$result" -ne 0 ]]; then
    {
      printf 'Native startup probe exit status: %s\n' "$result"
      /usr/bin/sw_vers
      /usr/bin/uname -m
    } > "$DIAGNOSTICS/native-startup-test-status.txt"
    # ReportCrash writes asynchronously. Collect only newly created reports for
    # this test helper, never MacMint or unrelated application/user reports.
    local report attempt collected=0
    for attempt in 1 2 3 4 5 6; do
      for report in "$HOME/Library/Logs/DiagnosticReports"/native-startup-test* \
        /Library/Logs/DiagnosticReports/native-startup-test*; do
        if [[ -f "$report" && ! -L "$report" && "$report" -nt "$STARTED" ]]; then
          if cp -p "$report" "$DIAGNOSTICS/$(basename "$report")"; then collected=1; fi
        fi
      done
      if [[ "$collected" -eq 1 ]]; then break; fi
      sleep 1
    done
    printf 'Helper-only failure diagnostics: %s\n' "$DIAGNOSTICS" >&2
  fi
  rm -f "$STARTED"
  exit "$result"
}
trap collect_probe_diagnostics EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

# Compile under Swift 6 with the app's macOS 14 deployment target. AppKit launch
# callbacks and the full real app run only in the external helper below.
xcrun swiftc -swift-version 6 -parse-as-library \
  -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
  "$ROOT/scripts/native_startup_test.swift" \
  -framework AppKit -framework CoreGraphics -o "$PROBE"
"$PROBE" "$APP" 2>&1 | tee "$DIAGNOSTICS/native-startup-test-output.log"
