# MacMint

A native **Swift 6 + SwiftUI** macOS cleaner/uninstaller, evolved from Mac Cleaner Hybrid Base V2 — **not a rewrite**.

## Accounts and licensing

MacMint requires a signed-in account with an active plan. Purchases on macmint.co issue a redemption code (`MINT-XXXX-XXXX-XXXX-XXXX`) that unlocks Pro on the account; each account can activate a limited number of Macs.

- Backend: PocketBase at `https://macmint.cloudpod.pro`. Routes and rules live in [`backend/pocketbase/pb_hooks`](backend/pocketbase/pb_hooks) (`/api/macmint/me`, `/redeem`, `/devices/activate`, `/devices/deactivate`, superuser-only `/admin/licenses`).
- The app stores the session token in the Keychain and re-verifies every 6 hours. A previously verified plan keeps working offline for 14 days.
- Only account and license checks touch the network. Files, paths, and scan results never leave the Mac.

V2 keeps the working V1 core (cleanup catalog, Trash-first deletion, streaming SHA-256, duplicate detection, application scanner, startup inventory, history, and safety policy) and upgrades it in-place for stronger reliability, safer destructive operations, better scan visibility, exclusions, cancellation, richer review flows, and a substantially more polished desktop interface.

## What works now

### Smart Care
- One pass (⌘R) over caches, apps, startup items, developer data, Removed Apps leftovers, Downloads, and the Trash, run in parallel.
- Findings become **ranked recommendations** — estimated bytes × confidence (Safe / Likely unneeded / Worth a look) — each with a plain-English reason. "Review" always opens the normal review sheet; "Review Safe Items" bundles everything that rebuilds or re-downloads itself. No opaque health score.
- **Usage intelligence** from Spotlight: last opened, date added, use count, and download source (host only). Unknown is never treated as unused, and file access times are never used.
- **Downloads**: big items not opened in 3+ months ("Downloaded 8 months ago from example.com and never opened").
- **Unused apps**: Applications can sort by *Last opened*; Smart Care lists apps not opened in 6 months (each uninstall is still reviewed individually).
- **Free-space history** (one sample a day, 90 days) with a weekly trend, and **storage growth**: each Storage map is compared with the previous one and points at the most specific folder that grew.

### Smart Scan
- Runs cleanup, installed-app, and startup-item scans concurrently.
- Reports safe reclaimable bytes separately from review-only bytes.
- Records scan duration/date and filesystem issues.
- Supports cancellation instead of forcing a long scan to finish.
- Honors persisted scan exclusions.

### Storage Explorer
- A squarified **treemap** plus a sorted size list of any folder or drive, with breadcrumbs and click-to-dive.
- Counts space actually used on the disk; hard links once; app/library packages as single items sized with their contents.
- Never crosses onto other drives, never opens or downloads cloud-only files (they're counted separately), and lists unreadable folders instead of hiding them.
- Select files or folders to send them through the same review → Trash → restore pipeline.

### Developer & AI
- **Xcode:** build data per project, archives (flagged — needed for symbolication), device support (latest kept).
- **Simulator caches;** simulator devices are removed with `xcrun simctl delete unavailable`, not by deleting files.
- **Package caches:** npm, pnpm, Yarn, Bun, Homebrew, pip, CocoaPods, SwiftPM, Gradle, Maven, Cargo. Go's read-only module cache is cleared with `go clean -modcache`.
- **Project build folders** under folders you add: `node_modules`, `.build`, `target`, `.next`, `Pods`… Each one is offered only when its tool's marker file is next to it (e.g. `node_modules` needs `package.json`).
- **AI models:**
  - Ollama models are sized from their manifests and removed with `ollama rm`, never by deleting blob files.
  - LM Studio models are listed per model.
  - Hugging Face caches are listed as whole repositories (all revisions), honoring `HF_HOME` / `HF_HUB_CACHE`.
- **Docker Desktop's disk image** is shown with `docker system prune` as the way to reclaim it.
- Each item says whether it rebuilds, re-downloads, or needs review. Anything touched in the last 3 days is marked "In use" and never preselected.

### Performance, menu bar, and reminders
- **Performance:** memory pressure (the signal macOS itself uses), CPU, swap, free space, and the apps using the most memory. "Quit…" asks an app to quit normally so it can prompt you to save. There's no fake RAM purge.
- **Optional menu bar companion** with the same readings and quick actions. It only samples while it's open.
- **Opt-in low-space alerts and weekly scan reminders:** at most once a day, never 10 pm–8 am, and they never clean anything automatically.
- **First-run onboarding** with a Full Disk Access check, plus an optional "Open at login" setting (SMAppService).
- **Browser caches** for Chrome, Firefox, Edge, Brave, Arc, Vivaldi, Opera, and Safari. A browser's cache is skipped while that browser is open.

### Photos
- **Similar shots**: 64-bit perceptual hashes grouped by Hamming distance; the sharpest (then largest) shot is the suggested keeper, which you can change with "Keep This One Instead". The kept shot can never be selected, and nothing is preselected.
- **Blurry photos**: variance-of-Laplacian sharpness judged relative to the rest of the collection; **Screenshots** listed by size.
- **Photos library** is analysed through PhotoKit thumbnails (local only, never downloads originals) and removed only through Photos itself: the system asks for confirmation and items stay in Recently Deleted for 30 days. Files inside `.photoslibrary` packages are never touched.
- **Folders** use the normal review → Trash → Restore pipeline; the kept shot's state is recorded so a plan can't remove it too.

### Removed Apps
- Finds Library data (Preferences, Application Support, Caches, Containers, Group Containers, Saved State, WebKit, Logs…) whose reverse-DNS bundle identifier no installed app, helper, login item, or extension claims — and that no running app uses.
- Never includes macOS's own data; same-developer or recently changed items are flagged "check first"; nothing is preselected.

### More system junk and the Trash
- Mail attachments (review) and iPhone/iPad firmware `.ipsw` files (rebuildable), each with its own allowlist.
- The Trash card shows what the Trash holds. **Empty Trash** is a separate, permanent action with its own warning (it can't be restored from History) and is performed by Finder.

### Cleaner
- User caches, logs, browser caches, developer junk, diagnostics, device backups, and old installers.
- Safe-by-default selection; review items are opt-in; restricted items cannot be selected.
- Category/path allowlists are revalidated immediately before cleanup.
- Search, risk filtering, safe-only selection, deselect-all, Finder reveal, and per-path exclusion.
- Selected review bytes are explicitly called out in the destructive confirmation.

### Review, undo, and restore
- Every action that moves files (Cleaner, Uninstall, Duplicates, Large Files) builds one **plan** and opens the same review sheet: what will move, why, from which screen, and which items need a closer look.
- Overlapping selections are counted once (a selected folder covers its children); excluded items are listed as "won't be moved".
- A shared executor re-checks each item right before moving it: same file as planned (device/inode), not excluded, allowed for its kind, and dependencies met (app data only moves if its app did).
- Progress with Stop; a result sheet with **Undo**; per-item **Restore** in History (never overwrites — offers another folder instead).
- A journal is written during each operation, so an operation interrupted by a crash or quit is recovered into History on next launch.
- The **Review** screen collects selections from every screen into one final pass.

### Trash-first cleanup
- Uses macOS Trash rather than permanent deletion.
- Rechecks item existence and safety immediately before acting.
- Records actual bytes moved and per-item failures.
- Maintains a local cleanup audit trail.

### Application uninstaller
- Inventories `/Applications` and `~/Applications`.
- Reads bundle metadata and app size.
- Searches common user Library locations for leftovers.
- Bundle-ID matches receive high confidence; name-token matches remain review-only.
- Related-data deletion is restricted to known user Library support roots.
- App and selected leftovers move to Trash; running apps must be quit first, and related data stays untouched if moving the app fails.

### Polish
- **Owners:** cleanup and developer rows show the app that owns the data (name and icon), from explicit owners, bundle-ID folder names, or a curated list of well-known caches.
- **⌘K command palette:** jump to any screen, run common actions, or find an item from current results.
- **Disk insights** (Performance): drive health (SMART), file system, purgeable space, and local Time Machine snapshots. These are explained, never "cleaned".

### Large Files
- Instant results from the Spotlight index, each re-checked on disk and with the same exclusions applied. Falls back to a full walk, and **Full Scan** includes unindexed folders.
- User-selectable scan root.
- Configurable thresholds: 100 MB, 500 MB, 1 GB, or 5 GB.
- `~/Library` and `.Trash` are excluded from generic review scans.
- Explicit review before moving a file to Trash.
- Per-file Finder reveal and scan exclusion.

### App updates
- The **Updates** tab under Applications checks App Store apps (via Apple's public lookup), apps that update themselves (their Sparkle appcast, ignoring beta channels), and Homebrew casks (offers `brew upgrade --cask`).
- It only runs when you click "Check for Updates", and only app identifiers and feed URLs are requested. MacMint never downloads or installs anything.

### Duplicate Finder
- Candidate grouping by logical file size.
- 64 KB sample SHA-256 stage.
- Full **streaming** SHA-256 verification for exact matches without loading multi-GB files into memory.
- Configurable minimum size.
- Bulk reviewed selection with an invariant that at least one copy remains in every duplicate group.
- Thumbnails and Quick Look for every copy.
- **Auto-select** with keeper rules: newest, oldest, shortest path, or preferred folders. Hard links of the kept copy are never selected.
- Nothing is selected automatically.

### Startup Items
- Read-only inventory of user/system LaunchAgents and LaunchDaemons.
- Shows label, program, scope, RunAtLoad, KeepAlive, and disabled state.
- Direct Finder reveal and System Settings access.
- No fake privileged mutation from the base app.

### Exclusions + privacy
- Persisted local exclusions used by cleanup, app-leftover, duplicate, and large-file scans. An exclusion inside a cache folder splits that folder instead of letting the parent be removed whole.
- No telemetry. Network use is limited to account sign-in and license checks.
- Cleanup history (with Trash locations for each moved item) and exclusions are local JSON files under `~/Library/Application Support/MacMint`.

## V2 user interface

V2 replaces the basic utility-style presentation with a consumer-facing SwiftUI layout while keeping the same underlying engine:

- branded sidebar shell with disk-space footer;
- Smart Scan hero with storage ring and safety/privacy status;
- module cards for Cleaner, Apps, Large Files, Duplicates, Startup Items, History, and Exclusions;
- bottom operation/status bar with cancellation and scan-issue access;
- dedicated scan-issue sheet instead of silently swallowing inaccessible paths;
- stronger review tables, risk badges, selection summaries, filtering, sorting, and contextual actions;
- polished empty/loading states and clearer destructive confirmations.

## Updates and releases

- The app checks the published release feed (PocketBase `app_releases`, stable channel) at launch and daily. It shows a banner when a newer version exists, and a stronger one when the installed version is below `app_config.client.min_version`. Downloads open in the browser so Gatekeeper verifies them.
- Tagging `vX.Y.Z` runs the **Release** workflow, which builds, signs with Developer ID, notarizes, staples, and publishes a GitHub release. Without signing secrets it publishes an ad-hoc-signed **pre-release**. See [`docs/RELEASING.md`](docs/RELEASING.md).

## Safety model

1. Cleanup actions move items to **Trash**, never permanently erase them.
2. `Desktop`, `Documents`, `Pictures`, `Movies`, and `Music` are blocked from automatic cleanup.
3. `/System`, `/Library`, `/usr`, `/bin`, `/sbin`, and `/private` are blocked from base cleanup writes.
4. Cleanup targets must pass **category-specific path allowlists** immediately before deletion.
5. Generic Large Files/Duplicates review cannot remove `~/Library` or system paths.
6. App leftovers can only be removed from known user Library support locations.
7. Symlinks are rejected by destructive safety checks.
8. Review-risk cleanup items are never preselected.
9. Duplicate bulk selection cannot select every copy in a group.
10. Privileged system maintenance is intentionally not faked with `sudo` shell execution.

## Core validation

```bash
swift test
```

Current V2 regression suite: **18 tests** covering:

- SHA-256 known vector;
- streaming-file hash equivalence;
- streaming hash cancellation;
- baseline automatic-cleanup safety;
- reviewed-file safety;
- category/path mismatch rejection;
- installer path/extension restrictions;
- exact duplicate detection;
- duplicate exclusions;
- cleanup review-selection defaults;
- cleanup exclusions;
- persisted IgnoreStore behavior;
- exact bundle-ID leftover matching plus longer-ID false-positive rejection;
- specialized developer-cache categorization and allowlist coverage;
- large-file protected-root exclusion;
- cleanup-engine rejection of unsafe selected targets.

## Requirements

- macOS 14+
- Swift 6 toolchain / Xcode command-line tools
- Full Disk Access is optional; without it, protected locations may be reported as scan issues rather than inspected.

## Run from source on macOS

```bash
swift run MacMint
```

## Build a local `.app`

```bash
./scripts/build_app.sh
```

The script now:

1. runs the core regression suite;
2. validates `Resources/Info.plist` with `plutil`;
3. builds the release `MacCleaner` executable;
4. constructs `dist/MacMint.app` and `dist/MacMint.zip`;
5. ad-hoc signs it for local testing;
6. verifies the code signature;
7. opens the app unless `NO_OPEN=1` is set.

## Architecture

```text
MacCleanerHybridBase V2
├── MacCleanerCore
│   ├── CleanupCatalog + CleanupScanner
│   ├── SafetyPolicy + CleanupEngine
│   ├── FileSystem metadata/size helpers
│   ├── streaming SHA256 + DuplicateFinder
│   ├── LargeFileFinder
│   ├── AppScanner + leftover confidence matcher
│   ├── StartupItemScanner
│   ├── IgnoreStore
│   ├── HistoryStore
│   └── SmartScanService
└── MacCleanerApp
    ├── AppViewModel operation coordinator
    ├── dashboard + storage visualization
    ├── cleaner review/filter UI
    ├── application uninstaller UI
    ├── large-file review UI
    ├── exact-duplicate review UI
    ├── startup inventory
    ├── history + settings/exclusions
    ├── scan issue presentation
    └── macOS Trash adapter
```

## Changelog

See [`CHANGELOG.md`](CHANGELOG.md).

## V1 → V2 upgrade record

See [`docs/V2_UPGRADE.md`](docs/V2_UPGRADE.md) for exactly what was preserved and what changed. The original V1 folder remains separate and untouched.

## Research and licensing

See [`docs/RESEARCH.md`](docs/RESEARCH.md). The implementation is a fresh hybrid architecture. Restrictive-reference projects were used for research only; they are not vendored into this base.

## Before a commercial release

- Replace the example bundle identifier.
- Add final product branding/app icon.
- Run the macOS CI build and real-device UI tests on supported Macs.
- Sign with a Developer ID certificate and notarize.
- Add a narrowly scoped signed `SMAppService`/XPC privileged helper only if system-level maintenance becomes a requirement.
- Add TOCTOU-resistant file identity validation before expanding destructive scope beyond the current user-owned contract.
- Add UI automation and performance benchmarks using large directory trees before calling the product production-complete.
