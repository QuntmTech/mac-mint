# Mac Cleaner Hybrid Base V2

A native **Swift 6 + SwiftUI** macOS cleaner/uninstaller foundation evolved directly from the original `mac-cleaner-hybrid-base` — **not a rewrite**.

V2 keeps the working V1 core (cleanup catalog, Trash-first deletion, streaming SHA-256, duplicate detection, application scanner, startup inventory, history, and safety policy) and upgrades it in-place for stronger reliability, safer destructive operations, better scan visibility, exclusions, cancellation, richer review flows, and a substantially more polished desktop interface.

## What works now

### Smart Scan
- Runs cleanup, installed-app, and startup-item scans concurrently.
- Reports safe reclaimable bytes separately from review-only bytes.
- Records scan duration/date and filesystem issues.
- Supports cancellation instead of forcing a long scan to finish.
- Honors persisted scan exclusions.

### Cleaner
- User caches, logs, browser caches, developer junk, diagnostics, device backups, and old installers.
- Safe-by-default selection; review items are opt-in; restricted items cannot be selected.
- Category/path allowlists are revalidated immediately before cleanup.
- Search, risk filtering, safe-only selection, deselect-all, Finder reveal, and per-path exclusion.
- Selected review bytes are explicitly called out in the destructive confirmation.

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

### Large Files
- User-selectable scan root.
- Configurable thresholds: 100 MB, 500 MB, 1 GB, or 5 GB.
- `~/Library` and `.Trash` are excluded from generic review scans.
- Explicit review before moving a file to Trash.
- Per-file Finder reveal and scan exclusion.

### Duplicate Finder
- Candidate grouping by logical file size.
- 64 KB sample SHA-256 stage.
- Full **streaming** SHA-256 verification for exact matches without loading multi-GB files into memory.
- Configurable minimum size.
- Bulk reviewed selection with an invariant that at least one copy remains in every duplicate group.
- Nothing is selected automatically.

### Startup Items
- Read-only inventory of user/system LaunchAgents and LaunchDaemons.
- Shows label, program, scope, RunAtLoad, KeepAlive, and disabled state.
- Direct Finder reveal and System Settings access.
- No fake privileged mutation from the base app.

### Exclusions + privacy
- Persisted local exclusions used by cleanup, app-leftover, duplicate, and large-file scans.
- No telemetry.
- No network calls in the base.
- Cleanup history and exclusions are local JSON files under Application Support.

## V2 user interface

V2 replaces the basic utility-style presentation with a consumer-facing SwiftUI layout while keeping the same underlying engine:

- branded sidebar shell with disk-space footer;
- Smart Scan hero with storage ring and safety/privacy status;
- module cards for Cleaner, Apps, Large Files, Duplicates, Startup Items, History, and Exclusions;
- bottom operation/status bar with cancellation and scan-issue access;
- dedicated scan-issue sheet instead of silently swallowing inaccessible paths;
- stronger review tables, risk badges, selection summaries, filtering, sorting, and contextual actions;
- polished empty/loading states and clearer destructive confirmations.

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
swift run MacCleaner
```

## Build a local `.app`

```bash
./scripts/build_app.sh
```

The script now:

1. runs the core regression suite;
2. validates `Resources/Info.plist` with `plutil`;
3. builds the release `MacCleaner` executable;
4. constructs `dist/MacCleaner.app`;
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
