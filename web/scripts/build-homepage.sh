#!/bin/bash
# Assemble the static marketing homepage and the separately routed account app.
# Run `npm run build` in web/ first. Node 22.13+ is required for the homepage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/ChatGPT sites the homepage V1"
DIST="$ROOT/web/dist"
[[ -d "$SRC" ]] || { echo "The marketing homepage source is missing." >&2; exit 1; }
python3 - "$DIST/index.html" <<'PY'
import pathlib, sys
page = pathlib.Path(sys.argv[1])
if not page.is_file() or 'id="root"' not in page.read_text():
    raise SystemExit('Build the account app with npm run build before assembling the site.')
PY

NODE22="$(ls -d "$HOME"/.nvm/versions/node/v22.* 2>/dev/null | sort -V | tail -1 || true)"
[[ -n "$NODE22" ]] && export PATH="$NODE22/bin:$PATH"

cd "$SRC"
[[ -d node_modules ]] || npm ci
rm -rf out
node scripts/prepare-metadata.mjs
NEXT_BASE_PATH= NEXT_PUBLIC_SITE_URL=https://macmint.co npx next build --webpack

mv "$DIST/index.html" "$DIST/account-app.html"
cp -R out/. "$DIST/"
python3 - "$DIST/index.html" <<'PY'
import pathlib, sys
page = pathlib.Path(sys.argv[1])
html = page.read_text()
if '/home2/_next/' in html:
    raise SystemExit('The main homepage must use root-relative assets.')
if '/lp.js' not in html:
    html = html.replace('<head>', '<head><script src="/lp.js"></script>', 1)
page.write_text(html)
PY
echo "✓ Main homepage and account app assembled in web/dist"
