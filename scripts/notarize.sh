#!/bin/bash
# Submit a signed container, require Apple's Accepted result, then staple its target.
set -euo pipefail
[[ $# -eq 2 ]] || { echo "Usage: notarize.sh CONTAINER STAPLE_TARGET" >&2; exit 2; }
RESULT="$(mktemp)"
trap 'rm -f "$RESULT"' EXIT
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RESULT"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait --output-format json > "$RESULT"
else
  echo "Complete Apple notarization credentials are required." >&2
  exit 1
fi
python3 - "$RESULT" <<'PY'
import json, sys
with open(sys.argv[1]) as result:
    status = json.load(result).get('status')
if status != 'Accepted':
    raise SystemExit(f'Apple notarization was not accepted ({status}). Nothing will be published.')
PY
xcrun stapler staple "$2"
xcrun stapler validate "$2"
