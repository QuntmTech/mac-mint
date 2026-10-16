#!/bin/bash
# Builds the site and publishes it to the cPanel docroot for macmint.co.
# cPanel-managed files (.htaccess directives, .user.ini, php.ini, .well-known, cgi-bin) are preserved;
# the MacMint block in .htaccess is replaced on every deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCROOT="${DOCROOT:-/home/qrkit/macmint.co}"
cd "$ROOT"

printf '▶ Building site...\n'
npm run build

printf '▶ Publishing to %s...\n' "$DOCROOT"
DOCROOT_MODE="$(stat -c '%a' "$DOCROOT")"
rsync -a --delete \
  --exclude '.htaccess' --exclude '.user.ini' --exclude 'php.ini' \
  --exclude '.well-known' --exclude 'cgi-bin' --exclude 'downloads' \
  dist/ "$DOCROOT/"
chmod "$DOCROOT_MODE" "$DOCROOT"

python3 - "$DOCROOT/.htaccess" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
block = r'''# BEGIN MacMint SPA
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteCond %{HTTPS} off
  RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
  RewriteCond %{REQUEST_URI} !^/\.well-known/
  RewriteCond %{REQUEST_FILENAME} !-f
  RewriteCond %{REQUEST_FILENAME} !-d
  RewriteRule ^ /index.html [L]
</IfModule>
<IfModule mod_headers.c>
  Header always set X-Content-Type-Options "nosniff"
  Header always set Referrer-Policy "strict-origin-when-cross-origin"
  Header always set X-Frame-Options "SAMEORIGIN"
  <If "%{REQUEST_URI} =~ m#^/assets/#">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </If>
  <Else>
    Header set Cache-Control "no-cache"
  </Else>
</IfModule>
# END MacMint SPA
'''
text = path.read_text() if path.exists() else ''
text = re.sub(r'# BEGIN MacMint SPA.*?# END MacMint SPA\n?', '', text, flags=re.S).rstrip() + '\n\n' + block
path.write_text(text)
PY

printf '✓ Deployed. https://macmint.co\n'
