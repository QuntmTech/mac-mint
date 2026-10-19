# MacMint marketing website

A responsive React + TypeScript homepage, built for Next.js. It is a separate web application; no native Swift sources, tests, scripts, or existing documentation are modified.

## Local development

Requires Node.js 22.13+.

```bash
cd marketing-site
npm install
npm run dev
```

Open http://localhost:3000.

```bash
npm run typecheck
npm test
npm run build
npm start
```

## Production

For Vercel, import this repository, choose `marketing-site` as the Root Directory and use the Next.js preset. Set `NEXT_PUBLIC_SITE_URL` to the final domain before building. No database, API keys, accounts, or analytics are required.

For another Node host: install dependencies, run `npm run build`, then run `npm start` on the platform's assigned port.

A separately packaged Vinext build hosts the Sites preview. Application components are shared; Sites hosting infrastructure is deliberately not added to the native app repository.

## Download configuration

`lib/product-config.ts` owns the release URL. `downloadUrl` is intentionally null: the repository had no published release assets when inspected. All Get MacMint buttons open an availability dialog with source and release links. Replace the value with a verified signed, notarized installer URL when ready. The CTA automatically becomes a download link.

## Documentation

See [HANDOFF.md](HANDOFF.md) for design, sections, exact file inventory, verification, factual sources, and release requirements.
