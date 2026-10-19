# Final homepage research and decisions — 2026-10-16

This is a focused iteration of the approved homepage, not a replacement design. Preserved brand headline, palette, illustrations, section order and working demos. No new major section was needed: the existing sections cover the product, example workflow, risk, privacy, developer use cases, FAQs and availability. Reused the final CTA as `#pricing` so the native app's existing pricing link has a meaningful target without inventing prices.

| Primary source reviewed | Observation | Applied decision |
| --- | --- | --- |
| [CleanMyMac](https://macpaw.com/cleanmymac) | Connects a category promise, product visuals, compatibility and clear trial/purchase routes. | Keep concrete cleanup tasks in the hero and visible macOS compatibility. Do not copy its ratings, scale or trial terms. |
| [DaisyDisk](https://daisydiskapp.com/) | Explains disk-space discovery and the user's decision before removal. | Keep the local interactive scan/review examples and concrete safety boundaries. |
| [Nektony App Cleaner](https://nektony.com/mac-app-cleaner) | Gives app-leftover cleanup a concrete use case and direct demonstration/download routes. | Explain what app leftovers are and let visitors review a working example. No awards, notarization or testimonials borrowed. |
| [NNGroup: Better Link Labels](https://www.nngroup.com/articles/better-link-labels/) | Link labels should predict the destination and set accurate expectations. | Change the unavailable-download CTA to “Check availability”; keep “Try the live demo”; add accurate sign-in and redemption routes. |
| [Baymard: Homepage UX](https://baymard.com/research-articles/ecommerce-homepage-ux) | Its ecommerce research cautions against distracting promotion and unclear scope. | Apply this cautiously to software: show the actual cleanup scope, retain a clear hero, avoid promo overlays and avoid extra sections without a distinct job. |
| [Next.js: Static Exports](https://nextjs.org/docs/app/guides/static-exports) | Static export emits HTML/CSS/JS usable on an ordinary web server. | Ship prebuilt files plus source and preserve the separately hosted account portal. |

Final changes: predictable availability labels; sign-in/redeem support; local-file privacy wording corrected for the latest account/license code; vague “Other cleaners / Varies” table replaced by useful MacMint expectations; existing phone selector, large tap targets and readable copy retained. No invented trust evidence, urgency or competitive claims.

## Measurement and limits

Primary current action: availability inquiry. Secondary action: interactive demo; existing customers can sign in. After installer/checkout launch, measure completed activation or purchase per eligible unique visitor, separated by mobile/desktop and acquisition source. Guardrails: failed downloads, account errors, refunds and support contacts. No analytics provider or tracking was added.

Hypothesis: clear next-step expectations, concrete product demonstrations and accurate requirements reduce uncertainty. No conversion dataset or randomized test was supplied, so no conversion lift or “better than every competitor” conclusion is claimed. Competitors' established release, support and reputation cannot be reproduced by copy. Product screenshots and user testing remain next validation steps before consumer launch.

Claims review: newer repository code supersedes the old “no cloud account / no network calls” wording. No prices or universal performance claims were added. Manual copy/claims review completed. The supplied Copy King `scripts/preflight.py` is absent; no automated copy preflight is claimed.

## Guided hero demo refinement

The hero's first action now starts an illustrative scan instead of claiming that a scan has already completed. A short Scan / Review / Restore sequence makes the next action clear. Editable selections, explicit cache rebuild consequences, an unchecked backup example, a session receipt and working example Restore let visitors test the product's control and recovery story. Native-app typography and readable phone rows improve inspection without changing the page's visual identity or adding a new section.

After Restore, visitors can explicitly open the existing availability dialog or explore app leftovers and exact duplicates. Availability remains accurate: no consumer installer or pricing is invented. The demo stays local to the browser and adds no telemetry. This is a conversion hypothesis based on reducing uncertainty; no measured conversion lift is claimed.
