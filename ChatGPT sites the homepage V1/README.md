# MacMint — ChatGPT Sites homepage V1

Main homepage package: editable Next.js/React/TypeScript source and prebuilt HTML, CSS, JavaScript and owned assets in `site/`. It serves `/`; the former `/home2` address redirects home. The native app and backend are separate; the `web/` account portal is published alongside this export.

- **Deploy:** read [HANDOFF.md](HANDOFF.md). `bash web/scripts/deploy.sh` from the repository root builds and publishes both this homepage and the account portal, with a docroot backup. No Node server is needed at runtime.
- **Edit:** `npm ci`, then `npm run dev` (Node 22.13+).
- **Rebuild:** `npm run typecheck`, `npm test`, then `npm run build`. A build regenerates `out/` and tracked `site/` together.
- **Domain:** defaults to `https://macmint.co`; set `NEXT_PUBLIC_SITE_URL` before building if changing domain. Account links are separately configured in `lib/product-config.ts`.
- **Preview:** https://macmint.amplycoindustries.chatgpt.site (owner-private).

See [CRO_RESEARCH.md](CRO_RESEARCH.md) for the research and decisions, and [IMPLEMENTATION_MANIFEST.md](IMPLEMENTATION_MANIFEST.md) for the original package inventory.
