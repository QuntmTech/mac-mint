#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

printf '▶ Running core tests...\n'
swift test

printf '▶ Validating Info.plist...\n'
plutil -lint "$ROOT/Resources/Info.plist"

printf '▶ Building MacCleaner release binary...\n'
swift build -c release --product MacCleaner
BIN="$(swift build -c release --show-bin-path)/MacCleaner"
APP="$ROOT/dist/MacCleaner.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/MacCleaner"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
chmod 755 "$CONTENTS/MacOS/MacCleaner"

printf '▶ Ad-hoc signing local test bundle...\n'
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

printf '✓ Built and verified: %s\n' "$APP"
if [[ "${NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi
