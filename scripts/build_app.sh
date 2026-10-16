#!/bin/bash
# Builds dist/MacMint.app and dist/MacMint.zip.
#
# Signing is chosen by environment:
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)" → hardened-runtime Developer ID signature.
#                   Unset → ad-hoc signature for local testing.
#   NOTARY_PROFILE  notarytool keychain profile name, or APPLE_ID + APPLE_TEAM_ID + APPLE_APP_PASSWORD
#                   → notarize and staple (requires SIGN_IDENTITY).
#   NO_OPEN=1       don't open the app afterwards.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script must run on macOS." >&2
  exit 1
fi

if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "Consumer builds require Developer ID signing." >&2; exit 1; }
  [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ) ]] || {
    echo "Consumer builds require complete notarization credentials." >&2; exit 1;
  }
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
ZIP="$ROOT/dist/MacMint.zip"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/MacMint"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
chmod 755 "$CONTENTS/MacOS/MacMint"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  printf '▶ Signing with %s (hardened runtime)...\n' "$SIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/Resources/MacMint.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
else
  printf '▶ Ad-hoc signing local test bundle...\n'
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "${SIGN_IDENTITY:-}" ]] && [[ -n "${NOTARY_PROFILE:-}${APPLE_ID:-}" ]]; then
  printf '▶ Notarizing...\n'
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  # Re-zip so the download carries the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
printf '✓ Built and verified: %s (sha256 %s)\n' "$APP" "$(cat "$ZIP.sha256")"
if [[ "${NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi
