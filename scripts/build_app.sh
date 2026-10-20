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
#
# Sparkle.framework (SwiftPM artifact) is embedded in Contents/Frameworks without its XPC
# services, and every nested executable is signed inside-out with the same identity.
# The bundle's copied Info.plist is stamped with CFBundleShortVersionString (VERSION),
# CFBundleVersion (commit count of HEAD, compared by Sparkle) and MacMintGitCommit, so a
# complete git history is required.
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

VERSION_STRING="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION_STRING" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "VERSION must be a dotted version number." >&2; exit 1; }
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
[[ "$PLIST_VERSION" == "$VERSION_STRING" ]] || { echo "VERSION ($VERSION_STRING) and Resources/Info.plist ($PLIST_VERSION) differ." >&2; exit 1; }
if [[ "$(git -C "$ROOT" rev-parse --is-shallow-repository 2>/dev/null)" != "false" ]]; then
  echo "Build numbers count the commits of HEAD: use a complete git clone (CI: actions/checkout fetch-depth: 0)." >&2
  exit 1
fi
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ && "$GIT_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "Could not read the build number and commit." >&2; exit 1; }
printf '▶ MacMint %s (build %s · %s)\n' "$VERSION_STRING" "$BUILD_NUMBER" "${GIT_COMMIT:0:7}"

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

# Keep in step with the exact Sparkle version in Package.swift (tag 2.10.0).
SPARKLE_REVISION="eef1a539a373c1f1a320624b1130fc5de7b2e100"
grep -Eq "\"revision\" *: *\"$SPARKLE_REVISION\"" "$ROOT/Package.resolved" || {
  echo "Package.resolved does not pin Sparkle at $SPARKLE_REVISION." >&2; exit 1;
}
SPARKLE_SOURCE="$({ find "$ROOT/.build/artifacts/sparkle" -type d -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' -prune 2>/dev/null || true; } | sort | sed -n 1p)"
[[ -n "$SPARKLE_SOURCE" && -d "$SPARKLE_SOURCE" ]] || { echo "Sparkle.framework was not found in the SwiftPM artifacts." >&2; exit 1; }
APP="$ROOT/dist/MacMint.app"
ZIP="$ROOT/dist/MacMint.zip"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN" "$CONTENTS/MacOS/MacMint"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION_STRING" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS/Info.plist"
plutil -replace MacMintGitCommit -string "$GIT_COMMIT" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"
[[ "$(plutil -extract SUPublicEDKey raw "$CONTENTS/Info.plist")" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "Info.plist needs SUPublicEDKey." >&2; exit 1; }
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"
chmod 755 "$CONTENTS/MacOS/MacMint"

printf '▶ Embedding Sparkle.framework...\n'
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$SPARKLE"
SPARKLE_VERSION="$SPARKLE/Versions/$(readlink "$SPARKLE/Versions/Current")"
[[ -x "$SPARKLE_VERSION/Autoupdate" && -d "$SPARKLE_VERSION/Updater.app" ]] || { echo "Unexpected Sparkle.framework layout." >&2; exit 1; }
# MacMint is not sandboxed and sets no SUEnable*Service key, so Sparkle downloads and
# launches its installer in-process; the XPC services are only for sandboxed apps.
rm -rf "$SPARKLE_VERSION/XPCServices" "$SPARKLE/XPCServices"
LOAD_COMMANDS="$(otool -l "$CONTENTS/MacOS/MacMint")"
if [[ "$LOAD_COMMANDS" != *"path @executable_path/../Frameworks "* ]]; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$CONTENTS/MacOS/MacMint"
fi

# Inside-out with one identity: Sparkle's installer and progress app, the framework, the app.
sign_code() {
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"
  else
    codesign --force --sign - "$@"
  fi
}
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  printf '▶ Signing with %s (hardened runtime)...\n' "$SIGN_IDENTITY"
else
  printf '▶ Ad-hoc signing local test bundle...\n'
fi
sign_code "$SPARKLE_VERSION/Autoupdate"
sign_code "$SPARKLE_VERSION/Updater.app"
sign_code "$SPARKLE"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  sign_code --entitlements "$ROOT/Resources/MacMint.entitlements" "$APP"
else
  sign_code "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
[[ ! -e "$SPARKLE_VERSION/XPCServices" ]] || { echo "Sparkle XPC services must not be embedded." >&2; exit 1; }

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
