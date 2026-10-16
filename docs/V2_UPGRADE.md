# V2 Evolution Record — Built on V1

V2 was created by copying the existing `mac-cleaner-hybrid-base` and modifying it in place. The V1 directory remains intact as the recovery/baseline copy.

## Preserved from V1

- Swift Package structure and `MacCleanerCore` / `MacCleanerApp` split.
- Cleanup catalog concept and risk model.
- Trash-first destructive strategy.
- `CleanupEngine` architecture.
- Streaming SHA-256 implementation.
- Three-stage duplicate strategy: size → sample hash → full hash.
- Installed-application scanner.
- Application-leftover scanner concept.
- Large-file finder.
- Startup-item scanner.
- History store.
- Smart-scan coordinator.
- macOS `FileManager.trashItem` adapter.
- SwiftUI section/navigation architecture.
- macOS packaging script and CI workflow.

## Reliability upgrades

- Added `ScanReport` issue/cancellation/duration propagation across scanners.
- Added cancellation checks throughout potentially long enumerations and hash passes.
- Added persistent `IgnoreStore` and propagated exclusions through scanners.
- Expanded app discovery from only top-level application entries to package-aware recursive enumeration.
- Expanded leftover roots and made exact bundle IDs higher-confidence than app-name token matches.
- Added protected-root exclusions to generic large-file and duplicate scans.
- Added category-specific cleanup allowlists checked again at execution time.
- Added app-leftover-specific deletion allowlists.
- Revalidated reviewed large/duplicate files through a separate safety policy before Trash actions.
- Recorded actual bytes moved rather than assuming scanned size equals final removed size.
- Replaced silent UI failure states with surfaced scan issues/status.
- Fixed duplicate bulk-selection logic so the app will not intentionally select the final remaining copy.
- Re-checks the duplicate keeper invariant again at execution time.
- Blocks app uninstall while the selected app is running and can request a normal macOS quit.
- Leaves related app data untouched when moving the application bundle itself fails.
- Tightened bundle-ID matching so a longer unrelated identifier is not treated as an exact match.
- Fixed a macOS packaging risk: the Swift target no longer declares a nonexistent resource directory.
- Hardened local `.app` packaging with tests, `plutil`, signing, and signature verification.

## UX/UI upgrades

- New branded sidebar shell and disk-capacity footer.
- Smart Scan hero and storage ring.
- Safe/review storage metrics.
- Feature/module navigation cards.
- Persistent operation bar with status, cancellation, and issue count.
- Scan-issue sheet.
- Cleaner search and risk filters.
- Cleaner safe-only/deselect-all controls.
- Per-item exclusion menus.
- Application search + sort and stronger detail view.
- Explicit leftover selection/reclaimable totals.
- Configurable large-file and duplicate thresholds.
- Duplicate group bulk selection with keeper protection.
- Rich startup-state chips.
- Improved history and settings/exclusion surfaces.
- Stronger loading/empty/destructive-confirmation states.

## Validation delta

V1 baseline: **4 core tests**.

V2: **18 core regression tests** plus Swift parser validation for every macOS app source file in the current build environment.

The environment used for this package is Linux, so AppKit/SwiftUI cannot be fully typechecked or launched here. The included GitHub Actions workflow performs the macOS release build when run on GitHub, and `scripts/build_app.sh` performs the full local macOS build/sign/verify path.
