# MacMint website implementation handoff

## Scope and source of truth

Reviewed native app commit `e75959edf784d504d00c68d619d632890dc971e9` on main. Read README, Package.swift, architecture/upgrade/research/validation docs, SwiftUI screens/view model, the core cleanup/scan/safety/hash/store logic, test coverage, resources and build script. No screenshots or final logo were supplied in that tree. GitHub Releases returned no releases. The existing app still uses placeholder native branding and an example bundle identifier; the website does not change those.

All changes in the GitHub repository are confined to `marketing-site/`. Existing Swift app, tests, docs and scripts remain untouched.

## Design system

- Canvas: `#FBFCF9`; white surfaces; subtle mint `#EAF5ED`.
- Primary emerald: `#12865A`; bright accent `#24B77A`.
- Charcoal text: `#1C2926`; body gray: `#68736E`; borders: `#E4E9E4`.
- System typography: Apple system / Segoe UI / Arial fallback. No remote font requests.
- Desktop headlines 54–92px; mobile headlines 36–51px. Section spacing about 85–110px desktop and 60–70px mobile.
- Buttons 9px corners; cards 11–20px; macOS-inspired window uses traffic lights, sidebar, storage ring, metrics and review rows derived from RootView, DashboardView and Components.
- Restrained tab entrances, hover elevation, conic scan ring and a scan sweep. Reduced-motion setting disables CSS animation/transitions and smooth scrolling. Simulated scan counters communicate progress without moving layout.
- Sparkle wordmark/icon is provisional, created as editable SVG/HTML; no competitor assets or Apple logo.

## Homepage architecture and conversion

1. Sticky navigation: features, workflow, safety, privacy and one Get MacMint action.
2. Outcome-led hero: exact brand line and direct product explanation; compatibility and safety reassurance.
3. Interactive product window: visitors can actually explore eight modules.
4. Factual trust strip: Trash-first, local operation, Swift/SwiftUI.
5. Storage clutter story: ordinary examples explain the need without fear claims.
6. Three-tab feature explorer: app leftovers, large files, exact duplicates; interactive demos make benefits concrete.
7. Scan → review → clean: switchable three-step walkthrough.
8. Safety story: normal Trash, protected personal folders, review-by-default for valuable categories; toggle cleanup boundaries.
9. Developer cleanup: selectable illustrative categories, sizes and risk levels; explains rebuild tradeoff.
10. Startup inventory, exclusions and history: concise secondary-feature cards link to their product demo modules.
11. Privacy centerpiece: current base app behavior, separated from website privacy notes.
12. Approach comparison: generic other-cleaner column says “Varies”; no competitor allegations.
13. Ten native FAQ disclosures with FAQ JSON-LD.
14. Final CTA and complete footer, support, source and clearly labeled legal/status dialogs.

No invented customers, ratings, media endorsements, speed benchmarks, pricing, free-download claims or notarization. Smart Scan coordinates cleanup, app inventory and startup inventory; large-file and duplicate scans remain separate modules. Browser-cleanup copy targets caches only. Developer Archives/DeviceSupport/Gradle/simulator caches require review. Automatic personal-folder protection is explicitly distinct from user-reviewed personal-file tools. Moving files to Trash is not misrepresented as immediately freeing disk space.

## Dynamic behavior

- Native demo sidebar switches Smart Scan, Cleaner, Applications, Large Files, Duplicates, Startup Items, History and Exclusions.
- Simulated scan progress, cancellation, safe/review filters, search, per-row selection, selected totals and explicit confirmation.
- Demo cleanup records a session history; a new scan resets example data.
- Fictional app selection, related-file checkboxes, exact-ID vs review confidence, calculated size, uninstall confirmation and reset.
- Large-file size threshold, sort direction, explicit per-file review, simulated Trash and reset.
- Duplicate verification stages, opt-in copy selection, last-copy protection, simulated Trash and reset.
- Developer-cache checkboxes and live selected total. Simulator caches start unselected.
- Mobile navigation with Escape dismissal, keyboard-accessible feature and workflow tabs, native FAQ details, dialog Escape/backdrop dismissal and focus restoration. Utility shortcuts control the demo through React state rather than a DOM-position query. Cleanup search has a no-results state and a Clear filters action.
- Page demos use React state; no native access, backend, tracking, filesystem writes or persistent user records.

## Mobile decisions

Breakpoints at 1100, 800, 600 and 374px. Below 600px the demo sidebar becomes a labeled native select exposing all eight modules, and the product surface becomes one readable column. Marketing body copy is 14–15px; key demo actions and navigation targets are at least 44px tall. Small cleanup row icons are removed to leave room for names, risk labels and sizes. No shrunk desktop sidebar. Feature stories stack copy before examples; app mockups use separately adjusted fonts and controls. Workflow becomes three compact choice buttons over one explanation. Trust strip becomes 2×2, utilities stack, privacy art sits below copy, footer becomes two columns. Primary hero action remains early; initial product visual begins in the first phone viewport at typical widths. No sticky bottom bar obscures content.

## Exact files

- `marketing-site/app/page.tsx`: route composition.
- `marketing-site/app/layout.tsx`: semantic shell, metadata, canonical, OG/Twitter and favicon.
- `marketing-site/app/globals.css`: design tokens, full responsive styling, focus states and reduced motion.
- `marketing-site/components/macmint/home-page.tsx`: homepage sections and page interactions.
- `marketing-site/components/macmint/product-demo.tsx`: source-informed native application demonstration.
- `marketing-site/components/macmint/feature-demos.tsx`: app/large-file/duplicate examples.
- `marketing-site/components/macmint/dialog.tsx`: centralized download/status/privacy flows.
- `marketing-site/components/macmint/brand.tsx`: editable brand treatment.
- `marketing-site/components/macmint/content.ts`: FAQ and illustrative data.
- `marketing-site/lib/product-config.ts`: release link, compatibility, source/support URLs.
- `marketing-site/public/favicon.svg`, `og.svg`, `og.png`, `robots.txt`, `sitemap.xml`: owned brand assets and discoverability.
- `marketing-site/package.json`, `package-lock.json`, `tsconfig.json`, `next.config.ts`, `postcss.config.mjs`, `.gitignore`, `.env.example`: standalone web tooling and configuration.
- `marketing-site/tests/compile.cjs`, `tests/interaction-checks.cjs`: meaningful React interaction checks, isolated compiled output.
- `marketing-site/README.md`, `HANDOFF.md`: setup and implementation notes.

## Verification

TypeScript validation passed. Sites/Vinext production build passed. React interaction checks passed 30 assertions covering all navigation anchors, single h1, disclosures, mobile menu open/close, availability dialog, truthful release state, scan start/cancellation, opt-in review defaults, selected totals, confirmation disclosure, demo cleanup/history, duplicate last-copy protection, file filtering/removal, and app uninstall.

The supported `control-browser` skill is unavailable in this session. No browser server was started, and rendered screenshot, hydration, console, overflow and viewport checks were NOT completed. This is a real verification limit, not a claim that visual QA passed. Before wider release, check 1920×1080, 1440×900, 1280×800, 768px, 430×932, 390×844 and 375×812 in a browser. Native macOS tests were not rerun because no native app code changed.

## Release requirements

- Final brand assets and native app name/bundle identity.
- Real macOS build, launch and interactive validation.
- Developer ID signing, notarization and published installer.
- Confirm pricing and any distribution/update policy.
- Final legal privacy and consumer terms, plus support contact/process.
- Real reviews only when available.
- Set `NEXT_PUBLIC_SITE_URL`, update robots/sitemap when choosing a permanent public domain, and populate `downloadUrl` only after verifying the release.


## Focused UX and copy refinement — 2026-10-16

Preserved the approved brand headline, mint/charcoal palette, section order, illustrations, product demos and native app code. No redesign or new marketing sections.

- Hero names the three concrete cleanup jobs, with “Review what goes. Keep what matters.” Release status now appears directly below hero/final CTAs. Secondary action explicitly says “Try the live demo.”
- App-uninstall copy connects app leftovers to the review action. Workflow explains scan/review/cleanup without implying one scan runs the separate large-file and duplicate modules. Final CTA offers a direct route back to the demo.
- Desktop keeps its composition with slightly tighter hero spacing and larger supporting copy. Phone layouts use readable section/FAQ text, a labeled module selector, larger controls and simplified cleanup rows. Tablet copy also gets minimum readable sizes.
- Availability dialog has its own accessible heading and a direct demo route. A new first FAQ answers download availability. GitHub Releases was checked again on 2026-10-16 and returned zero published releases.
- Regression checks now cover Escape menu dismissal, keyboard workflow selection, accessible panel labels, all eight phone demo options, utility shortcuts, final demo reset, and cleanup no-results recovery.

Copy strategy: assume storage-conscious Mac owners comparing cleaners; make review/control tangible through the demo. Main objections are accidental removal and download uncertainty. Keep Get MacMint as the primary availability action; the live demo is a lower-commitment supporting route. No prices, measured outcomes, testimonials, urgency or release promises were added. Native capabilities remain tied to the previously reviewed app source.

Verification for this refinement: 30 React interaction assertions passed in both the isolated Sites test runtime and standalone package. TypeScript passed in both packages. Sites/Vinext production build and standalone `npm run build -- --webpack` passed. `git diff --check` passed. Browser visual/viewport, hydration, console, overflow and real-device checks remain unverified because the supported control-browser capability is unavailable. These are conversion hypotheses, not measured conversion gains. Manual claims/clarity review completed; the supplied Copy King `scripts/preflight.py` is absent, so no automated copy preflight is claimed.

Source continuity: https://macmint.amplycoindustries.chatgpt.site is the existing owner-private Site. The standalone website stays under `marketing-site/` on `marketing/macmint-homepage-20261016`, reviewed in draft PR https://github.com/QuntmTech/mac-mint/pull/2. Do not merge or change native Swift sources as part of this iteration.
