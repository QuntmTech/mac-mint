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

printf '▶ Building MacMint release binary...\n'
swift build -c release --product MacMint
BIN="$(swift build -c release --show-bin-path)/MacMint"
APP="$ROOT/dist/MacMint.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/MacMint"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
chmod 755 "$CONTENTS/MacOS/MacMint"

printf '▶ Ad-hoc signing local test bundle...\n'
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

printf '▶ Zipping for download...\n'
rm -f "$ROOT/dist/MacMint.zip"
ditto -c -k --keepParent "$APP" "$ROOT/dist/MacMint.zip"

printf '✓ Built and verified: %s\n' "$APP"
if [[ "${NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi
