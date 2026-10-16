#!/bin/bash
# Builds the ChatGPT Sites homepage (A/B variant "home2") into web/dist/home2.
# Requires Node 22.13+ (Next.js 16); uses nvm's newest Node 22 when the default is older.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/ChatGPT sites the homepage V1"
DIST="$ROOT/web/dist"
[[ -d "$SRC" ]] || { echo "No ChatGPT homepage package; skipping /home2." >&2; exit 0; }

NODE22="$(ls -d "$HOME"/.nvm/versions/node/v22.* 2>/dev/null | sort -V | tail -1 || true)"
[[ -n "$NODE22" ]] && export PATH="$NODE22/bin:$PATH"

cd "$SRC"
[[ -d node_modules ]] || npm ci --legacy-peer-deps
rm -rf out
NEXT_BASE_PATH=/home2 NEXT_PUBLIC_SITE_URL=https://macmint.co npx next build --webpack

rm -rf "$DIST/home2"
cp -R out "$DIST/home2"
# Share images are referenced from the site root.
for asset in og.png og.svg; do
  [[ -f "$DIST/$asset" ]] || cp "out/$asset" "$DIST/$asset"
done
# Split-test beacon, same script as the main site.
python3 - "$DIST/home2/index.html" <<'PY'
import pathlib, sys
page = pathlib.Path(sys.argv[1])
html = page.read_text()
if '/lp.js' not in html:
    html = html.replace('<head>', '<head><script src="/lp.js"></script>', 1)
page.write_text(html)
PY
echo "✓ /home2 built"
