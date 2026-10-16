# VPS handoff — MacMint homepage V1

## Start here

Canonical package: `ChatGPT sites the homepage V1/` on the `main` branch of https://github.com/QuntmTech/mac-mint. The homepage is a static export with working client-side demos. Upload **everything inside `site/`**, including `_next/`, images, SVGs and metadata. No Node service, database or homepage API is required at runtime.

## Preserve the existing account portal

The current repository already contains a Vite account app in `web/`. Its routes are `/login`, `/signup`, `/account`, `/forgot-password`, `/reset-password` and `/verify-email`. Homepage account links intentionally point to `https://macmint.co/login` and `/signup`.

For the existing cPanel layout (default docroot in `web/scripts/deploy.sh`: `/home/qrkit/macmint.co`):

1. Back up the current docroot, `.htaccess` and account app before publishing.
2. Keep the existing account app's `index.html` as **`account-app.html`** in the docroot, and preserve its `/assets/` files, runtime configuration and backend.
3. Copy the **contents** of this package's `site/` into that docroot. Do not delete `/assets/`, `/downloads/`, `.well-known`, `cgi-bin` or cPanel-managed files.
4. Merge the rules in `deploy/apache-cpanel.example.conf` into the existing `.htaccess`, replacing the old **MacMint SPA** fallback. The six account routes must serve `account-app.html`; the homepage must serve the new `index.html`. Keep the host's existing HTTPS/cPanel rules.
5. Test the homepage and all six account URLs directly, including reset/verify URLs with query parameters. Confirm CSS/JS return 200, demos work, keyboard/dialog behavior works and no phone viewport overflows. Keep account cookie, API/CORS and email link configuration unchanged.

**Important:** the existing `web/scripts/deploy.sh` uses `rsync --delete`. Do not run it unmodified after a combined deployment: it can remove the new homepage and `_next/`. Update that deployment workflow to preserve/re-publish both applications. For Nginx, see `deploy/nginx.example.conf` as a routing reference; adapt it to the actual vhost/TLS configuration.

## Rebuild / change domain

```bash
cd "ChatGPT sites the homepage V1"
npm ci
npm run typecheck
npm test
NEXT_PUBLIC_SITE_URL=https://macmint.co npm run build
```

Deploy the regenerated `site/`. `npm run build` generates HTML, CSS, JS, robots and sitemap; the same domain sets canonical/OG metadata. No `npm start` is used for this static export.

## Release and product truth

`lib/product-config.ts` owns account, source, support and future download URLs. No installer is linked and this page has no checkout. Set `downloadUrl` only to a verified installer. The current native app requires an account and active plan; network checks handle account/license/device activation, while files and scan results stay local. Product review used native source commit `095f2e6b11bd7adc571c5d6f79ff1370f582c32f`. Demos are illustrative and do not access local files. Do not add pricing, a trial, refunds, reviews, speed claims or launch dates without confirmed product evidence.

## Validation / remaining work

TypeScript, React interaction tests, production builds and static export asset checks are recorded in `IMPLEMENTATION_MANIFEST.md`. Browser viewport, hydration, console and real-device checks remain unverified because the supported browser-control capability is unavailable. No VPS login, server mutation or production-domain deployment was performed. Launch the consumer site only after checking the real installer/purchase flow, final privacy/terms, TLS and the account routes above.
