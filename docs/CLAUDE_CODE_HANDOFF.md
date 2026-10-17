# MacMint — handoff to Claude Code for independent review

Desktop micro polish followed the original implementation checkpoint; see section 18 for the additional changes to review.

A further interruption/lifecycle pass is described in section 19, including new regression tests and photo-deck resume/completion captures.

Prepared 2026-10-16, America/New_York. This document accompanies delivery to `main` through [PR #22](https://github.com/QuntmTech/mac-mint/pull/22).

Claude Code: please independently review the work described here. Treat these statements as claims to verify against the source and executable evidence, not as proof that the product is finished. Prioritize data safety, recovery, privacy, account boundaries, concurrency, native usability, and resource consumption. Report concrete findings with severity, file/line, trigger, consequence, and a regression or verification method. Separate confirmed defects from untested hypotheses and product limitations. Another green test run alone is not the requested review.

## 1. Repository and review boundaries

- Repository: `QuntmTech/mac-mint`, https://github.com/QuntmTech/mac-mint.
- Actual source checkout on this shared Linux host: `/home/qrkit/src/mac-mint`.
- `/home/qrkit/macmint.co` is a deployed website directory, **not** the source checkout. Do not edit the deployed site instead of the repository.
- Implementation branch: `feature/trustworthy-cleanup-flow`.
- Full implementation checkpoint before this handoff: `9214f5d0ca90aecfa90d4e88eb5ebe9bf17d229c`.
- Previous `main` / original review baseline: `05ecb65417f2d0a7a3c16748a2abd39284c7cf91`.
- Before this document, the branch contained 60 commits ahead of that baseline, with 151 changed files, 9,771 insertions and 2,035 deletions. This is substantial work and warrants review by subsystem.
- The user explicitly requested that all this work and the handoff be pushed to `main`. PR #22 records the final merge SHA; use the current `origin/main` after fetching, rather than assuming an older local branch is current.
- `VERSION` remains `0.9.0`. No new version tag or consumer release was created by this work.

Useful comparison commands, after preserving any existing local work:

```bash
git fetch origin
git status --short --branch
git log --oneline --decorate -12 origin/main
git diff --stat 05ecb65417f2d0a7a3c16748a2abd39284c7cf91..origin/main
git log --reverse --oneline 05ecb65417f2d0a7a3c16748a2abd39284c7cf91..9214f5d0ca90aecfa90d4e88eb5ebe9bf17d229c
```

Build artifacts, `.build/` logs/previews, dependency directories, credentials, and disposable fixtures are not source deliverables and should not be committed. All source, test, workflow, and documentation changes belong in Git. Do not force-push or rewrite the implementation history to perform this review.

## 2. User intent and decisions to preserve

The user wants a polished native desktop app that serves everyday Mac owners and developers equally, feels coherent, and is friendly to CPU/RAM. They requested a thorough implementation review, a major front-end redesign including light/dark appearance, and strategic expansion around process control, fast photo decisions, and AI file organization.

Decisions already made:

1. Useful scanning/inspection should work before sign-in. Recovery must remain available after sign-out, expiry, or service failure.
2. AI is optional. Local rules and execution policy remain authoritative.
3. For AI organization, the user explicitly chose **“Preview proposed names and moves, then approve.”** Do not reinterpret this as consent to silently rename, move, or continuously upload names.
4. Retain SwiftUI, the portable core, PocketBase, and existing licensing semantics. Pricing changes were not part of this work.
5. Keep unsupported external-volume mutations unavailable until their identity/disconnect/recovery behavior has dedicated evidence.
6. Favor making the cleanup journey trustworthy over adding more top-level modules.

The user referred to Auto Tame as though it already existed. Source review found monitoring and ordinary Quit, not an automatic throttling engine. The implemented pass adds guarded process controls and lighter sampling. **Auto Tame is still future work.**

## 3. Architecture and environment

- Native app: Swift 6, SwiftUI/AppKit, minimum macOS 14.
- `Sources/MacCleanerCore`: portable Foundation policy, scanners, planning, execution abstractions, recovery, account DTO/client, AI DTO/context, organization, hashing and photo analysis.
- `Sources/MacCleanerApp`: views, MainActor coordination, account/session state, native Trash, PhotoKit, Quick Look, monitoring, packaging smoke harness and synthetic UI fixtures.
- `Sources/MacMintBench`: non-shipping performance tool.
- `backend/pocketbase/pb_hooks`: PocketBase/Goja routes and helpers. Do not assume Node SDKs can run inside Goja.
- `backend/pocketbase/pb_migrations`: versioned collection/rule migrations; no credential or user-record dump.
- `web`: Vite/React/TypeScript account, purchase, recovery and download website.
- `ChatGPT sites the homepage V1`: separate Next.js homepage/demo package, including the static `/home2` source.
- Existing desktop service URL: `https://macmint.cloudpod.pro`; CloudPod project slug `macmint`.
- There is no privileged helper or arbitrary shell-command execution authority in the desktop implementation.

The implementation host was Linux. Portable tests run locally; AppKit/SwiftUI/PhotoKit semantic compilation and native filesystem evidence come from macOS CI. `swiftc -frontend -parse` on Linux is only syntax checking, not native compilation.

The connected interactive Mac was last checked through Desktop Commander and was offline. CI therefore does not substitute for the outstanding interactive journeys described below.

## 4. Safety and recovery changes

### Shared selection and execution policy

The existing planner/executor remain the removal boundary; they were extended rather than replaced.

- Duplicate keeper constraints survive parent-folder collapse. Example: selecting `Album/copy.jpg` plus `Album`, when the protected keeper is also inside `Album`, cannot authorize removal of the containing folder.
- Similar-photo keeper and owner/activity evidence follow a path across Cleaner, Developer, Storage, Large Files, Duplicates and the final queue. A broader Cleaner target cannot override more conservative developer evidence.
- Active Xcode/DerivedData ownership and missing activity evidence are handled conservatively. “Unknown” is not positive proof of inactivity.
- Shared file selection propagates between filesystem inventories, preserves explicit keeps, and deduplicates queue/confirmation totals through planning. Photos library assets remain a separate PhotoKit flow.
- Generic removal centrally protects managed photo libraries, their descendants, and folders containing them. Direct scan roots are checked too.
- All filesystem scanner families receive exclusions, including app/startup inventories. Path comparisons resolve parent aliases and respect the volume's case sensitivity.
- Selecting an ancestor that contains an excluded descendant is rejected rather than silently discarding the exclusion.
- Home/Applications authority includes volume identity and case-aware boundaries. A mounted disk below home does not inherit home-volume mutation authority.
- Identity, metadata, owner/running-app, keeper, exclusion, and managed-library checks occur after expensive preparation, immediately before movement. Please inspect remaining TOCTOU assumptions rather than interpreting this as a claim that every possible race is eliminated.
- App uninstall retains its app-before-leftovers dependency.

Primary files: `OperationPlan.swift`, `OperationExecutor.swift`, `SafetyPolicy.swift`, `FileSystem.swift`, `DuplicateRemovalVerifier.swift`, `OwnerResolver.swift`, `Recommendations.swift`, `CleanupCatalog.swift`, and `AppViewModel+Selection.swift` / `+Operations.swift`.

### Durable Trash history and restore

- Journal writes are atomic and sync the file and directory. A journal/intent failure stops movement; a post-move persistence failure stops remaining work and retains evidence.
- Executor journals survive until the app durably commits the report to History. Recovery/History append is idempotent by operation ID.
- A missing original path alone is not proof that an item reached Trash. Unknown outcomes remain uncertain; no receipt is invented.
- Corrupt journals/history are preserved. History cannot overwrite an unreadable store or evict pending receipts/uncertainty merely because 200 newer operations exist.
- Restore writes an intent before movement and records actual restored destinations, including alternate folders, before acknowledging its journal.
- Restore runs away from the UI thread, supports cancellation between safe item boundaries, and never overwrites an occupied destination. Bulk restore exposes all conflicts and alternate-folder choices.
- Cross-volume restore is intentionally unavailable; copy/remove does not preserve the identity proof this implementation relies on.
- Damaged exclusions no longer become an empty exclusion set. New scans/paid removal wait for usable exclusions; explicit reset preserves the damaged file. Local recovery remains usable.
- The Trash card now opens **Review Trash in Finder**. It does not present `~/.Trash` size as proof of the scope of Finder's global Empty Trash action.

Primary files: `HistoryStore.swift`, `RestoreCoordinator.swift`, `RecoveryService.swift`, `IgnoreStore.swift`, `TrashBinService.swift`, `HistoryView.swift`, `OperationViews.swift`.

## 5. Account, access, navigation and existing feature improvements

### Local access and account lifecycle

- Fresh/offline users can inspect local data, view coverage, set exclusions, use History, and restore supported receipts without paid activation.
- New paid removal is checked in the coordinator. Activation preserves the selection/deferred plan and returns it for review.
- Fourteen-day cached access is evaluated with a testable clock. Background verification cannot silently extend it indefinitely.
- Cached access is session-bound. Delayed sign-in/activation/verification/deactivation responses cannot undo sign-out or overwrite a newer session.
- Device release is ordered after pending activation; explicit reactivation is required for a removed device. Background verification does not silently activate it again.
- Cache/Keychain persistence failures are visible. Tests isolate token storage from the real Keychain.

Primary files: `AccountStore.swift`, `AccountViews.swift`, `Account.swift`, `AppViewModel.swift`, `RootView.swift`, `AccountLifecycleTests.swift`.

### Coherent journey and advanced inspection

- One **Quick Scan** vocabulary across onboarding, menus, menu bar and overview; deeper mapping/hashing/photo/project scans remain separate.
- Progressive results and coverage distinguish findings from unreadable/excluded/cloud-only data. Scan age and issues remain visible.
- Seven primary workspaces: Overview, Cleanup, Storage, Apps, Photos, Developer, History. Settings/Help stay in the sidebar footer.
- Storage/large files/duplicates, app/uninstall/update/startup inventory, and Overview/Performance retain contextual destinations. Existing AI destination IDs map into the reorganized presentation.
- Keyboard shortcuts are explicit rather than enum-order derived. Destination/tab state and relevant search/sort settings are retained; complete native scroll retention still needs verification.
- Final review supports keep/remove/exclude/reveal and bounded folder inspection. Consequences/recovery are conditional and readable, rather than a blanket “everything is undoable.”
- Duplicates gained comparison, full locations/dates, keeper choice, Quick Look/Space support, and explanations of hard links/shared storage.
- Apps gained drop-to-inspect and Keep my settings; uncertain/shared data remains distinguished.
- Developer inventory explains rebuild, redownload and manual-recovery costs. Tool commands remain copied instructions, not execution authority. Ollama arguments are validated/quoted with option termination.
- Updates distinguish not checked, failed, unsupported, up to date and available. Startup reports declared facts rather than claiming a plist's Disabled flag proves live state.
- Help covers permissions, recovery and why free space may not change. Diagnostic export previews contents and omits personal names/paths/questions/file bytes by default.

## 6. Native UX/UI redesign

The design pass starts at `42ee70e` and runs through the compact-inspector/accessibility refinements at `2d4020c`.

- `DesignSystem.swift` and `Components.swift` provide semantic surfaces, text, borders, selection and status colors, responsive `PageHeader`, `SurfaceCard`, `IconTile`, `SearchField`, and button styles.
- Appearance supports **System / Light / Dark**, persists via one `AppAppearance.storageKey`, and applies to the main scene and menu-bar scene; sheets inherit appearance.
- Light uses a pale neutral canvas/white cards; Dark uses graphite surfaces/brighter mint text. Surfaces are opaque, Increased Contrast strengthens boundaries, and motion respects Reduce Motion.
- `AppearanceTests` measures primary/status text contrast against five surface backgrounds in both appearances, including white primary-button text.
- `RootView` has a compact mint sidebar, disk-space footer, command search, contextual workspace bar, persistent Review badge, and account/help access.
- The detail region is explicitly bounded by a `GeometryReader`; responsive headers keep their intrinsic height. These fixes prevent split-view minimum sizing from placing important controls outside a compact window.
- The overview gives Quick Scan, available space, focused tools, recommendations, coverage and trends a clearer hierarchy.
- Cleaner/app/developer/storage/history/photo views share headers, spacing, status language and compact control layouts. The app inspector's review actions use a fixed bottom inset and remain visible.
- Assistant, consent, onboarding, Help, review sheets and menu bar use the same visual system. AI prose links are inert; constrained navigation actions remain separate controls.

See `docs/NATIVE_INTERFACE.md` for the capture/layout details. Screenshots and passing contrast checks do not certify VoiceOver, Full Keyboard Access or every screen-reader label.

## 7. New photo review and resource controls

### Photo review deck

`PhotoReviewDeck.swift` adds a large one-photo-at-a-time preview, progress, comparison, swipe/arrow choices and Undo choice.

- Left queues removal; right keeps. A gesture does not execute deletion.
- A protected keeper cannot be queued; the user chooses another keeper through comparison first.
- Undo choice restores the previous selection decision. It is distinct from undoing an already-completed filesystem move.
- A new `PhotoScanResult.generation` resets deck state. Removing unrelated findings does not reset the deck.
- Folder-file removal uses the reviewed Trash planner; library deletion uses PhotoKit's confirmation and Recently Deleted, with the sync consequence disclosed.
- Library analyses/default previews request no network download. Cloud preview is an explicit per-preview action. Pending preview requests are canceled where supported, and canceled results are not published.
- Supported public PhotoKit APIs do not expose reliable resource byte sizes here. Undocumented KVC was removed; unavailable library sizes stay unavailable.
- PhotoKit revalidates the selected assets and protected keepers inside the deletion change block.
- Photo tabs remain valid when changing from a folder to the library.

`SimilarPhotos.swift` uses indexed candidate grouping rather than all-pairs comparisons, bounds members against their suggested keeper rather than merging weak similarity chains, and adds lookup indexes for group membership, filename candidates and selected IDs. Similarity remains a judgment; exact duplicates remain the content-hashing module.

### Preview memory

`PreviewImageCache.swift` implements an explicit LRU because an NSCache cost limit is advisory. Photo previews have a 32 MiB estimated budget/count 64; Quick Look has 16 MiB/count 96. Views clear retained images on disappearance. Modification/identity/size/cloud settings participate in appropriate keys, including PhotoKit modification dates.

Folder decoding is serialized in a utility actor, checks cancellation before opening queued work, and requests downsampled thumbnails capped at 1,400 pixels. These are cache budgets, **not** a 48 MiB whole-app guarantee; visible images, decoder buffers, metadata, PhotoKit and AppKit use additional memory. Real-device profiling remains required.

Primary files: `AppViewModel+Photos.swift`, `AppViewModel+Selection.swift`, `PhotoLibraryService.swift`, `PhotosView.swift`, `PhotoReviewDeck.swift`, `PreviewImageCache.swift`, `FileThumbnail.swift`, `SimilarPhotos.swift`.

## 8. Process controls and lightweight monitoring

`SystemMonitor.swift` / `PerformanceView.swift` now provide a searchable running-app list, memory/CPU sorting, PID, memory footprint, and guarded Quit/Force Quit.

- Inventory covers regular applications and their main processes, not every system/helper process. 100% app CPU equals one core; the system gauge covers all cores. Activity Monitor is linked for the broader process view.
- Quit is normal application termination. Force Quit has a separate destructive confirmation. A true result means the request was sent, not that exit completed.
- Before action, validate the NSRunningApplication identity/object, bundle ID, kernel process birth time and current user ownership. PID alone is insufficient.
- Protect MacMint/self, PID 1, Finder, Dock, loginwindow, SystemUIServer, Control Center and unknown bundle identities.
- Sampling runs in a serial utility actor, with idempotent UUID leases per visible consumer, no overlapping sample, and cancellation/generation checks.
- The Performance scene releases its lease while inactive/disappearing and has Pause/Resume. The menu-bar popover owns a separate lease. No leases means no polling timer.
- Normal requests are at least three seconds; the views currently ask for four. Low Power Mode raises the floor to eight seconds; serious/critical heat raises it to twelve, with 25% timer tolerance.
- Process CPU divides XNU rusage CPU deltas by Mach absolute-time wall deltas; it does not assume those counters are nanoseconds on Apple silicon.
- Each sampling call releases acquired host-port send rights. A native regression checks repeated sampling does not accumulate port references.
- Sampling does not load app icons for every candidate.

This is not Auto Tame, a CPU cap, automatic suspension, automatic force quit, or memory purging. Those claims must not appear in the product until an appropriate subsystem and native lifecycle evidence exist.

## 9. Preview-first Organizer

### Scope and UI

`Organization.swift`, `OrganizerView.swift`, and `AppViewModel+Organization.swift` implement the first bounded version:

- Entry through Storage → Organize; separate Organization history is also available from main History.
- Shallow inspection of at most 500 direct entries, retaining at most 100 eligible files and 24 existing destination subfolders plus the root.
- Supported regular local document/media/archive types only. Skip symlinks, hard links, placeholders, hidden/unsupported files, managed libraries, packages, app data and repositories; obey exclusions.
- Same home-volume authority; a mounted disk below home remains unsupported. An unreadable root is an error, not an empty inventory.
- Local file-type suggestions use existing folders. Manual edits and local suggestions work offline.
- The current version renames **files** and moves them into **existing** folders. No recursive reorganization, folder renaming, directory creation, file-content extraction or watched-folder automation is implemented.
- Each row shows original/proposed name, destination, reason and local validation. Editing deselects the row. Nothing is selected automatically. Apply requires explicit final approval.

### Name sharing and provider authority

Organization has separate per-request consent. The frozen preview contains exactly the file/destination-folder names and opaque IDs sent to the backend/Anthropic. Names can reveal personal information; the copy says so. No full root path or file content is sent by this route. This exception must not be confused with existing category-only automatic cleanup/chat context.

`AIOrganizationRequest` supplies IDs/names. The provider can return a known file ID, known destination-folder ID, proposed basename and reason. It cannot supply URLs, shell commands, policy changes or execution. Both backend and local code validate the proposal; schema compliance alone does not grant authority.

Canceling, closing the view, changing folders/exclusions, sign-out or consent withdrawal invalidates the pending request. Sign-out does not clear the local-operation busy state while an already-authorized move is finishing.

### Movement and recovery

- New Apply checks access, exclusion readiness and operation overlap in the app coordinator, including after asynchronous scheduling. UI visibility is not the authorization boundary.
- Snapshot identity, size/mtime, link count, root/destination identity, case-sensitive path comparisons, exclusions, name/extension validity, destination collisions and duplicate destinations are checked.
- Durable records precede movement and every moving/undoing intent. Operation IDs make retries idempotent.
- Descriptor-relative exclusive rename uses `renameatx_np(..., RENAME_EXCL)` on Darwin and `renameat2(..., RENAME_NOREPLACE)` on Linux. Opened directory identities and source metadata are checked immediately before movement; resulting identity and directory sync are checked afterward.
- A post-move persistence/sync/identity uncertainty retains its intent for reconciliation rather than manufacturing a successful receipt.
- Organization history is its own durable store, not a fake Trash receipt. States include prepared, moving, moved, undoing, undone, failed and uncertain; UI explains “Not applied,” “Undo available,” or “Needs verification.”
- Corrupt records remain on disk and are reported while readable records remain available. There is a Finder path to the recovery records.
- Undo is local/free, works after expiry/sign-out and with unreadable exclusions, and refuses changed files or occupied original locations.
- Successful and uncertain outcomes invalidate affected findings, selections and storage maps. Unrelated photo/file choices remain. Reconciliation also runs after errors when readable evidence exists.

### Server rollout

`POST /api/macmint/ai/organize` uses `macmint_organization.js`, the shared AI accounting helper, structured output, plan checks, strict ID/name/extension handling and a separate daily request allowance of eight.

`1792109300_organization.js` adds its usage counter and defaults `features.organize` to false. Both client and server require explicit true; absent means off. The current default model is the allowlisted Haiku configuration. Do not enable this feature in production merely because the key already exists or these tests pass.

## 10. Existing AI privacy and service reliability

- Cleanup Explain/Review/Ask automatic context uses storage categories, allowlisted identifiers and numeric summaries on client and server. Arbitrary document-package/project/folder/app labels and personal names are omitted.
- Typed questions/history are sent as the user's text and shown in the preview. These features do not send file contents.
- Consent resumes the pending action, freezes the exact payload, and invalidates stale work across scans, new chat, sign-out and withdrawal. Explanation/review/chat errors are independent.
- Feature status refreshes before requests/foreground use and distinguishes service off, offline, plan required, quota and failure states. Consent can be withdrawn when the server is unavailable.
- Existing AI actions remain navigation-only and prose links inert. The Organizer is an explicit reviewed proposal workflow, not a general autonomous tool runner.
- Usage is reserved transactionally before Anthropic: user allowance, estimated tokens and currency. Settle actual input/output/cache-write/cache-read usage. Known uncharged failures release; possibly charged timeouts retain uncertain reservations for operator reconciliation.
- Models must be in an explicit price allowlist, and configured effective models actually control requests. Defaults are 3,000,000 tokens and USD 20 per UTC day; explicit zero closes calls. Per-user limits are 150 Explain, 8 Review, 30 Ask, and 8 Organize per day.
- Do not free uncertain reservations without verified usage/no-charge proof. The admin reconciliation route is `POST /api/macmint/admin/ai-reconcile`.
- Accounting stores contain usage/operation evidence, not prompts, chat transcripts or personal filename inventories.

Primary files: `AIAssistant.swift`, `AppViewModel+AI.swift`, `AccountStore+AI.swift`, `AIViews.swift`, `macmint_ai.pb.js`, `macmint_ai_context.js`, `macmint_ai_lib.js`, `macmint_organization.js`.

### Existing Anthropic key

The user asked whether their key was already integrated. A read-only CloudPod query verified a nonempty `app_secrets` entry named `anthropic_api_key`; only record ID/name were requested, never its value. Public configuration had Ask, Explain and Review enabled. The server supports `ANTHROPIC_API_KEY` with private `app_secrets` fallback. No key belongs in the desktop bundle or this handoff, and no replacement key was requested.

This verifies configuration, not a successful paid provider request. Live AI organization remains disabled pending deployment/staging/canary. Recheck current configuration before rollout; the live backend was not updated by these source commits.

## 11. Backend, purchase, email, website and distribution changes

### PocketBase and accounts

Versioned migrations:

1. `1792108800_baseline.js`: schema/rule baseline, preserving existing IDs/auth configuration; no user/secrets export.
2. `1792108900_reservations.js`: private accounting/reservation collections, cache/currency fields and deactivation tombstones.
3. `1792109000_orders_and_release_gates.js`: order/fulfillment and consumer release attestations.
4. `1792109200_account_mail_templates.js`: verification/reset templates, preserving existing customization.
5. `1792109300_organization.js`: organizer allowance and default-off flag.

PocketBase 0.40.5 and its checksum are pinned in CI. Test migration against a backup of the target runtime/data in staging before touching production. Rollbacks preserve orders/reservations/recovery evidence; do not treat an old hook-only directory as a reproducible database deployment.

### Payments and release eligibility

- Server-only Stripe REST integration suitable for Goja. No key in the website/app.
- Hosted one-time checkout, verified raw-body webhook signatures, authoritative session retrieval and exact order/user/price/currency/amount/mode/quantity validation.
- Fulfillment/license/entitlement commits are transactional and idempotent under duplicate/concurrent delivery. Unpaid or failed asynchronous sessions do not grant access. A success-page visit grants nothing.
- Saved Checkout sessions are retrieved/reused; completed and expired sessions have distinct recovery. Old missing-session retries cannot depend indefinitely on Stripe's idempotency-key retention.
- Checkout remains gated on a validated consumer release and verified email. Retail pricing was not changed.
- Stripe key/webhook secret, actual sandbox journeys and live canary remain operational work. See `TRUSTWORTHY_CLEANUP_IMPLEMENTATION.md` for exact commerce configuration and provider version assumptions.

### Mail and web

- Verification/resend/status refresh, password reset/error recovery and website token links were improved.
- Vite account flows validate redirects/retry identity, handle completed/expired checkout attempts, and expose validated public downloads before login.
- Homepage/demo privacy copy and scan wording were aligned, analytics collection disabled, and fictional-demo boundaries retained.
- Browser tests intercept remote APIs and reject unexpected external requests. System fonts avoid third-party font requests on account pages.
- Both frontend packages' dependency/lockfile updates, build/type/lint checks and interaction coverage are in Git. Older generated/deployed assets are not proof that production runs the new source.
- Local SMTP fixtures prove actual PocketBase mail generation/token behavior. They do not prove delivery to an external inbox. SMTP was disabled at the earlier live read-only check; sender credentials/domain delivery still need operational validation.

### Signing and release

The release workflow runs only on `v*` tags. Ordinary `main` pushes run tests/build artifacts; they do not automatically deploy hooks/websites or publish a consumer release.

Consumer release needs Developer ID signing, notarization, stapling and downloaded Gatekeeper evidence. Required secret names are `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`; their values were not available in this implementation session. Do not paste them into a transcript or source.

Without complete signing inputs the release workflow identifies an ad-hoc prerelease. Feed records require validation/notarization, SHA-256 and an HTTPS URL. Do not set attestations before testing the actual download. No tag, feed publication, backend restart, payment configuration change or website deployment was performed here.

## 12. Independent implementation review already performed

`docs/CODE_REVIEW_2026-10-16.md` records ten additional findings found after the first implementation was already green:

| Finding | Correction / review focus |
|---|---|
| R01: delayed account actions undo sign-out | Session generations, ordered release/reactivation, session-bound cached access, visible persistence errors. |
| R02: restore moved before durable history | Write-ahead restore intents, per-item actual destinations, retained evidence and idempotent recovery. |
| R03: uncertainty evicted with old history | Retain unresolved paths beyond normal history cap and expose them. |
| R04: corrupt exclusions became none | Checked loading, preserved corrupt bytes, block new scans/removal, leave local recovery available. |
| R05: nested mounted volume inherited home authority | Volume-aware policy plus disposable case-sensitive/full-volume native fixtures. |
| R06: old checkout retries depended on retained idempotency keys | Retrieve/reuse saved session and distinguish completed/expired/old-unbound states. |
| R07: valid JSON accepted as valid AI answer | Validate response structure and settle provider usage even for malformed output. |
| R08: consent preview/request drift | Freeze exact payload and invalidate pending consent on context changes. |
| R09: undocumented Photos size and uncanceled previews | Public API behavior, unavailable sizes, cancellation and PhotoKit keeper recheck. |
| R10: equal versions had unequal hashes | Normalize version hashing consistently with equality. |

The subsequent UI/feature pass also fixed offscreen compact controls, unreliable native captures, per-swipe photo lookup costs, unbounded image caches, host-port reference accumulation, organizer preparation races, uncertain-result invalidation, and permission-denied inventories appearing empty.

Some intermediate CI runs failed while catching compile/layout/test-fixture mistakes. Examples include a nonexistent contrast environment key, AppKit lists omitted by ImageRenderer alone, titled snapshot windows changing bounds, asynchronous layout preferences arriving late, and native tests trying to set a private loading state/use paths instead of UUIDs. These were corrected. Review final-SHA results, not an arbitrary older red or green run. The native test now exercises real corrupt-exclusion loading instead of bypassing it.

## 13. Verified evidence at implementation checkpoint 9214f5d

| Check | Evidence and limitation |
|---|---|
| Portable core | 165 tests, zero failures locally on Linux. |
| Native macOS | 195 core/native cases, one expected skip, zero failures. [Push run](https://github.com/QuntmTech/mac-mint/actions/runs/38960425939), [PR run](https://github.com/QuntmTech/mac-mint/actions/runs/38960431192). Native count includes core cases; do not add 165 and 195 as unique tests. |
| Native mounted fixtures | Real case-sensitive 128 MB image; direct/ancestor mounted-volume rejection, case boundaries, bounded actual ENOSPC, disconnected plans, cross-volume restore refusal, organizer authority/full-disk refusal. Only test-created images/files are filled/moved/detached. |
| Packaging rerun | 195 cases, two expected skips: case-dependent host check and expensive mounted-image fixture. The main CI invocation explicitly runs the image fixture. |
| Native visual evidence | 85 states covering light/dark destinations, populated/compact workspaces, review, onboarding/menu/help/account, photo deck and Organizer entry. Push capture took 22.1 s. Geometry assertions check important controls remain in viewport. |
| Downloaded ZIP | Separate runner checks SHA-256, extracted signature and 85-state launch/render smoke, 11.5 s in the recorded push run. This is ad-hoc signature evidence, not Gatekeeper certification. |
| Backend/web | [Push CI](https://github.com/QuntmTech/mac-mint/actions/runs/38960425733), [PR CI](https://github.com/QuntmTech/mac-mint/actions/runs/38960431221): 22 Node unit checks; disposable real PocketBase auth/transaction/migration/webhook/provider/SMTP checks; both web builds, lint, five Playwright account journeys and 35 homepage interactions. |
| Resource gates | [Benchmark run](https://github.com/QuntmTech/mac-mint/actions/runs/38960431258): 100,000-file/fingerprint fixtures, per-scanner peak RSS under 250 MiB and cancellation under one second; matching streamed SHA-256/system digest. |

Recorded photo benchmark: 100,000 fingerprints/50,000 groups, including new indexes and queue lookups, 3.05 s, approximately 228 MiB peak, 128 ms cancellation. Combined scan workload: 9.25 s, approximately 222 MiB, 4 ms cancellation. These are synthetic CI measurements, not full PhotoKit decoding, app-wide idle CPU, battery life or a real photo-library guarantee.

Artifacts are `MacMint-UI-<github.sha>` and `MacMint-<github.sha>`, retained 14 days. PR runs may use a synthetic merge SHA, so discover artifact names from the run rather than assuming the branch head is the suffix. Benchmark raw JSON retention is 30 days. This host also has ignored previews under `.build/final-feature-previews`; they are not portable handoff dependencies.

The handoff/documentation commit and final `main` merge generate fresh CI runs. Consult PR #22 and current main checks for those run IDs. The source implementation checkpoint above is retained so evidence remains unambiguous even when merge SHAs differ.

## 14. Reproduce the checks

### macOS

Requires Swift 6/Xcode toolchain and macOS 14+. Run destructive-adapter tests only with their disposable fixture machinery, never substitute personal files or an existing disk.

```bash
swift test
swift build -c release --product MacMint
NO_OPEN=1 ./scripts/build_app.sh
MACMINT_SCREENSHOT_DIR="$PWD/.build/interface-previews" ./scripts/smoke_test.sh dist/MacMint.app
```

Main CI additionally runs `MACMINT_VOLUME_TESTS=1 swift test` on a disposable macOS runner. Read `NativeVolumeTests.swift` before opting into that fixture elsewhere.

### This Linux host

```bash
mkdir -p .build
TMPDIR="$PWD/.build" /home/qrkit/.local/swift/swift-6.2.1-RELEASE-ubi9/usr/bin/swift test -j 4
```

`/tmp` is no-exec on this host, hence the build-local TMPDIR. Do not mistake portable success or app syntax parsing for native semantic compilation.

### Backend

Use the pinned PocketBase executable/checksum from `.github/workflows/backend-web.yml`. With it installed locally:

```bash
node --test backend/tests/*.test.cjs
POCKETBASE_BIN="$PWD/.build/pocketbase-bin/pocketbase" python3 backend/tests/integration.py
POCKETBASE_BIN="$PWD/.build/pocketbase-bin/pocketbase" python3 backend/tests/service_integration.py
```

Both Python suites create disposable `.build` databases and loopback fixtures. Do not point them at production. Their provider/payment/mail transport substitution is limited to copied test files. They do not make paid Anthropic/Stripe calls or deliver external email.

### Websites

Use Node 22 (the homepage package requires at least 22.13):

```bash
cd web
npm ci
npm run build
npm run lint
npx playwright install --with-deps chromium
npx playwright test
```

In a separate shell/workdir:

```bash
cd 'ChatGPT sites the homepage V1'
npm ci
npm run typecheck
npm test
npm run build
```

For performance, inspect/run `.github/workflows/benchmarks.yml`; it compiles `macmint-bench`, creates its own fixture, measures seven workloads and cancellation independently, and enforces memory/cancellation/digest gates. Do not raise thresholds to hide a regression.

## 15. Review file map and suggested order

| Area | Start with | Meaningful regression coverage |
|---|---|---|
| Removal authority / keeper merging | Core `OperationPlan`, `OperationExecutor`, `SafetyPolicy`, `FileSystem`; app `+Operations`, `+Selection` | `OperationTests`, `TrustRegressionTests`, `SafetyHardeningTests`, `UpdatesAndKeeperTests` |
| Durable history / restore | `HistoryStore`, `RestoreCoordinator`, `RecoveryService`, `HistoryView` | `RestoreDurabilityTests`, `NativeRecoveryTests`, `NativeVolumeTests` |
| Corrupt exclusions / aliases | `IgnoreStore`, scanner call sites, `FileSystem`, app initialization | `ExclusionPersistenceTests`, `AccountLifecycleTests`, mounted-volume cases |
| Account / async authority | `AccountStore`, `AccountViews`, `RootView`, coordinator guards | `AccountLifecycleTests`, `OrganizationCoordinatorTests` |
| Organizer | `Organization.swift`, `OrganizerView`, `+Organization`, AI DTOs | `OrganizationTests`, `OrganizationCoordinatorTests`, native volume fixture |
| AI privacy / late responses | `AIAssistant`, `+AI`, `AccountStore+AI`, `AIViews`, context helper/routes | `AIAssistantTests`, consent/account lifecycle cases, `ai.test.cjs`, `organization.test.cjs`, service integration |
| AI reservations / model config | `macmint_ai_lib.js`, reservation/organization migrations | Node unit tests and real PocketBase concurrency/service suites |
| Photo decisions / analysis | `SimilarPhotos`, `+Photos`, `PhotoReviewDeck`, `ComparisonViews`, `PhotoLibraryService` | `SimilarPhotosTests`, `PhotoReviewTests`, `PhotoRequestTests`, benchmarks |
| Process controls / resource lifetime | `SystemMonitor`, `PerformanceView`, `MenuBarView`, preview caches | `ResourceMonitorTests`, `PhotoReviewTests`, manual Instruments still needed |
| Theme / responsive layout | `DesignSystem`, `Components`, `RootView`, `ApplicationsView`, `SmokeTest`, `DesignFixtures` | `AppearanceTests`, actual NSHostingView captures and viewport frame assertions |
| Fulfillment / release safety | payment hooks/helpers, account hooks, migrations, `ReleaseChecker`, release workflow | `payments.test.cjs`, real webhook/migration integration, browser account tests |
| Web privacy / recovery / checkout | `web/src` account/reset/checkout/layout; separate homepage components/config | Playwright account suite and homepage interaction checks |

Please specifically challenge:

1. Remaining race windows around source replacement, opened parent directories, metadata checks, journal failure and post-move proof. Check uncertain recovery after process death, not only thrown errors.
2. Backward compatibility for old History/receipts, corrupt/incomplete records, replayed restore/organize intents and identity changes. Verify Undo conflict paths remain no-overwrite.
3. Cross-module keeper/exclusion authority when parent selections collapse, scan results change, or aliases/case/mounts alter path identity.
4. Actor/session generation boundaries: rapid sign-out/re-auth, dismissed consent, late AI, canceled previews, overlapping Apply/Undo and UI busy lifetime.
5. Native interaction completeness: deck focus/gestures, selected-keeper changes, PhotoKit permissions/system confirmation/cloud preview, actual app Quit/Force Quit against disposable apps, and activation while Organizer is presented.
6. Performance under prolonged use: photo/deck queue latency, dictionary/index overhead, retained NSImages/PhotoKit buffers, Quick Look concurrency, timer/port lifetime, foreground/low-power/thermal transitions, and full-library decoding.
7. Privacy copy consistency before enabling organization: a name-only, explicitly consented organizer request is different from category-only cleanup/chat context. Do not promise filenames never leave the Mac when the user deliberately sends them through this new flow.
8. Migration/payment/provider behavior on the actual staging runtime and real upstream services, including prices/rates/version assumptions that can change.

## 16. Work still outstanding — do not report it as completed

### Native/manual release gates

- Interactive Mac journeys: first launch → scan → activation → reviewed cleanup → recovery; navigation/state retention; failed update; near-full storage behavior.
- VoiceOver, Full Keyboard Access, keyboard traversal/focus, contrast/reduced motion/system appearance changes and smaller laptop windows. Automated captures prove layout rendering, not all interactions.
- Real Photos permission/limited-access/cloud-only/sync/deletion/Recently Deleted journeys.
- Real disposable-app process control, especially unresponsive apps, foreground transitions and PID reuse. Never test by killing the user's real work.
- Instruments on Intel and Apple silicon for idle, visible Performance, rapid photo decisions, large library analysis and cancellation. Synthetic RSS/cancellation numbers do not establish daily-use battery/CPU behavior.
- Developer ID-signed, notarized, stapled downloaded install, quarantine/Gatekeeper acceptance, update failure and feed validation.

### Service and rollout gates

- Backup/staging migration validation on the actual target PocketBase runtime.
- Authenticated Anthropic staging with strict payload/output checks, feature kill switch, quotas, uncertain timeout reconciliation, then a tightly bounded real-provider canary. Keep `features.organize` off until this passes.
- Stripe sandbox fulfillment/failed/delayed payments/webhook replay/device transfer and then approved bounded live validation.
- Secure SMTP sender configuration and real verification/reset inbox delivery.
- Deploy reviewed hooks/migrations and websites deliberately. Merging source into `main` does not do any of these things automatically.

### Future product features

- Auto Tame/background throttling/suspension: not implemented. Prototype with supported controls, foreground/audio/download/build/backup exceptions, sleep/wake and crash-safe restoration; never auto-force-quit.
- Watched-folder inference: not implemented. Use scoped FSEvents, debounce, stable writes, bounded queues, self-event suppression, single inference concurrency, power/thermal/offline/budget controls, and a separate persistent name-sharing grant if requested. This version's one-request consent grants no ambient upload permission.
- Content-based naming, OCR/vision/document extraction: not implemented; needs byte/page/pixel/time budgets, appropriate content consent and injection/privacy tests.
- Folder renaming, recursive organization, creating new destinations and external/cloud-volume mutation: not implemented; need dependency/identity/recovery evidence.
- Offline naming templates/presets are a recommended next step before more autonomous filing.

## 17. Research and supporting documents

Likely match for the user's remembered Setapp app: [NameQuick](https://setapp.com/apps/namequick), with its [official product site](https://www.namequick.app/). This is a researched possibility, not confirmation of the user's download history. Its content-based naming/watch-folder features informed the roadmap; MacMint's current implementation is narrower and explicitly reviewed.

Other useful primary references already consulted:

- [App Tamer app-management behavior](https://www.stclairsoft.com/AppTamer/help/pages/managing.html): background scheduling/suspension is more than periodic killing and has audio/browser/download implications.
- [Apple NSRunningApplication](https://developer.apple.com/documentation/appkit/nsrunningapplication) and [force termination](https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate%28%29): identity and asynchronous exit semantics.
- [Apple XNU task/rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c), [task counters](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c), [host-port trap documentation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/man/mach_host_self.html).
- [Anthropic structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [pricing](https://platform.claude.com/docs/en/about-claude/pricing).
- [Apple FSEvents](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html), [Photos deletion/recovery](https://support.apple.com/en-gb/guide/icloud/mm08b49040b5/icloud).
- [Stripe fulfillment](https://docs.stripe.com/checkout/fulfillment) and [idempotent requests](https://docs.stripe.com/api/idempotent_requests).

Local reading order:

1. This handoff for current scope, evidence and limitations.
2. `docs/CODE_REVIEW_2026-10-16.md` for the ten implementation findings/triggers/regressions.
3. `docs/NATIVE_INTERFACE.md` for appearance and actual native capture/layout machinery.
4. `docs/FEATURE_EXPANSION.md` for the photo/process/Organizer scope, resource bounds and roadmap.
5. `docs/TRUSTWORTHY_CLEANUP_IMPLEMENTATION.md` for the original plan mapping and operational rollout details.
6. `docs/RELEASING.md`, workflow files and actual code for distribution requirements.

Some older docs retain historical counts such as 127/157 tests and 20/25 screens, or describe future modules that now exist. Use the explicit checkpoint above and current-SHA CI for current evidence. They do not supersede current source or establish release readiness.

Please finish your review with prioritized findings, what you verified yourself, what remained untested, and a concrete recommended sequence of fixes/validation. Preserve the user's preview-and-approve decision and existing recovery boundaries while proposing improvements.

## 18. Desktop micro polish follow-up

After the original implementation was merged, the user requested another pass of small desktop improvements. The follow-up changes five views; the original checkpoint/test counts above remain historical evidence.

- `DesignSystem.swift`: shared search fields show a semantic focus outline, consume Escape to clear a nonempty query, leave Escape available to the enclosing screen when empty, and restore typing focus after clicking Clear. The decorative search icon is hidden from accessibility.
- `CommandPalette.swift`: results are native SwiftUI buttons with accessible titles, details and selection state. Truncated results have tooltips. The footer shows keyboard instructions and the displayed result count; an empty search result explains what can be searched.
- `PerformanceView.swift`: Pause captures the displayed snapshot, app list and sample time, so another monitor consumer cannot change the paused readings. Resume uses the live monitor again; existing lease/lifecycle policy and final process-identity checks remain authoritative. The view labels CPU/Memory columns, supplies their accessible values, ignores surrounding whitespace in searches, and keeps unavailable disk capacity distinct from a measured zero.
- `PhotoReviewDeck.swift`: the current photo identifies an existing queued selection; swiping a keeper shows protection rather than a misleading removal label. Folder photos can be revealed directly. The end state distinguishes an empty queue and offers the existing review flow when photos are selected. Keyboard/Undo hints are visible; gestures still change selections only.
- `OrganizerView.swift`: validation waits for a 200 ms typing pause, captures inventory ID/proposals/exclusions together, and discards cancelled or superseded checks. Review and selection stay unavailable until that input has been validated. A checking indicator explains the delay. Undo also communicates the existing scan/operation busy boundary through its disabled state.

Review the cancellation/edit/exclusion transitions, pausing while the menu-bar monitor is active, and photo-deck completion in both appearances. Portable tests and syntax parsing run on the Linux host; the macOS workflow provides semantic compilation, native tests, layout captures, and downloaded-package checks for the follow-up commit. Actual keyboard routing and VoiceOver still need interactive Mac verification. This follow-up adds no polling timer, AI request, watcher, automatic removal, release tag or deployment.

## 19. Interruption and lifecycle follow-up (2026-10-17)

A second critical pass found three gaps beyond visual polish:

1. Photo-deck cursor/Undo state lived in the view, so moving to Similar, another workspace, or a scan progress view restarted browsing while keeping queued selections. `PhotoReviewSession` now lives in `AppViewModel` and is reset when the scan generation changes. Navigation and cancelled scans preserve progress. `decidePhotoReview`, `undoPhotoReview`, and `restartPhotoReview` share existing selection/keeper policy; restarting browsing leaves the queue alone. Preparing a plan blocks deck changes. New results cannot inherit old index-based Undo records.
2. File-type suggestions used an untracked task without the AI path's generation check or immediate busy state. `OrganizationSuggestionSession` now owns preparation for both paths. Starting work blocks edits/folder changes immediately, replacement/cancellation invalidates the old result, and a late success/error cannot publish into a dismissed or newer session or clear its busy state. Cancelling preparation does not clear the separate busy state of an already-started local apply/Undo.
3. Quick Look generation had no explicit native cancellation forwarding. `ThumbnailRequest` now forwards cancellation to the request-specific generator API, skips already-cancelled starts, and discards late images before cache insertion. This builds on [Apple's cancellation API](https://developer.apple.com/documentation/quicklookthumbnailing/qlthumbnailgenerator/cancel(_:)); it does not establish a measured CPU/RAM improvement or a hard bound on third-party thumbnail-provider shutdown time.

`PhotoReviewTests` adds navigation/resume/Undo, cancelled scans, changed-result invalidation, changed keepers, and queue-preserving restart checks. `OrganizationSuggestionTests` uses deliberately delayed operations that ignore cancellation to verify stale-response and retry behavior. `ThumbnailRequestTests` covers cancellation before start, cancellation during generation, repeated cancellation and late images, and normal completion. The smoke harness also captures resumed and completed photo decks in both appearances.

The Linux host can run portable tests and syntax parsing; new app-level tests require macOS CI. Inspect the final commit's native test, render and package evidence. Interactive keyboard/VoiceOver, real PhotoKit/iCloud, provider shutdown behavior and prolonged Instruments measurements remain outstanding as described above. No paid operation authority, production AI flag, release tag or deployment is added by this follow-up.
