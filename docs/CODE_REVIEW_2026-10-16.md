# MacMint implementation review — 2026-10-16

This review started from `c6ffc45`, after the initial implementation had passing automated checks. It found additional defects. The fixes remain on `feature/trustworthy-cleanup-flow` in [draft PR #22](https://github.com/QuntmTech/mac-mint/pull/22); production has not been deployed or changed.

The conclusion is **improved and testable, with consumer-release gates still open**. Passing tests do not establish zero defects, complete native interaction coverage, or a market-leading product. The earlier implementation should not have been described as fully functional.

## Findings and fixes

### R01 — P1: delayed account actions could undo sign-out

**Trigger:** sign out while sign-in, activation or remote device release is awaiting a response. Verification already had a generation check, but the other actions did not. A late activation could restore the active phase, and a slow sign-out could clear a newer sign-in. Repeated submit could start overlapping authentication.

**Fix:** capture the session generation before requests, check it after asynchronous boundaries, serialize account submissions, clear local access immediately, order device release after pending activation, and order a subsequent activation after release. Old errors cannot clear a newer session. Verified access is held in memory instead of rereading its cache on every UI check. Cache and Keychain save failures are visible; a verified online session remains usable when disk persistence fails. Offline cache records are bound to the stored token with a SHA-256 fingerprint, so another session cannot inherit their allowance.

**Evidence:** [AccountStore](../Sources/MacCleanerApp/AccountStore.swift), [AccountLifecycleTests](../Tests/MacCleanerAppTests/AccountLifecycleTests.swift). Deterministically delayed authentication, activation, verification and deactivation; duplicate submit; offline expiry; deactivated devices; failed cache writes; restart with a matching or different stored token. An older, unbound account cache requires one successful online verification before offline access works again. Existing cleanup receipts are unaffected.

### R02 — P1: restore movement preceded durable History evidence

**Trigger:** restore several files, then crash before the batch's single History update. Alternate-folder restores also discarded their actual destinations. A History write failure after movement left the same gap.

**Fix:** a restore coordinator durably writes an intent before each move, verifies source identity, records the actual physical destination in History per item, and acknowledges the intent only after that commit. Restart recovery is idempotent and requires identity proof at the destination. It preserves corrupt and uncertain evidence. A missing Trash item alone never means restored. History now reveals alternate destinations. The folder-panel callback rechecks whether another operation started while the panel was open.

Restores keep the no-overwrite rule, reject symlink escapes from Trash and managed photo-library destinations, and repeat parent/identity checks after preparing directories. Cross-volume restore is explicitly unavailable for now: copy-and-remove changes file identity and cannot use this recovery proof reliably. Users can choose another folder on the Trash item's volume.

**Evidence:** [RestoreCoordinator](../Sources/MacCleanerCore/RestoreCoordinator.swift), [RecoveryService](../Sources/MacCleanerCore/RecoveryService.swift), [RestoreDurabilityTests](../Tests/MacCleanerCoreTests/RestoreDurabilityTests.swift). Tests cover an unwritable intent, History failure after a completed alternate-folder move, repeated recovery, corrupt evidence, uncertain destinations, occupied destinations and a symlink below Trash pointing to an unrelated file. Existing native tests also exercise real macOS Trash receipts and restore collisions.

### R03 — P1: old uncertain moves could lose their only remaining explanation

**Trigger:** an interrupted move has no provable Trash destination, its cleanup journal commits to History and is acknowledged, then more than 200 newer operations accumulate. Retention protected pending receipts, but this uncertain operation had none.

**Fix:** retain structured unresolved paths independently of receipts, preserve them through History updates, exempt them from ordinary retention, and show them explicitly in History with inspection guidance.

**Evidence:** [HistoryStore](../Sources/MacCleanerCore/HistoryStore.swift), [OperationExecutor](../Sources/MacCleanerCore/OperationExecutor.swift), `testUncertainMoveEvidenceSurvivesHistoryRetentionWithoutAReceipt` in [RestoreDurabilityTests](../Tests/MacCleanerCoreTests/RestoreDurabilityTests.swift).

### R04 — P1: damaged exclusions silently became an empty list

**Trigger:** saved exclusions cannot be decoded or read. The loader returned an empty set, and add/remove could overwrite the damaged store with a partial replacement.

**Fix:** checked loading distinguishes absence from corruption. Editing cannot overwrite an unreadable store. All scan entry points and new paid removal wait for readable exclusions. Settings explains the failure; an explicit reset preserves the original file before writing a new list. Local History and Restore remain accessible.

**Evidence:** [IgnoreStore](../Sources/MacCleanerCore/IgnoreStore.swift), [AppViewModel](../Sources/MacCleanerApp/AppViewModel.swift), [ExclusionPersistenceTests](../Tests/MacCleanerCoreTests/ExclusionPersistenceTests.swift). Tests prove corrupt bytes survive failed reads/edits and an explicit reset preserves a backup. A native controller test in [AccountLifecycleTests](../Tests/MacCleanerAppTests/AccountLifecycleTests.swift) starts with corrupt exclusions, verifies blocked scanning/new access, and restores an actual fixture file through the app coordinator without paid access. App stores and journals are isolated from real user data.

### R05 — P1: a mounted volume below home passed a path-only boundary

**Trigger:** mount a different filesystem at a directory under the home folder, then select that mount or an ancestor. The path was inside home even though the data belonged to another filesystem.

**Fix:** removal authority compares filesystem device identities, and folder-content preflight refuses nested mounts. A home folder that itself lives on another volume still uses its own volume as its authority anchor. Read-only mapping remains available. Execution still checks identity and policy immediately before movement.

**Evidence:** [SafetyPolicy](../Sources/MacCleanerCore/SafetyPolicy.swift), [FileSystem](../Sources/MacCleanerCore/FileSystem.swift), [NativeVolumeTests](../Tests/MacCleanerAppTests/NativeVolumeTests.swift). Disposable macOS CI mounts a uniquely named, case-sensitive 128 MB sparse image. It exercises case-distinct home siblings, direct and ancestor mount selections, same-volume restore restrictions and a disconnected stale plan. The fixture also fills only its own bounded image to actual ENOSPC and checks that failed journal persistence prevents movement. No existing disk is filled, reformatted or detached. The image fixture is required in the main CI test step and explicitly skipped in an ordinary local run.

### R06 — P2: checkout retry depended on temporary provider idempotency

**Trigger:** retry an older request after Stripe has pruned its idempotency key. The route POSTed another session before discovering that its ID conflicted with the saved order. Expired and completed sessions had no distinct response.

**Fix:** retrieve a saved session and reuse only an open, unexpired, correctly bound session. Completed/processing and expired attempts have separate responses. The browser prevents another attempt after a completed response and offers account refresh; an expired attempt can restart explicitly. Old orders whose session ID never committed cannot POST beyond the conservative retention window. Inconsistent lifetime/duration offer configuration closes checkout.

**Evidence:** [payment helpers](../backend/pocketbase/pb_hooks/macmint_payments_lib.js), [payment unit tests](../backend/tests/payments.test.cjs), [real PocketBase integration](../backend/tests/integration.py), [browser journeys](../web/tests/account.spec.ts). Tests cover session reuse without a POST, expiry/completion, old unbound orders, signatures, unpaid-to-paid transitions and eight concurrent duplicate fulfillment events. These use a local Stripe protocol fixture, not Stripe's sandbox.

Stripe documents that keys may be pruned after at least 24 hours and reused keys can create new requests: [idempotent requests](https://docs.stripe.com/api/idempotent_requests). Session states and expiry are defined in [Checkout Sessions](https://docs.stripe.com/api/checkout/sessions).

### R07 — P2: valid JSON was mistaken for a valid AI answer

**Trigger:** the provider returns `null`, an array, an empty answer, missing fields or wrong field types with HTTP 200. JSON parsing succeeded; routes could fail generically or render empty content after charging usage.

**Fix:** validate the structural schema before accessing the answer. Invalid responses produce the controlled upstream error while settling reported usage, including cache tokens. Advisory enum values still pass through conservative allowlist normalization. A model-provided destination cannot select, mutate or execute anything.

**Evidence:** [AI helpers](../backend/pocketbase/pb_hooks/macmint_ai_lib.js), [AI unit tests](../backend/tests/ai.test.cjs), [authenticated route integration](../backend/tests/service_integration.py). Wrong-shape responses are checked through actual PocketBase auth/routes/transactions and a loopback provider. No Anthropic requests are made by these tests.

### R08 — P2: consent previews could drift from the submitted context

**Trigger:** build a preview, show consent, then change results or chat context before accepting. Review and Ask rebuilt the request after consent, so the displayed snapshot could differ from the transmitted one.

**Fix:** freeze the actual request and generation before consent. The continuation uses that request. Scan invalidation clears pending actions and dismisses stale consent; generation checks also protect the continuation after the sheet yields. Onboarding now describes category summaries and typed questions explicitly, replacing its remaining “anonymized summaries” claim.

**Evidence:** [AppViewModel AI flow](../Sources/MacCleanerApp/AppViewModel+AI.swift), native controller tests in [AccountLifecycleTests](../Tests/MacCleanerAppTests/AccountLifecycleTests.swift). One test compares the decoded preview to the actual serialized request captured by the transport after changing chat state before consent. Another invalidates the scan generation and verifies that consent cannot resume the old request or erase the draft. A human review of the complete consent-sheet journey remains a release gate; controller tests are not presented as an interactive UI test.

### R09 — P2: Photos used an undocumented size property and did not cancel preview requests

**Trigger:** library analysis read resource sizes using KVC for `fileSize`; preview tasks did not cancel their PhotoKit request when the view disappeared. Deletion could also silently operate on a subset if some selected identifiers were no longer available.

**Fix:** remove undocumented KVC. On the supported macOS versions, library items show “Size unavailable” and no speculative byte estimate on deletion. Folder-file sizes remain measured. A cancellation bridge handles cancellation before registration, synchronous callbacks and repeated callbacks, including explicit cloud previews. Deletion requires the complete selected identifier set to remain available.

**Evidence:** [PhotoLibraryService](../Sources/MacCleanerApp/PhotoLibraryService.swift), [PhotoRequestTests](../Tests/MacCleanerAppTests/PhotoRequestTests.swift). Callback races have native tests. Real permission dialogs, iCloud downloads, library deletion and Recently Deleted recovery still require interactive testing. Apple's public [`dataSize`](https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva) API has macOS 27 availability; it cannot be assumed on the current macOS 14+ baseline. Apple documents explicit request cancellation in [`cancelImageRequest`](https://developer.apple.com/documentation/photos/phimagemanager/cancelimagerequest(_:)).

### R10 — P3: equivalent app versions had inconsistent hashes

**Trigger:** `1`, `1.0` and `1.0.0` compared equal but synthesized different hashes, violating the contract for dictionary keys and sets. No current user-visible failure from hashed version collections was established.

**Fix:** hash the same normalized components that equality compares, preserving the displayed version string.

**Evidence:** [ReleaseChecker](../Sources/MacCleanerCore/ReleaseChecker.swift), `testEquivalentVersionsBehaveConsistentlyInSetsAndDictionaries` in [TrustRegressionTests](../Tests/MacCleanerCoreTests/TrustRegressionTests.swift).

## Verification scope

The review examined account lifecycle and capability boundaries, planning and execution, journals and History, restore, filesystem/exclusion rules, Photos, AI consent/client/server/accounting, Checkout/webhook handling, website retry behavior, release/version handling, native packaging and CI. It builds on the earlier scanner, navigation, ownership, developer-activity and privacy review. It is not a line-by-line certification of every dependency or an interactive audit of every screen.

Local checks and the corresponding CI evidence are summarized in [implementation coverage](TRUSTWORTHY_CLEANUP_IMPLEMENTATION.md) and the PR checks. Distinguish real local filesystems/PocketBase/SMTP from simulated upstream services, and synthetic photo fingerprints from decoding a real photo library.

## Required before consumer release

1. Run the signed, notarized, stapled downloaded build through Gatekeeper and a fresh-user installation. The ad-hoc CI artifact does not prove this.
2. Configure real sender credentials/domain settings and prove verification/reset delivery to external inboxes. Local SMTP capture proves generation and token behavior only.
3. Run actual Stripe sandbox Checkout and verified webhook fulfillment, including delayed/failed payments, retries and account transfer. Then use a separately authorized, bounded live canary.
4. Run authenticated Anthropic staging checks with bounded budgets and compare billed usage, malformed/failure handling and kill switches to the ledger. Fixtures cannot certify the provider integration.
5. Exercise Photos permissions, local/cloud previews, deletion sync warnings and Recently Deleted recovery in a disposable real library. Callback unit tests do not prove PhotoKit or iCloud behavior.
6. Exercise VoiceOver, keyboard-only traversal, contrast, reduced motion, small windows and per-screen context/scroll retention with a person using the app. Render smoke tests establish launch/layout execution, not usability or accessibility.
7. Finish a complete download → free scan → purchase → activation → editable review → cleanup → restore journey, including sleep/offline/device-transfer and interrupted-operation cases. The connected interactive Mac was unavailable during this work.

The new sparse-image checks provide real evidence for case sensitivity, mounts, ENOSPC and a stale disconnected plan in CI. They do not establish external-volume Trash/restore support across APFS, network storage, removable disks or every disconnect timing. External-volume removal and cross-volume restore remain unavailable.

Read-only readiness checks during this review confirmed that production SMTP is disabled with a placeholder host, repository signing secrets are absent, and the connected interactive Mac is offline. Environment inspection used masked values. No test emails, payments, provider requests or deployment changes were sent to production.

No consumer-release approval or “fully functional” claim should be inferred from this review. The remaining work is specific verification and operational setup, not a promise that automated checks have exhausted every failure mode.
