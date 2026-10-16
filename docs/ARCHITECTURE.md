# Architecture

## Goal

Create a lightweight native macOS maintenance application that is useful immediately and can grow toward a CleanMyMac-class utility without making unsafe deletion or licensing choices part of the foundation.

## Boundaries

### `MacCleanerCore`
Pure Foundation logic. No SwiftUI or AppKit dependencies.

- `CleanupCatalog` declares supported cleanup targets and risk.
- `CleanupScanner` calculates reclaimable user data.
- `SafetyPolicy` is the write gate for automatic cleanup.
- `CleanupEngine` executes only reviewed targets through a `TrashService` abstraction.
- `DuplicateFinder` performs staged exact-content verification.
- `AppScanner` inventories apps and predicts related user Library files.
- `LargeFileFinder` enumerates review-only candidates.
- `StartupItemScanner` parses launchd property lists without mutating them.
- `SmartScanService` coordinates independent scanners concurrently.
- `HistoryStore` records local operations.

### `MacCleanerApp`
macOS-specific presentation and OS integration.

- SwiftUI views/view model
- AppKit folder picker, icons, Finder reveal
- `FileManager.trashItem` adapter
- confirmation UI
- local `.app` packaging script

## Security posture

The base intentionally has **no root helper** and no arbitrary shell-command runner. That lowers blast radius during product development. If system-level maintenance becomes a requirement, introduce a helper as a new trust boundary:

1. signed helper embedded in the app;
2. `SMAppService` registration;
3. narrow `NSXPCConnection` protocol using typed operations, not arbitrary paths/commands;
4. allowlisted operations and canonical path validation;
5. authorization UX only at the moment elevated access is needed;
6. operation logging and rollback where possible;
7. dedicated tests for symlinks, path traversal, races, and confused-deputy attacks.

## Deletion semantics

The normal deletion primitive is macOS Trash. Cleanup of known caches is reversible until the user empties Trash. Personal-file modules are always explicit review surfaces and are not included in automatic cleanup.

## Expansion path

Strong next modules:

1. disk treemap + historical snapshots;
2. app updater via Sparkle feeds/Homebrew/App Store metadata;
3. menu-bar system monitor;
4. scan-plan export / dry-run diff for advanced review;
5. signed privileged helper for specifically enumerated system tasks;
6. safe scheduler/LaunchAgent owned by this app;
7. optional developer-tool adapters (Docker/Ollama/JetBrains) with dry-run commands;
8. notarized release pipeline and update channel.


## V2 reliability additions

V2 preserves the original architecture while adding cancellation-aware scan reports, persisted exclusions, category-specific destructive allowlists, explicit scan issue propagation, bulk duplicate keeper protection, and a MainActor operation coordinator in the app layer. The privileged-helper boundary is unchanged: system-owned mutation remains out of scope for the base.
