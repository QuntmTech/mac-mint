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
    # ReportCrash writes asynchronously. Always limit helper reports to this run.
    local report attempt collected=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      for report in "$HOME/Library/Logs/DiagnosticReports"/native-startup-test* \
        /Library/Logs/DiagnosticReports/native-startup-test*; do
        if [[ -f "$report" && ! -L "$report" && "$report" -nt "$STARTED" ]]; then
          if cp -p "$report" "$DIAGNOSTICS/$(basename "$report")"; then collected=1; fi
        fi
      done
      if [[ "$collected" -eq 1 ]]; then break; fi
      sleep 1
    done
    # On disposable GitHub runners only, also retain a new MacMint crash report
    # when its PID AND executable path match the helper's marker-verified launch.
    # Existing/user MacMint reports and all unrelated app reports are excluded.
    if [[ "${GITHUB_ACTIONS:-}" == "true" && "${CI:-}" == "true" ]]; then
      if ! python3 - "$DIAGNOSTICS" "$STARTED" \
        "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports <<'PY'
import json
import shutil
import sys
from pathlib import Path

destination, marker, *folders = map(Path, sys.argv[1:])
manifest = destination / "native-startup-test-owned-apps.jsonl"
owned = set()
if manifest.exists():
    for line in manifest.read_text().splitlines():
        try:
            record = json.loads(line)
            if isinstance(record["pid"], int) and record.get("marker"):
                owned.add((record["pid"], record["executablePath"]))
        except (ValueError, KeyError, TypeError):
            continue
started = marker.stat().st_mtime
copied = 0
for folder in folders:
    for report in folder.glob("MacMint*.ips"):
        try:
            if report.is_symlink() or not report.is_file() or report.stat().st_mtime < started:
                continue
            # Apple .ips files contain a metadata JSON line followed by the body.
            text = report.read_text()
            first, end = json.JSONDecoder().raw_decode(text.lstrip())
            remainder = text.lstrip()[end:].strip()
            body = json.loads(remainder) if remainder else first
            if (body.get("pid"), body.get("procPath")) not in owned:
                continue
            shutil.copy2(report, destination / ("native-startup-test-owned-app-" + report.name))
            copied += 1
        except (OSError, ValueError, TypeError, AttributeError):
            continue
print(f"Collected {copied} new crash report(s) for marker-verified test app PIDs.")
PY
      then
        printf 'Could not collect owned test-app crash diagnostics.\n' >&2
      fi
    fi
    printf 'Startup test failure diagnostics: %s\n' "$DIAGNOSTICS" >&2
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
: > "$DIAGNOSTICS/native-startup-test-owned-apps.jsonl"
MACMINT_NATIVE_STARTUP_DIAGNOSTICS="$DIAGNOSTICS" "$PROBE" "$APP" 2>&1 | tee "$DIAGNOSTICS/native-startup-test-output.log"
