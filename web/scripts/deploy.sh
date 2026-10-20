#!/bin/bash
# Builds the site and publishes it to the cPanel docroot for macmint.co.
# cPanel-managed files (.htaccess directives, .user.ini, php.ini, .well-known, cgi-bin) are preserved;
# the MacMint block in .htaccess is replaced on every deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCROOT="${DOCROOT:-/home/qrkit/macmint.co}"
cd "$ROOT"

if [[ $# -eq 0 ]]; then
  printf '▶ Building site...\n'
  npm run build
  bash "$ROOT/scripts/build-homepage.sh"
elif [[ $# -ne 1 || "$1" != "--publish-built" ]]; then
  echo "Usage: $0 [--publish-built]" >&2
  exit 2
fi

python3 - "$ROOT/dist" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ('index.html', 'account-app.html', '404.html', 'robots.txt', 'sitemap.xml', '_next/static', 'assets'):
    if not (root / name).exists():
        raise SystemExit(f'Incomplete site build: {name} is missing.')
home = (root / 'index.html').read_text()
account = (root / 'account-app.html').read_text()
if 'id="root"' in home or '/home2/_next/' in home or 'id="root"' not in account:
    raise SystemExit('The homepage/account build has not been assembled correctly.')
PY

BACKUP_ROOT="$ROOT/../.build/site-deploy-backups"
mkdir -p "$BACKUP_ROOT"
BACKUP="$(mktemp -d "$BACKUP_ROOT/site.XXXXXX")"
tar -czf "$BACKUP/docroot.tar.gz" -C "$DOCROOT" .
printf '▶ Previous site backed up to %s\n' "$BACKUP/docroot.tar.gz"
printf '▶ Publishing to %s...\n' "$DOCROOT"
DOCROOT_MODE="$(stat -c '%a' "$DOCROOT")"
rsync -a --delete --delay-updates \
  --exclude '.htaccess' --exclude '.user.ini' --exclude 'php.ini' \
  --exclude '.well-known' --exclude 'cgi-bin' --exclude 'downloads' \
  dist/ "$DOCROOT/"
chmod "$DOCROOT_MODE" "$DOCROOT"

python3 - "$DOCROOT/.htaccess" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
block = r'''# BEGIN MacMint site
DirectoryIndex index.html
ErrorDocument 404 /404.html
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteCond %{HTTPS} off
  RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]
  RewriteRule ^home2/?$ / [L,R=301]
  RewriteRule ^(login|signup|account|forgot-password|reset-password|verify-email|start|welcome|download)/?$ account-app.html [L]
</IfModule>
<IfModule mod_headers.c>
  Header always set X-Content-Type-Options "nosniff"
  Header always set Referrer-Policy "strict-origin-when-cross-origin"
  Header always set X-Frame-Options "SAMEORIGIN"
  # The original request line survives the internal rewrite to account-app.html.
  <If "%{THE_REQUEST} =~ m#^[A-Z]+ /(start|welcome|download)/?[?\s]#">
    Header always set Referrer-Policy "no-referrer"
  </If>
  <If "%{REQUEST_URI} =~ m#^/(assets|_next/static)/#">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </If>
  <Else>
    Header set Cache-Control "no-cache"
  </Else>
</IfModule>
# END MacMint site
'''
text = path.read_text() if path.exists() else ''
text = re.sub(r'# BEGIN MacMint (SPA|site).*?# END MacMint \1\n?', '', text, flags=re.S).rstrip() + '\n\n' + block
path.write_text(text)
PY

printf '✓ Deployed. https://macmint.co\n'
