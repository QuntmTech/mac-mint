# Trustworthy cleanup implementation

Implementation branch: `feature/trustworthy-cleanup-flow` · [draft PR #22](https://github.com/QuntmTech/mac-mint/pull/22).

This implements the independent review's safety, access, AI, navigation, inspection and fulfillment work. It is a reviewable implementation, not a consumer release. No production backend, website, payment configuration, app feed or email settings were changed.

## Safety and recovery

The existing planner and executor remain the removal boundary. Keeper constraints survive covered selections; global keeper and ownership evidence also follows a file into reviews opened from another module. A broad rebuildable Cleaner target cannot override developer evidence requiring individual review. Execution repeats identity, file metadata, exclusions, app activity and keeper checks after sizing and managed-library inspection, immediately before movement.

Managed photo packages, their contents, and folders containing them cannot be moved through generic tools. Every filesystem scanner receives exclusions, including app and startup inventories. Path comparisons resolve parent aliases and use the volume's case sensitivity. Selecting an ancestor containing an exclusion is rejected. Removal authority and configured developer-cache roots also use volume-aware home and Applications boundaries: a differently cased sibling on a case-sensitive volume cannot inherit access to the real home. Restrictive category rules continue conservatively protecting case variants.

Journal writes are atomic and sync both the file and its directory. An initial or intent-write error stops movement. A post-move error stops the remaining work. The journal remains until History commits the operation by ID; repeated recovery cannot duplicate History. Unreadable journals remain on disk and appear as recovery warnings. An interrupted unknown destination is explicitly uncertain and never becomes an invented Trash receipt. History does not overwrite a corrupt store or evict pending receipts solely because 200 newer entries exist.

Restore runs filesystem moves off the UI thread, checks cancellation between items, never overwrites an occupied destination, and presents all conflicts with skip or alternate-folder choices. History and Restore remain reachable without a signed-in or entitled account.

## Desktop experience coverage

| Plan items | Implemented behavior |
|---|---|
| 1–5 | Local inspection before sign-in; coordinator gating for paid removal; consistent Quick Scan; progressive category results; coverage, exclusions, issues and scan age; deferred plans return for review after activation. Deep scans remain separate. |
| 6–8 | Seven main destinations, stable AI destination mappings, explicit shortcuts, contextual tabs and a persistent Review control. Folder state stays in the model; app search/sort/mode, cleanup search, startup search and photo tab use scene storage. Native scroll retention still needs interactive verification. |
| 9–14 | Rebuildable/effect language, owner/change-time evidence with explicit unknowns, conservative shared planning evidence, shared file selections and explicit keeps across inventories, deduplicated byte totals, and separate moved-byte/free-space explanations. |
| 15–20 | Editable final review, keep/exclude/reveal, bounded folder inspection, expanded consequences, per-receipt recovery status, complete conflict handling, background restoration and targeted removal of moved findings. AI advice is invalidated when its context changes. |
| 21–23 | Developer rebuild/redownload/review costs; command-only actions remain copyable inventory. Ollama identifiers are validated and shell-quoted with option termination. External storage is labeled inspection-only and generic ineligible locations cannot be selected. |
| 24–26 | Duplicate comparison, full paths/change dates, explicit keep choice, Quick Look/Space support and hard-link/shared-storage explanations. Photos has larger comparison, suggested keepers, local previews, explicit per-preview cloud permission, and indexed grouping that avoids weak similarity chains. |
| 27–30 | Dragged app inspection, Keep my settings, distinct update outcomes, accurate declared startup settings and possible owner, direct Login Items access, actionable performance explanations and normal Quit behavior. |
| 31–34 | Consent continuation, serialized payload preview, feature flag refresh, separate consent/plan/service errors, independent request errors, request cancellation, generation checks, and consent withdrawal while unavailable. A pending question survives navigation and a scan or consent interruption. AI actions retain navigation-only authority. |
| 35–36 | Added keyboard/accessibility actions, smaller window support, list alternative to the treemap, expanded smoke rendering, permission/recovery/space explanations, and a previewed diagnostic export with no names, paths, questions or file contents. Interactive accessibility verification remains required. |

Shared selection is scoped to filesystem inventories. Photos library asset deletion continues through PhotoKit and its own confirmation/recovery; it never enters the generic file-removal queue. App uninstall review retains its app-before-leftovers dependency.

Folder inspection lists at most 100 direct children and links to Finder for the full folder. Photo comparisons use fingerprints, not proof of image identity; users still choose what to keep. Synthetic grouping benchmarks do not measure PhotoKit decoding, iCloud behavior, or a complete real-world library scan.

## AI privacy and accounting

Automatic context is rebuilt from fixed storage categories, known app/tool identifiers and numeric summaries on both client and server. Arbitrary filenames, document-package names, project names, custom app labels and startup labels are omitted. Explain locations are allowlisted too. Typed questions and recent chat turns are transmitted separately as user-supplied text; the request preview includes them. File contents are never uploaded by these routes.

`ai_requests` and `ai_daily_budgets` reserve a user's request allowance and estimated token/currency capacity in a transaction before calling Anthropic. Actual input, output, cache-write and cache-read usage settles transactionally. Known uncharged failures release capacity and allowance; timeouts retain an uncertain reservation for operator reconciliation. Accounting failures surface as errors while the reservation remains. No prompt, personal summary, model answer or chat transcript is stored in these collections.

The default global limits are 3,000,000 tokens and USD 20 per UTC day; both are configurable via `app_config.ai` or `AI_DAILY_TOKEN_BUDGET` / `AI_DAILY_USD_BUDGET`. Explicit zero budgets stop calls. Per-user daily feature limits remain 150 explanations, 8 reviews and 30 questions. Pending and possibly charged attempts occupy allowance until settled. Models must exist in the explicit model/price allowlist; configured models actually control requests.

Rates were checked against [Anthropic pricing](https://platform.claude.com/docs/en/about-claude/pricing). Update the allowlist/rates before adopting another model or provider pricing mode. Currency accounting assumes standard global pricing, no tools, no fast mode and five-minute cache writes. Provider spending controls remain a separate operational backstop. Older usage rows lack cache measurements; on a mid-day cutover, reconcile provider history or start a fresh UTC budget cycle before enabling the new routes.

An operator can reconcile a timed-out reservation through `POST /api/macmint/admin/ai-reconcile`, supplying its request ID and verified provider usage, or explicit `confirm_no_charge`. Do not release unknown reservations merely because a client timed out.

## Backend, checkout and release rollout

Migrations are checked into `backend/pocketbase/pb_migrations`. The baseline contains collection metadata only, preserves existing collection IDs and auth settings, and does not include records or secret values. Later migrations add private budget/order collections, device deactivation tombstones, and release attestations. Rollbacks deliberately retain payment and usage evidence.

The test runtime is PocketBase 0.40.5, with its download checksum pinned in CI. Confirm the host runtime and test migrations on a backup in staging before applying them to production. Run `node --test backend/tests/*.test.cjs` and `POCKETBASE_BIN=/path/to/pocketbase python3 backend/tests/integration.py`. The integration suite creates and removes its own local database; its Stripe protocol fixture never contacts Stripe.

Device activation counts and saves in one transaction. Deactivation retains a tombstone, and explicit reactivation is required. Background verification reads the current device list rather than reactivating a removed Mac. New paid operations enforce the existing fourteen-day cached allowance through an injected clock; losing access never hides local recovery.

Checkout uses a server-only REST client because PocketBase's Goja runtime cannot load the Node SDK. It creates one-time hosted Checkout Sessions, preserves request idempotency, retrieves authoritative paid sessions, checks user/order/price/currency/amount/mode/quantity, and commits the redeemed license, entitlement and fulfilled order together. Both success event types are handled; unpaid sessions grant nothing, failed asynchronous payments are recorded, and concurrent duplicate events cannot extend access twice. Success-page visits never grant access. See [Stripe fulfillment](https://docs.stripe.com/checkout/fulfillment).

Before enabling checkout:

1. Use a separate Stripe sandbox and a restricted key with only the necessary Checkout Session and Price permissions. Store it in the host secret store as `STRIPE_RESTRICTED_KEY` (or the existing private `app_secrets` fallback named `stripe_restricted_key`). Store the matching webhook secret as `STRIPE_WEBHOOK_SECRET` / `stripe_webhook_secret`. Never put values in the repository, website or logs.
2. Register `/api/macmint/stripe/webhook` for `checkout.session.completed`, `checkout.session.async_payment_succeeded` and `checkout.session.async_payment_failed`. The implementation pins API version `2026-08-26.dahlia`; configure and test compatible event payloads.
3. Create a private `app_config` record keyed `commerce`, initially disabled. Use the already-approved price's `price_id`, `amount_minor`, `currency`, existing `plan`, `duration_days`, `max_devices`, and explicit `livemode`. No retail price was chosen or changed in this work. `amount_minor` must exactly match the Stripe Price’s integer `unit_amount`; the hosted Stripe page displays the currency and price. The server validates the offer against the retrieved one-time Stripe Price.
4. Supply a validated, notarized stable release. Checkout remains closed without one. Verify a fresh account's email before purchase. No automatic tax configuration was added; confirm registrations before changing that behavior.
5. Run the actual sandbox journey, failed/delayed payment, duplicate delivery, network loss after payment, receipt/support process and account transfer. Only then run a bounded, explicitly approved live canary.

SMTP credentials, sender-domain configuration and delivery were not available in this session. Configure the project's sender and secure credentials, then prove verification and password-reset delivery, expired-link behavior and rate limits in staging. The implementation does not claim that email delivery is complete.

Fresh installations now receive website verification/reset templates through a versioned migration; existing customized templates are preserved. The account page offers verification resend, delivery errors and a status refresh before checkout. Invalid reset links provide a direct route to request another link. `python3 backend/tests/service_integration.py` runs the actual PocketBase mailer against a loopback SMTP server and checks verification, reset, changed-password login, replay, tampering, expiry, and unknown-email privacy. This proves local mail generation and token handling, not external inbox delivery.

The main homepage exposes validated public downloads without account gating. The static `/home2` package intentionally has no consumer link yet; update its `productConfig.downloadUrl` and rebuild it only after the consumer artifact passes validation.

Consumer signing needs all six GitHub secrets listed in [RELEASING.md](RELEASING.md). The workflow distinguishes an ad-hoc prerelease from a complete Developer ID/notarized build, smoke-tests the package, validates stapling and Gatekeeper on consumer builds, and never automatically publishes an unvalidated feed entry. A published feed record requires `validated=true`, `notarized=true`, a SHA-256 and an HTTPS download URL. Set these attestations only after testing the actual downloaded artifact.

For a rollback, disable checkout and AI first, preserve journals/orders/reservations and back up the database. Do not restore older best-effort accounting routes while leaving AI enabled.

## Verification and remaining release gates

Automated evidence is recorded in the PR's checks: the portable core suite, native build/package/render checks, backend unit checks, real PocketBase transaction/webhook tests, website build/lint and demo interaction checks. Browser probes covered public pages, signed-out routing, checkout redirect rejection and retry identity, mobile login, updated privacy copy, zero analytics requests and zero JavaScript errors.

Local validation completed with 148 portable core tests, 14 backend unit tests, the real PocketBase integration suite, 35 demo interaction checks, website build/lint with no warnings, and production builds of both web packages. Both npm dependency audits reported zero known vulnerabilities. The macOS workflow also renders 25 screen states and checks shared selection, queue deduplication, keeper protection, inert AI links and navigation authority.

The [initial additional native validation](https://github.com/QuntmTech/mac-mint/actions/runs/38933989228) passed all 152 tests: 146 core tests plus six app integration tests. These exercise the actual macOS Trash adapter, verified receipt/history round trips, same-name collisions, occupied and symlink restore destinations, foreground expiry after fourteen days, and explicit reactivation of removed devices. Test token storage is isolated from Keychain; foreground verification also refreshes actual access in the application. Map Storage is available before sign-in through the menu as well as the main screen.

Authenticated AI staging checks now run through real PocketBase route/auth/transaction handling against a loopback provider fixture. They inspect serialized outbound payloads, account for cache tokens, enforce navigation bounds and effective model configuration, and cover feature/global kill switches, a zero currency budget, known uncharged failures, malformed output, missing accounting and timeouts. They do not contact Anthropic. A later account regression also verifies that an outstanding verification response cannot restore access after sign-out.

Four committed Playwright browser journeys cover signed-out routing, mobile password-reset privacy, verification delivery errors/resend/status refresh, checkout gating and redirect validation, stable checkout retry identity, untrusted success-return URLs, and recovery from expired reset links. Remote APIs are intercepted and unexpected external requests fail the checks. Account pages use system fonts and make no third-party font requests. The homepage demo's typecheck, 35 interaction checks and production build are also required CI jobs.

The benchmark workflow includes a 100,000-file fixture with actual developer dependency trees, 100,000 synthetic photo fingerprints, the combined scan workload, memory gates, cancellation gates and hashing comparisons. Consult the latest run for timings; hardware, image decoding, filesystem layout and existing data affect real performance.

The [validated macOS benchmark run](https://github.com/QuntmTech/mac-mint/actions/runs/38868907091) measured photo grouping at 5.01 seconds / 191 MB, developer scanning across 50 dependency trees at 2.51 seconds / 55 MB, and the combined workload at 13.79 seconds / 220 MB. Their cancellation latencies were 65 ms, 3 ms and 9 ms respectively; all benchmark gates passed. These are synthetic fixture measurements on the CI runner.

The connected Mac was offline when checked. CI rendering is not interactive journey testing. These gates remain outstanding:

- A downloaded Developer ID/notarized/stapled consumer installation and update failure/required-update behavior.
- Interactive disposable-Mac cleanup/restore, a nearly full real volume and connected-volume disconnects. Automated native receipt and restore-conflict tests now pass on the CI Mac; manual journeys remain outstanding.
- PhotoKit permissions, limited access, cloud-only assets, explicit cloud previews, synced deletion and Photos recovery.
- VoiceOver, full keyboard access, high contrast, reduced motion, dark mode, smaller windows and navigation scroll retention.
- Real Stripe sandbox, SMTP delivery, authenticated staged Anthropic requests, and a bounded live canary after those pass.

External-volume removal remains read-only until dedicated Mac evidence exists. Production deployment and consumer release are intentionally not represented as completed by this PR.
