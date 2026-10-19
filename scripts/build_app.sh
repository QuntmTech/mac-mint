#!/bin/bash
# Builds MacMint.app, ZIP and a drag-to-Applications DMG in dist/.
# MACMINT_ARCHS="arm64 x86_64" builds a universal consumer binary; local default is native.
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
ARCHITECTURES=()
read -r -a ARCHITECTURES <<< "${MACMINT_ARCHS:-$(uname -m)}"
[[ ${#ARCHITECTURES[@]} -gt 0 ]] || { echo "At least one architecture is required." >&2; exit 1; }
BIN_STAGE="$(mktemp -d "$ROOT/.build/package-bin.XXXXXX")"
trap 'rm -rf "$BIN_STAGE"' EXIT
BINARIES=()
for ARCHITECTURE in "${ARCHITECTURES[@]}"; do
  case "$ARCHITECTURE" in arm64|x86_64) ;; *) echo "Unsupported Mac architecture: $ARCHITECTURE" >&2; exit 1;; esac
  swift build -c release --product MacMint --arch "$ARCHITECTURE"
  BUILT_BIN="$(swift build -c release --show-bin-path --arch "$ARCHITECTURE")/MacMint"
  cp "$BUILT_BIN" "$BIN_STAGE/MacMint-$ARCHITECTURE"
  BINARIES+=("$BIN_STAGE/MacMint-$ARCHITECTURE")
done
BIN="$BIN_STAGE/MacMint"
if [[ ${#BINARIES[@]} -eq 1 ]]; then cp "${BINARIES[0]}" "$BIN"; else lipo -create "${BINARIES[@]}" -output "$BIN"; fi
lipo "$BIN" -verify_arch "${ARCHITECTURES[@]}"
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

NOTARIZED=0
if [[ -n "${SIGN_IDENTITY:-}" ]] && { [[ -n "${NOTARY_PROFILE:-}" ]] || [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; }; then
  printf '▶ Notarizing app archive...\n'
  "$ROOT/scripts/notarize.sh" "$ZIP" "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  NOTARIZED=1
  # Re-zip so the compatibility download carries the stapled app ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi
[[ "${REQUIRE_NOTARIZATION:-0}" != "1" || "$NOTARIZED" == "1" ]] || { echo "Consumer app notarization is required." >&2; exit 1; }
REQUIRE_NOTARIZATION="$NOTARIZED" "$ROOT/scripts/build_dmg.sh"
EXPECTED_ARCHS="${ARCHITECTURES[*]}" REQUIRE_NOTARIZATION="$NOTARIZED" "$ROOT/scripts/verify_installer.sh" "$ROOT/dist/MacMint.dmg"

shasum -a 256 "$ZIP" | awk '{print $1}' > "$ZIP.sha256"
printf '✓ Built and verified: %s (sha256 %s)\n' "$APP" "$(cat "$ZIP.sha256")"
if [[ "${NO_OPEN:-0}" != "1" ]]; then
  open "$APP"
fi
