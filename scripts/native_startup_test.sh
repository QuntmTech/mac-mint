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
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

# Compile under Swift 6 with the app's macOS 14 deployment target. AppKit launch
# callbacks and the full real app run only in the external helper below.
xcrun swiftc -swift-version 6 -parse-as-library \
  -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
  "$ROOT/scripts/native_startup_test.swift" \
  -framework AppKit -framework CoreGraphics -o "$PROBE"
"$PROBE" "$APP"
