#!/bin/bash
# No Finder automation. The window layout (background, icon positions, hidden toolbar) is
# written by dmgbuild, pinned with hashes in scripts/installer-requirements.txt. Without it
# a plain image is built, unless REQUIRE_STYLED_INSTALLER=1 or the build is notarized.
set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "Disk images must be built on macOS." >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/MacMint.app"
DMG="$ROOT/dist/MacMint.dmg"
[[ -d "$APP" ]] || { echo "Build MacMint.app before creating the installer." >&2; exit 1; }
if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]] || { echo "Consumer disk images require Developer ID signing." >&2; exit 1; }
  xcrun stapler validate "$APP"
fi
STAGE="$(mktemp -d "$ROOT/.build/installer.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MacMint.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install MacMint.txt" <<'TEXT'
INSTALL MACMINT

1. Drag MacMint.app onto the Applications shortcut in this window.
2. Open MacMint from Applications. Eject the MacMint disk image afterward.
3. Follow the short setup guide, or choose Set Up Later to explore first.

Requires macOS 14 or later. Local scanning, exclusions, History and Restore
work before sign-in. A scan never removes files. Review and confirm each
removal; file recovery is available while the files remain in Trash.

ALREADY PURCHASED?
Connect the same account you used on macmint.co. Choose Check My Purchase
if the payment has just completed. A direct website purchase does not
require a separate redemption code. Keep your selections while signing in.

OPTIONAL PERMISSIONS
Full Disk Access improves scan coverage. Install the app first, then grant
access to that installed copy. Setup opens the relevant System Settings
page and provides written instructions. Photos and notifications ask only
when you use those features. No Accessibility or Screen Recording access
is required.

REPLACING AN OLDER COPY
Quit MacMint before replacing it in Applications. Replace only when you
intend to update that copy. Your local History and exclusions are stored
separately from the app; do not delete them to install an update.

For installation or account help: support@macmint.co
TEXT
VOLUME="MacMint"
if [[ "${REQUIRE_NOTARIZATION:-0}" != "1" ]]; then
  VOLUME="MacMint Preview"
  printf '\nDEVELOPER PREVIEW: This package is not a validated consumer installer.\n' >> "$STAGE/Install MacMint.txt"
fi
rm -f "$DMG"
REQUIRE_STYLED="${REQUIRE_STYLED_INSTALLER:-0}"
[[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]] && REQUIRE_STYLED=1
VENV="$ROOT/.build/installer-venv"
styled_tools() {
  [[ -x "$VENV/bin/dmgbuild" ]] && return 0
  # dmgbuild needs Python 3.10 or later (Apple's Command Line Tools ship 3.9).
  local python=""
  for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
      python="$candidate"; break
    fi
  done
  [[ -n "$python" ]] || return 1
  rm -rf "$VENV"
  "$python" -m venv "$VENV" && "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check \
    --require-hashes --only-binary :all: -r "$ROOT/scripts/installer-requirements.txt"
}
if styled_tools; then
  # hdiutil can briefly report "Resource busy" right after other images detach; retry once.
  build_styled() {
    "$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg_settings.py" -D app="$STAGE/MacMint.app" \
      -D readme="$STAGE/Install MacMint.txt" -D background="$ROOT/Resources/Installer/background.png" \
      "$VOLUME" "$DMG"
  }
  build_styled || { sleep 5; rm -f "$DMG"; build_styled; }
elif [[ "$REQUIRE_STYLED" == "1" ]]; then
  echo "The installer window tools (dmgbuild) could not be installed; a styled installer is required." >&2
  exit 1
else
  echo "warning: dmgbuild is unavailable; building a plain installer window." >&2
  hdiutil create -ov -volname "$VOLUME" -fs HFS+ -format UDZO -srcfolder "$STAGE" "$DMG"
fi
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ "${REQUIRE_NOTARIZATION:-0}" == "1" ]]; then
  "$ROOT/scripts/notarize.sh" "$DMG" "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
shasum -a 256 "$DMG" | awk '{print $1}' > "$DMG.sha256"
printf '✓ Installer created: %s\n' "$DMG"
