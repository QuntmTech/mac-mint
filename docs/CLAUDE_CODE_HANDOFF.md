# MacMint — handoff to Claude Code for independent review

**Updated 2026-10-19. Start with [../HANDOFF.md](../HANDOFF.md) and [installation and setup](INSTALLATION_AND_ONBOARDING.md).**

## Latest installation extension — 2026-10-19

Implementation `2c6013c` adds a drag-to-Applications DMG alongside the ZIP, universal release builds, explicit accepted-notarization/stapling gates and read-only verification of the built and downloaded image plus an isolated app copy. `FirstRunSetup.swift` owns advisory location classification and persisted setup steps. `InstallationGuide.swift`, onboarding and permission settings explain the intended installed copy. Setup resumes after an access-related restart, offers optional same-account connection and hands Quick Scan back to its presenter to start after dismissal. The website account download includes DMG/ZIP-specific steps; the desktop action is named **Check My Purchase** consistently.

Read the [implementation and acceptance plan](INSTALLATION_AND_ONBOARDING.md), [release procedure](RELEASING.md), [successful native run](https://github.com/QuntmTech/mac-mint/actions/runs/39204402387) and [successful backend/website run](https://github.com/QuntmTech/mac-mint/actions/runs/39204402359). Both Mac versions passed 251 cases with expected skips, 123 rendered states, packaging/startup and fresh-runner downloaded ZIP/DMG checks; all 39 website browser tests passed. A first native packaging run caught an argument-order error in `lipo -verify_arch`; `2c6013c` corrects both verifier calls. Do not cite that earlier failed run as installer acceptance. The website guidance was deployed using the tested combined build; read-only checks passed seven desktop account/recovery routes and phone navigation/layout without JavaScript errors, missing assets or mutating requests.

No price, Stripe account configuration, release tag or public feed attestation changed. Repository Apple signing/notarization credentials were absent. These changes do not certify a consumer download, real permission dialogs, macOS 14/Intel hardware journeys or the user's iCloud library. The older sections below retain historical results; fetch `origin/main` before reviewing.

## Earlier extension — 2026-10-18

[PR #33](https://github.com/QuntmTech/mac-mint/pull/33) tracks all six phases: app uninstall discovery and related-data safety; reversible manual/automatic process slowdown and exceptions; bulk photo selection; the repeated blank review-deck preview; MacMint's own resource footprint; and review/validation/delivery. Its checks and artifacts identify final validation and merge status. The dated section 0 below is the previous delivery checkpoint, not a claim that `c0ade0e` is still the newest source.

Read `AppTaming.swift`, `AppTamingController.swift`, the `SystemMonitor` integration and `UNINSTALL_AND_TAMING.md` before reviewing slowdown. It uses same-user Darwin background priority, not a hard CPU/RAM cap or process suspension. Restoration has durable intents, boot/PID/birth/path checks, exclusive journal ownership and uncertain-outcome preservation. Automatic mode is explicit, conservative and off at each launch; exceptions persist.

Photos now supports bulk selection by tab/group and deselection of all results while protecting keepers. The deck first displays a local 256px thumbnail, then attempts a larger preview, preserves degraded results, bounds/cancels requests and refuses blind queueing. The user's repeated-blank-library report still needs acceptance on that actual iCloud account. Resource changes supersede the earlier cache figures: photo/file pixel caches are 8+8 MiB, icons use an explicit 2 MiB LRU, disposable caches clear on navigation/pressure, horizontal comparisons are lazy, and scan iterations drain autoreleased temporaries. Neither these budgets nor synthetic stress tests certify total application RAM.

New evidence lives in `AppUninstallTests`, `AppTamingTests`, `AppTamingControllerTests`, `NativeTamingTests`, `PhotoMemoryTests` and expanded photo tests/smoke fixtures. The packaged startup helper also measures the live Performance view through the read-only `--performance` launch shortcut. Preserve the distinction between automated native fixture evidence and the user's 19,282-photo live workload. Existing Stripe, distribution and manual accessibility gates remain as documented below.

## 0. Previous verified delivery checkpoint

At this earlier checkpoint, the verified application implementation was on `main` at **`c0ade0ec66e2b600d50dcdf9dc3b0a8965af1423`**. The older branches, counts and “pending CI” language below describe their checkpoints, not the newest implementation.

| Delivery | Merged evidence |
| --- | --- |
| Stripe readiness and account flow | [PR #25](https://github.com/QuntmTech/mac-mint/pull/25), merge `245b6c9b5465a9354f7069eaaf97968c4ee15840` |
| Startup fix, permission onboarding and neutral palette | [PR #26](https://github.com/QuntmTech/mac-mint/pull/26), merge `c969d827a7dcba9333746339c6cb53f706197bbe` |
| ProcessX-inspired Performance presentation | [PR #27](https://github.com/QuntmTech/mac-mint/pull/27), merge `c0ade0ec66e2b600d50dcdf9dc3b0a8965af1423` |

Final implementation validation is complete: [main native CI](https://github.com/QuntmTech/mac-mint/actions/runs/39065968758) and [main backend/website CI](https://github.com/QuntmTech/mac-mint/actions/runs/39065968760) both succeeded at `c0ade0e`. The [PR native run](https://github.com/QuntmTech/mac-mint/actions/runs/39065371113) and [implementation-head native run](https://github.com/QuntmTech/mac-mint/actions/runs/39065125666) also succeeded.

- macOS 15 and 26 each passed the **220-test suite with zero failures and one expected skip**. Packaging reruns add the expected opt-in mounted-volume fixture skip; these are repeat runs, not additional unique tests.
- Each native build rendered **113 screens/states**, including the 16 Performance variants and compact-row visibility assertions.
- Ordinary packaged startup passed with menu-bar insertion off and on, normal-window metadata, the idle CPU-loop check and graceful Quit. Downloaded archives passed checksum/signature, rendering and ordinary-startup checks on separate runners.
- Backend and both website packages passed their workflow checks. See section 20 for the 36 Node cases, 27 account-browser cases and disposable PocketBase integration scope; see the linked runs for exact commands/results.

**Source completion is not launch certification.** The user's installed copy was not replaced from this Linux workspace. Permission dialogs, VoiceOver/full keyboard access, ordinary macOS 26 sidebar drawing, real PhotoKit/iCloud journeys and prolonged CPU/RAM profiling remain native checks. macOS 26 offscreen captures omit the glass sidebar; geometry and render counts do not prove its pixels. The startup CPU threshold detects the reported feedback loop and is not a daily-use energy benchmark.

Stripe-only purchase preparation is committed, but pricing, intended account/sandbox setup, real-provider payment tests and production deployment remain pending. Earlier connector failures and live configuration observations are historical evidence, not current account access. No live pricing, consumer release/tag or deployment was performed in these passes. Developer ID/notarization/Gatekeeper, external inbox delivery, authenticated staging AI and bounded provider canaries remain operational gates. Auto Tame, CPU caps, GPU measurements and grouped helper totals are future work; current process controls are guarded Quit/Force Quit for regular apps' main processes.

The next reviewer should verify this implementation, report concrete findings, and distinguish existing functionality from those open gates. Sections 1–22 preserve the detailed architecture, changes, failed approaches, tests and review map.

### Historical delivery notes

Desktop micro polish followed the original implementation checkpoint; see section 18 for the additional changes to review.

A further interruption/lifecycle pass is described in section 19, including new regression tests and photo-deck resume/completion captures.

Section 20 records the subsequent Stripe readiness and account-flow improvements. Pricing, real Stripe account configuration, sandbox provider verification and production deployment remain pending.

Section 21 covers the user's local startup-freeze handoff, contextual permission setup, a normal-launch regression gate, and the neutral workspace palette requested afterward.

Section 22 describes the ProcessX-inspired Performance presentation and its separate verification requirements.

Originally prepared 2026-10-16, America/New_York, for [PR #22](https://github.com/QuntmTech/mac-mint/pull/22). Sections 18–22 record later work; section 0 gives the final verified implementation status.

Claude Code: please independently review the work described here. Treat these statements as claims to verify against the source and executable evidence, not as proof that the product is finished. Prioritize data safety, recovery, privacy, account boundaries, concurrency, native usability, and resource consumption. Report concrete findings with severity, file/line, trigger, consequence, and a regression or verification method. Separate confirmed defects from untested hypotheses and product limitations. Another green test run alone is not the requested review.

## 1. Repository and review boundaries

- Repository: `QuntmTech/mac-mint`, https://github.com/QuntmTech/mac-mint.
- Actual source checkout on this shared Linux host: `/home/qrkit/src/mac-mint`.
- `/home/qrkit/macmint.co` is a deployed website directory, **not** the source checkout. Do not edit the deployed site instead of the repository.
- Original implementation branch (historical): `feature/trustworthy-cleanup-flow`. Review current `origin/main`.
- Original implementation checkpoint before this handoff: `9214f5d0ca90aecfa90d4e88eb5ebe9bf17d229c`; latest verified implementation: `c0ade0ec66e2b600d50dcdf9dc3b0a8965af1423`.
- Previous `main` / original review baseline: `05ecb65417f2d0a7a3c16748a2abd39284c7cf91`.
- Before this document, the branch contained 60 commits ahead of that baseline, with 151 changed files, 9,771 insertions and 2,035 deletions. This is substantial work and warrants review by subsystem.
- The user explicitly requested that all this work and the handoff be pushed to `main`. PR #22 records the original merge; PRs #25–27 and section 0 identify the subsequent deliveries. Use current `origin/main` after fetching.
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
- `RootView` has a compact sidebar, disk-space footer, command search, contextual workspace bar, persistent Review badge, and account/help access. Section 21 supersedes the original mint-tinted surfaces with neutral grays/charcoal and small green accents.
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

On a disposable graphical Mac with no existing MacMint instance running, also run the ordinary scene regression gate:

```bash
./scripts/native_startup_test.sh dist/MacMint.app
```

It refuses an existing instance and uses marker-verified test processes. It is distinct from the isolated view-rendering smoke test; read [PERMISSIONS_AND_STARTUP.md](PERMISSIONS_AND_STARTUP.md) before running it on a development Mac.

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

## 20. Stripe readiness and account-flow follow-up (2026-10-17)

The user requested purchase integration readiness while researching pricing, plus useful micro improvements. Work started from `86a0b2ec0ae671130dfaccc392f91d67c82c9907` on `feature/stripe-readiness`. The existing hosted one-time Checkout architecture remains in place; no retail price, product, recurring subscription or live sales configuration was selected or created. See [STRIPE_SETUP.md](STRIPE_SETUP.md) for setup commands, prerequisites and operational verification.

### Backend changes to review

- `macmint_payments_lib.js` snapshots the account email, canonical trusted return origin and offer terms before the first provider POST. Lost-response retries retain exactly the original parameters and idempotency key, including after the email, price or origin changes. A legacy unbound order without its original email fails closed for reconciliation rather than guessing. Existing bound sessions remain retrievable.
- Order creation checks for another unresolved purchase within its transaction. Eight racing distinct keys produce one order/session; a single existing order returns its owner-only canonical key for explicit Resume. Ambiguous legacy orders require operator reconciliation instead of another payment. Unbound attempts outside the safe retention window or missing their frozen email report `checkout_attention`, preserving uncertainty rather than describing them as confirmed expiry.
- `/checkout/status` is authenticated, owner-scoped, database-only and `no-store`. It returns immutable offer terms and allows a replacement only after a verified persisted failure/expiry. Missing or unknown attempts remain uncertain. Polling never consumes provider calls.
- `checkout.session.expired` joins completed/asynchronous success/failure handling. The server fetches authoritative Session/line items before terminal transitions, cannot downgrade fulfilled orders, and can fulfill an already-paid session even when a late terminal notification triggers the check. A delayed creation response cannot reopen a terminal order. Missing terminal deliveries require reconciliation rather than inferred failure.
- `1792109400_checkout_lifecycle.js` adds the immutable email/origin fields and expired state. Old evidence is retained on rollback. Test the additive migration on the actual staging database/runtime.
- Pure config validation rejects invalid types, unsafe numeric/date arithmetic and unsafe origins. HTTPS origins are canonicalized; HTTP loopback is permitted only in explicit non-live mode. Browser-provided return URLs remain unused. The superuser-only readiness endpoint returns reason codes without secrets or raw config.

### Website and desktop changes to review

- The account page distinguishes loading, disabled sales and availability failures, displays configured currency/access/device terms, and uses the original order's offer when resuming. Stripe minor-unit currency special cases are covered. Query-string payment returns never grant access.
- Checkout cancellation/transport failures preserve the retry identity. Another tab's unresolved purchase is adopted only from a valid server-provided owner key and resumed explicitly. Storage failure blocks checkout creation rather than losing its retry identity. Failed/expired Start New consumes the old return query before permitting a new request.
- Payment confirmation uses bounded sequential status checks, pauses while hidden and retains the same request budget on foregrounding. Manual refresh remains available. Account loads, redemptions and redirect callbacks reject late responses after an account switch or sign-out.
- `AccountStore.checkPurchase()` explicitly activates this Mac using a browser purchase, without requiring a redemption code. It supersedes pre-purchase quiet verification and retains session/sign-out/duplicate-action guards. New native tests exercise pending/completed purchase, stale verification and repeated checks interrupted by sign-out. Background verification still cannot reactivate a removed Mac.
- The native account sheet scrolls when content exceeds the viewport. Purchase and redemption wording are distinct, and the account uses “Access until” rather than implying automatic renewal.

### Setup tooling and executable evidence

`backend/commerce.example.json` is intentionally disabled with commercial inputs unset. `backend/scripts/check-commerce-readiness.cjs` reads a local ignored config and injected environment values without network access, changes or secret/config echo. A successful preflight means local prerequisites only; it always reports `launch_ready: false`. Five CLI regressions cover pending pricing, key mode, unrestricted keys, secret-safe malformed config handling and trusted origins.

Verified locally for this follow-up: **165 portable Swift tests**, **36 backend Node tests**, **27 Playwright browser cases**, website build, lint with zero warnings, browser-test TypeScript checking, Swift syntax parsing and the real disposable PocketBase integration and service suites. The integration suite covers concurrent distinct checkout attempts, owner isolation/database-only polling, duplicate/concurrent fulfillment, expired/failed/out-of-order webhooks and migration compatibility. The service suite checks authenticated AI/organization contracts and real loopback SMTP token flows; it does not contact Anthropic or prove external inbox delivery. Native CI results should be checked at the final delivery SHA; older counts in this document are historical. The independent read-only payment review's three concrete findings—terminal restart query state, wrong offer shown on resume, and late redemption across accounts—were corrected and covered by regressions.

macOS CI at `9ddccec` also passed **207 tests with one expected skip**, the release build and **89 rendered screens**. Packaging reruns tests without the opt-in volume flag, adding an expected volume-fixture skip. The three new Check Purchase regressions passed in the native suite. Check the PR's final head for the subsequent backend-only uncertainty-message correction and final package-verification status.

### Explicitly unverified and not deployed

The Stripe connector first returned `UNAUTHORIZED` / requires reauthentication. The user reported reconnecting; subsequent calls still failed, and the final retry returned “MCP tool call blocked by app configuration.” No intended account or sandbox was obtained. Official Stripe documentation was read using the local Stripe CLI documentation command; its unauthenticated account check did not supply access. No real Stripe API mutation, product/Price provisioning, webhook registration or actual payment canary occurred.

A read-only GET to `https://macmint.cloudpod.pro/api/macmint/checkout/config` returned HTTP 404. Source readiness does not mean these hooks/migrations or website changes are deployed. No production database/config/secret, release tag, AI flag, pricing or deployment was changed. Existing notarization/consumer-build, SMTP inbox-delivery and real-provider gates still apply.

Claude: challenge retry identity across every mutable input, legacy unresolved-order reconciliation, terminal webhook ordering, cross-tab/account transitions, currency formatting, viewport overflow and Check Purchase interrupted by sign-out. Run the actual sandbox → signed webhook → entitlement → explicit Mac activation journey before opening sales. If the chosen business model is recurring, implement and test a separate subscription lifecycle; a positive `duration_days` is only a one-time access term.

## 21. Native startup, permissions and workspace follow-up (2026-10-17)

The user supplied an installation handoff from their Apple Silicon Mac, macOS 26.5/Swift 6.3.3, based on `86a0b2e`. It reported a real interactive startup freeze and about one core of continuous CPU usage, despite 204 unit tests and 89 view renders passing. That chat isolated the `MenuBarExtra` direct AppStorage insertion binding and reported responsiveness after adding an unchanged-value guard. Its fix was local and uncommitted; release repackaging/replacement/final walkthrough remained pending. This repository now ports the exact production setter fix in `MacCleanerApp.swift` without importing the diagnostic bypasses.

The user also requested proper permission onboarding and Settings shortcuts. New `PermissionsService`/views provide passive Photo/notification state, truthful optional Full Disk Access instructions, current-app reveal, safe Settings navigation/fallback and written paths. The unreliable Safari/Stocks FDA probe is removed entirely. Photos has an explanation before its system request, current denied/restricted/limited states, Settings help and a folder alternative. File/folder, app-data and app-bundle purpose strings describe actual operations; obsolete Finder-automation text/dead errors are removed. App Management is independent from FDA and uses the general Privacy & Security page with a written path. Login Items pending approval uses the public API.

Onboarding is scrollable and replayable. Skip/Escape/Open Workspace do not scan; Run Quick Scan is explicit. Existing-user launch also stops automatically scanning. Settings/Help/scan-issue sheets offer access guidance. Permission refreshes never prompt or list protected directories. Notification requests occur only after opt-in, with concurrency guards; successful scheduling alone records cooldowns. Seven native tests cover authorization distinctions, Settings fallback, late refreshes, contextual opt-in and denied/failed reminder recovery.

`native_startup_test.swift`/`.sh` exercise full normal application scenes rather than the smoke-test entry point, with menu bar off/on, launch/window evidence, a generous CPU-loop threshold and graceful Quit. Existing instances cause refusal; only the exact marked new process can be cleaned up. macOS CI now covers macOS 15 and 26, with OS-specific artifacts and equivalent downloaded-package checks. Actual helper compilation/execution must be verified by that CI; Linux parsing is not a substitute. Smoke captures include all three onboarding steps, access help and scan details in both appearances.

The user strongly rejected the green workspace. Canvas, panels, sidebar, text, borders and selection backgrounds now use neutral whites/grays/charcoal, preserving green for small accents/actions. This changes appearance without changing selection or removal authority. The follow-up ProcessX-inspired Performance redesign is a separate task after this startup/permissions pass; CPU caps, grouped helper totals and Auto Tame are not implemented by these changes.

See [PERMISSIONS_AND_STARTUP.md](PERMISSIONS_AND_STARTUP.md) for flows, diagnostics, primary Apple references and outstanding interactive checks. Review normal launches on the user's macOS version, actual Settings anchors, permission denial/re-enable, Login Items approval, keyboard/VoiceOver and notification races. Do not claim the local installed release is repaired from source/CI results alone. Stripe remains the chosen provider: the user explicitly clarified “Stripe only”; no PayPal code or configuration was created. PR #25 merged Stripe readiness at `245b6c9` with all checks passing; real account access, pricing and live configuration remain pending.

## 22. ProcessX-inspired Performance interface (2026-10-17)

The user supplied ProcessX screenshots and requested a clearer resource/app interface with actions close to the readings. They also explicitly rejected the green main workspace. [ProcessX's official site](https://avantigroupai.github.io/processx-web/) was consulted for design context; no competing process-control implementation or measurement claims were adopted. See [PERFORMANCE_UX.md](PERFORMANCE_UX.md).

Performance now emphasizes compact CPU/Memory cards that select sorting, an aligned app table with sortable headers and direction, name/PID/bundle search, per-row resource bars, visible confirmed Quit, and secondary confirmed Force Quit. Counts, live/paused state and sample time are next to the table. Supporting disk/swap details follow the app list. CPU text preserves 100% = one core and values above 100%; bars describe whole-machine capacity. Main-process-only coverage is explicit: helper totals and system-wide process groups are not invented.

`PerformancePresentation.swift` is pure scalar display logic. It keeps unknown/nonfinite CPU readings last, sorts exact integer memory values, resolves ties deterministically, and clamps meter fractions. Six meaningful tests were run through a Linux XCTest adapter and subsequently passed in the native suite on both macOS versions. Native AppKit/SwiftUI compilation and final render gates also passed; see section 0. Pause retains its snapshot, apps and timestamp; nil timestamps cannot fall through into newer live readings. Sort-card arrows reflect the selected direction.

The existing `SystemMonitor` sampler, adaptive cadence, lease policy and final PID/birth/owner checks remain unchanged. Rows map real control handles using PID plus kernel birth identity. Read-only preview fixtures cannot control a process. App icons are rasterized to 64×64 and held in an NSCache configured for 64 entries/2 MiB. Those NSCache limits are advisory, unlike the explicit photo-preview LRU budgets described in section 7; they are not a whole-app memory guarantee. No sampling timer, shell polling or inference is added.

Smoke rendering adds 16 deterministic populated/paused/high-pressure/unknown-reading captures in both appearances at compact/full sizes. Preview-only row/viewport measurements require three complete app rows at 980×660 and five at 1200×800; later offscreen rows remain valid scrolling content. These assertions check usability beyond a successful render. Inspect artifacts, long names, unknown readings, keyboard/VoiceOver and a disposable app's normal/force quit. Longer Instruments sessions and actual UI interaction still have not been established by this presentation work.

Dashboard decoration, account-sheet backgrounds and AI-review panels also use neutral surfaces so large green washes do not return outside the main canvas. Small brand/action accents remain green. CPU capping, background reprioritization, GPU readings, helper aggregation and Auto Tame are not implemented or advertised as controls by this change.

Native CI caught older-SDK callback actor-isolation traps in the external startup helper and the app's notification status bridge. Both callback boundaries now have explicit `@Sendable` completions that only transfer results through their mailbox/continuation. The real startup gate passes on macOS 15 after that correction; check the final SHA for both operating systems and downloaded-package results. Failure diagnostics retain only newly created helper reports and, on disposable GitHub CI only, app crash reports whose PID and executable path match the probe's marker-verified launch.

Independent image review found a capture gap: macOS 26 `cacheDisplay` images show a white sidebar even in dark mode, while macOS 15 captures render the controls. Current RootView still lays out those controls, and the Performance detail is visible; this supports a system-compositor capture limitation rather than proving the normal sidebar works. Native macOS 26 drawing/interaction must still be checked. Do not claim that all pixels or permission dialogs were verified from the screenshot count. The app requests no Screen Recording or Accessibility workaround.
