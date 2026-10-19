#!/bin/bash
# Verify a built OR downloaded installer without installing it or granting access.
set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "Installer verification requires macOS." >&2; exit 1; }
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: verify_installer.sh MacMint.dmg" >&2; exit 2; }
DMG="$1"
WORK="$(mktemp -d)"
MOUNT="$WORK/mounted"
ATTACHED=0
cleanup() {
  if [[ "$ATTACHED" == "1" ]]; then hdiutil detach "$MOUNT" -quiet || hdiutil detach "$MOUNT" -force -quiet; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
[[ -f "$DMG.sha256" ]] || { echo "The installer SHA-256 file is required." >&2; exit 1; }
EXPECTED="$(cat "$DMG.sha256")"
ACTUAL="$(shasum -a 256 "$DMG" | awk '{print $1}')"
[[ "$EXPECTED" =~ ^[a-f0-9]{64}$ && "$EXPECTED" == "$ACTUAL" ]] || { echo "Installer checksum mismatch." >&2; exit 1; }
hdiutil verify "$DMG"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" -quiet
ATTACHED=1
[[ -d "$MOUNT/MacMint.app" && -f "$MOUNT/Install MacMint.txt" && -L "$MOUNT/Applications" ]]
[[ "$(readlink "$MOUNT/Applications")" == "/Applications" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$MOUNT/MacMint.app/Contents/Info.plist")" == "co.macmint.MacMint" ]]
codesign --verify --strict --verbose=2 "$MOUNT/MacMint.app"
if [[ -n "${EXPECTED_ARCHS:-}" ]]; then
  EXPECTED_ARCHITECTURES=()
  read -r -a EXPECTED_ARCHITECTURES <<< "$EXPECTED_ARCHS"
  lipo -verify_arch "${EXPECTED_ARCHITECTURES[@]}" "$MOUNT/MacMint.app/Contents/MacOS/MacMint"
fi
if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  xcrun stapler validate "$DMG"
  xcrun stapler validate "$MOUNT/MacMint.app"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  spctl --assess --type execute --verbose=2 "$MOUNT/MacMint.app"
fi
# Copy to an isolated Applications-like directory, not the real /Applications.
mkdir "$WORK/Applications"
ditto "$MOUNT/MacMint.app" "$WORK/Applications/MacMint.app"
codesign --verify --strict --verbose=2 "$WORK/Applications/MacMint.app"
cmp "$MOUNT/MacMint.app/Contents/MacOS/MacMint" "$WORK/Applications/MacMint.app/Contents/MacOS/MacMint"
printf '✓ Read-only installer, Applications shortcut and copied app verified.\n'
