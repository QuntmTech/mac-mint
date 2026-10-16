# MacMint — ChatGPT Sites homepage V1

Complete homepage package: editable Next.js/React/TypeScript source and prebuilt HTML, CSS, JavaScript and owned assets in `site/`. Existing native app, backend and `web/` account portal are separate.

- **Deploy:** read [HANDOFF.md](HANDOFF.md). Publish the **contents of `site/`**, including `_next/`; no Node server is needed at runtime.
- **Edit:** `npm ci`, then `npm run dev` (Node 22.13+).
- **Rebuild:** `npm run typecheck`, `npm test`, then `npm run build`. A build regenerates `out/` and tracked `site/` together.
- **Domain:** defaults to `https://macmint.co`; set `NEXT_PUBLIC_SITE_URL` before building if changing domain. Account links are separately configured in `lib/product-config.ts`.
- **Preview:** https://macmint.amplycoindustries.chatgpt.site (owner-private).

See [CRO_RESEARCH.md](CRO_RESEARCH.md) for the final research and decisions, and [IMPLEMENTATION_MANIFEST.md](IMPLEMENTATION_MANIFEST.md) for the package inventory. No VPS deployment is performed by adding this folder.
