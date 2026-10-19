# Public-readiness review — 2026-10-19

This pass reviews the desktop, portable safety core, account/AI services, purchase website and distribution boundary. Automated evidence covers its stated fixtures, not every native interaction, the user's live iCloud library, or real provider charges.

## Work checklist

- [x] Implement recurring Checkout, verified invoice/subscription synchronization, absolute access periods, cancellation and payment recovery.
- [x] Implement customer-owned billing management, explicit recurring/trial terms and server-authorized repurchase.
- [x] Review desktop account expiry, cleanup/recovery, photo/resource handling, AI session boundaries and updates.
- [x] Complete the new regression, browser and native CI gates and record delivery evidence below.
- [ ] Complete actual Stripe-account acceptance, external inbox delivery, production service deployment and consumer signing/installation.

## Approved offer

US$39.99 per year, three-day free trial, payment method collected, one trial per MacMint account. Three Macs per account retains the existing allowance. `backend/commerce.subscription.example.json` records these terms with checkout disabled and provider IDs blank. The intended Stripe business account remains unverified. Do not silently provision this in an arbitrary account or describe fixture payments as live purchases.

## Findings fixed in this pass

| Finding | Trigger and consequence | Change / regression |
| --- | --- | --- |
| Malformed expiry could become unlimited access | Backend date parsing returned null for a nonempty invalid date; desktop offline logic also accepted an unparseable expiry when `active` was true. | Invalid dates fail closed. Offline access additionally requires consistent Pro/active fields. Backend and core expiry regressions. |
| Recurring billing was absent | Existing `duration_days` represented one-time license duration, with no renewals, cancellation, trial or billing portal. | Separate private subscription ledger, verified provider objects, absolute invoice/trial periods, owner-bound portal and immutable order terms. Recurring unit/integration/browser regressions. |
| Delayed AI availability could outlive sign-out | A public availability response could republish enabled status after local sign-out; request continuation could cross a replaced session. | Capture session generation, reject canceled/stale status, and recheck cancellation/session before the authenticated AI send. Native delayed-response regressions. |
| Library screenshots were always empty | PhotoKit IDs are synthetic URLs, so filename detection cannot classify them; the library scan explicitly supplied an empty screenshot list. | Carry PhotoKit `photoScreenshot` metadata into fingerprints and populate the tab; screenshots stay out of blurry suggestions. Core regression and native compilation. |
| Photo mutation could overlap a scan through a controller call | UI controls were disabled, but the library-removal controller lacked scan/preparation guards. | Both review and removal refuse overlapping work while retaining selections; native controller regression without real PhotoKit deletion. |
| Restricted accounts could pay for unusable recurring access | Revoked/suspended base access deliberately blocks subscriptions, but a new/resumed checkout could still collect money. | Reject subscription checkout before any provider call and give a support action. Unit regressions cover both statuses. Existing customers can still open billing. |
| Delayed-payment failure could allow duplicate recurring checkout | Failure could arrive before the completion event and mark an order replaceable while its subscription still required recovery. | Resolve/synchronize the authoritative subscription first. An incomplete subscription keeps checkout pending; missing identity remains retryable/uncertain. Unit and real PocketBase protocol tests cover reordered events. |
| Demo scan duration grew when timer callbacks were delayed | Progress counted callbacks, so busy/throttled browsers stretched a short illustrative scan. | Compute progress from elapsed monotonic time; a delayed-callback interaction regression proves catch-up without extra timers. |
| Whole-item inventories traversed excluded descendants | Downloads and Removed Apps sized an ancestor even with an excluded child; Cleaner retained a separate literal path comparison. | Skip whole-item ancestors containing exclusions before sizing, skip excluded roots before enumeration, and use the shared volume/alias-aware matcher. Scanner regressions retain eligible siblings and avoid excluded-root access errors. |

## Review map and preserved boundaries

- **Selection, normalization, execution and restore:** `OperationPlan`, `OperationExecutor`, `SafetyPolicy`, `FileSystem`, `HistoryStore`, `RecoveryService`, `RestoreCoordinator`, and `AppViewModel+Operations`. Keeper constraints survive ancestor collapse; final checks follow expensive preparation; exclusions/managed libraries/mounted volumes remain protected. Durable intent precedes movement and History commits precede journal acknowledgment. Restore never overwrites and remains independent of paid access. Existing fault-injection, symlink, identity, exclusion, conflict and crash-recovery tests are rerun.
- **App uninstall:** `AppScanner`, app-data categories, Applications and uninstall-plan construction. Exact bundle-ID data is distinct from shared/uncertain matches; another installed copy makes shared data conservative; data depends on successful bundle removal. MacMint and nested helpers cannot be uninstalled through the wrong path. No root helper, installer receipt purge or system-wide metadata deletion was added.
- **Performance and RAM:** `SystemMonitor`, `ResourceSampler`, `AppTamingController`, `AppTaming`, preview caches and photo request bridge. Sampling uses leases and a serial utility actor, minimum intervals/thermal backoff, identity-bound same-user actions and bounded caches. Auto Tame remains opt-in, two targets maximum, reversible, time-bounded, foreground-aware and exception-aware. It adjusts Darwin background priority, not hard CPU/RAM quotas. No new polling loop, memory purge or image-content AI upload was added. Existing native lifecycle, taming, memory and startup gates are rerun; these do not reproduce the user's exact 19,282-photo memory case.
- **Photos and organization:** `PhotoLibraryService`, `PhotoThumbnailRequest`, review deck, bulk selection, grouping, organization store/suggestion lifecycle. Local preview fallback and explicit cloud opt-in remain; unseen deck images cannot be queued blindly. Group keepers remain protected. Organization is shallow/bounded, preview-first, same-volume, identity-checked, exclusive rename with durable apply/undo evidence. AI supplies names/opaque IDs, never executable filesystem authority.
- **Account/AI:** `AccountStore`, portable account policy, consent/request lifecycle and automatic context; backend effective entitlement, private collections, reservations/model allowlist/cache-token accounting. Recovery and useful local inspection remain available without sign-in. Trial expiry is absolute and cannot grow into the fourteen-day offline grace. Periodic verification does not reactivate a removed device. AI actions remain navigation-only; automatic context stays category/identifier-only, while typed questions and separately approved organization names are described explicitly.
- **Website/distribution:** checkout retry identity, same-user billing, safe redirect origins, visibility-aware finite polling, verification/reset routes, install guidance, persisted setup, contextual permissions, release checker, DMG/ZIP/notarization scripts and release publication guards. Billing UI supports light/dark styling and refreshes trial eligibility before a new order. Checkout creation checks the configured portal before collecting payment. No consumer feed/release attestation was invented.

This is a source/risk-path review plus executable regressions. VoiceOver, permission dialogs, Apple-signed Gatekeeper behavior, actual photo sync/deletion and sustained real-world CPU/RAM profiling still require native acceptance. A source review cannot establish that every native interaction is functional.

## Service state verified read-only at the start

- Live backend healthy; `/api/macmint/checkout/config` and `/api/macmint/admin/commerce/readiness` return 404. The production collection list lacks checkout orders and subscription migrations.
- SMTP is disabled with placeholder configuration. Real external verification/reset delivery is unproven; the local SMTP integration test covers the code only.
- Stripe is installed/enabled, but no Stripe account tools are exposed in this session. No business account, Price, restricted key or webhook registration has been verified.
- Repository signing credentials were absent in the preceding installation pass. Developer ID signing, notarization/stapling and real quarantined-download acceptance remain release gates.
- The available CloudPod interface does not expose the orientation's fixed release/migration deployment recipe. Do not partially swap dependent production hooks or bypass protected deployment via arbitrary shell commands.

No production billing mutation, real charge, refund, email delivery, consumer release tag or public release-feed publication is part of the local review evidence.

## Validation and delivery

Local portable core: **185 tests passed**, zero failures. Backend: **53 Node tests passed**, plus disposable PocketBase transaction/migration/webhook, authenticated AI/local SMTP, and recurring/trial/portal integration checks. Installer notarization failure checks: **4 passed**. Homepage interaction checks: **50 passed**. Website build and lint passed. Native source parse, workflow lint and whitespace checks passed.

All **44 browser tests passed**, including recurring/trial disclosure, light/dark and phone billing presentation, safe portal redirects, payment recovery and server-authorized resubscription. Visual inspection confirmed the billing layouts. The [backend/website CI](https://github.com/QuntmTech/mac-mint/actions/runs/39208436914) passed.

The [real Stripe sandbox contract report](validation/stripe-sandbox-2026-10-19.json) records **nine passed checks**, including the first annual invoice paid with a Stripe test token, with zero live operations. This is separate from the disposable backend webhook tests. It does not certify owner-account setup, real webhook transport, annual time advancement or external email. The optional operator probe is source-controlled; no credentials or hosted-session URLs are committed.

The initial browser run exposed two assertion/copy mismatches, a generic billing-address error and delayed mobile demo progress; these were corrected. Native CI also caught `/var` versus `/private/var` URL comparisons in the two new scanner tests; the tests now compare resolved locations. [Native builds at `03da749`](https://github.com/QuntmTech/mac-mint/actions/runs/39208436969) passed 258 cases on each macOS 15/26 runner, with one expected skip and zero failures. Packaging repeats have two expected skips. Startup, idle-loop, rendering, ZIP/DMG packaging and fresh-runner downloaded-package/installer checks all passed. Subsequent billing/operator/documentation edits do not alter those native sources.

In the isolated startup fixture, idle readings were 0.1–0.9% of one core with the menu bar off/on and 1.2–2.6% with Performance visible. The 2,000-image memory fixture reported 0–4 MiB incremental peak. These short fixture readings are not a sustained energy benchmark, total app RAM budget, or acceptance of the user's actual photo library.

See [Stripe setup](STRIPE_SETUP.md) for real-account acceptance and the still-closed approved offer.
