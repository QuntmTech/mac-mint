# Recommendation safety plan (from the build 310 review)

Source: the owner's Codex review of dev-build-310, dated November 14, 2026, which looked at commit `a52e3cb`.
Each finding below was checked against `main` at `a52e3cb`; nothing newer has touched these files.
This is a plan. No behavior changes are in this commit.

## Goal

Recommendations should only claim what MacMint actually checked:
- Anything MacMint can't prove is safe becomes **Review**, not **Rebuildable**.
- "Open apps are skipped" is only said when MacMint knows the owner.
- Results from an old or partial scan say so.

The working safety features stay as they are: review → final check → journaled move to the Trash → History/Restore. That includes the identity checks, exclusions, keepers, path allowlists and running-owner checks.

## Findings confirmed in the current code

| # | Finding | Where (current main) | Confirmed |
|---|---|---|---|
| 1 | Every folder in `~/Library/Caches` and `~/Library/Logs` is rated safe. Owners are worked out only for caches, never for logs. The recommendation still says data for open apps is skipped, even when no owner is known. | `CleanupCatalog.swift` rules for `.userCaches`/`.userLogs`; `CleanupScanner.owner(of:rule:)` returns nil for anything that isn't a cache; `Recommendations.swift` step 1 lets nil-owner items through (`!= false`) | Yes |
| 2 | `node_modules`, `Pods` and `.build` are treated as build output and rated rebuildable, then suggested once idle. They can hold locally patched or private dependencies. | `DeveloperStorage.projectArtifactNames`, `isSuggested` | Yes |
| 3 | Every DerivedData child is rated rebuildable. It can contain dSYMs (release symbols) and editable package checkouts. | `DeveloperStorage.xcodeDerivedData()` | Yes |
| 4 | Removed-app data: the app inventory ignores errors. An unreadable folder looks like "no apps here", which makes data look ownerless. The recommendation calls these "apps you've deleted". The plan item carries no owner ID, so the move can't check that the app is running. | `OrphanScanner.installedBundleIDs()` (`errorHandler: { _, _ in true }`, `try?` → `[]`); `Recommendations.swift` step 5; `PlanItem.orphan` | Yes |
| 5 | The final check confirms a folder's identity, but not that nothing inside it changed or that a command-line tool (`xcodebuild`, npm, uv, a Node runtime) is using it. | `PlanItem.developer/.orphan`; `FileSnapshot` handles files only | Yes |
| 6 | "5 of 5 checks" counts areas that ran, even if they reported issues. Recommendations don't show how old the scan is. | `AppViewModel+SmartCare.swift` `scanCompletedAreas` | Yes |

## Phase 1: honest labels and safer defaults (P1, small, high value)

### PR A: Owner state for caches and logs (finding 1)
- **Owner state:** add an `OwnerEvidence` value: `known([bundleID])`, `toolManaged(tool)`, `shared([bundleID])` or `unknown`. Store it on `CleanupTarget` alongside today's `ownerBundleID`.
- **Logs:** resolve owners the same way as caches. Logs become **Review**: past logs can't be recreated, and new logs don't bring back old events.
- **Unknown owners:** generic cache children with an unknown owner become Review. Caches with a known owner stay Rebuildable. Narrow catalog rules keep their current rating (npm `_cacache`, SwiftPM and CocoaPods download caches, browser caches).
- **Wording:** "Known open apps are skipped. Ownership couldn't be confirmed for N items, so they're left for you to review."
- **Shared owners:** a shared owner blocks the item while any of its apps is running. The executor's running-owner check takes a list of owners.
- **Tests:** an unknown-owner cache is not in the safe bundle. A nil-owner log is not in the safe bundle. A known open owner is skipped. A shared owner is blocked when any of its apps runs. Existing owner tests stay unchanged.

### PR B: Dependencies are not build output (findings 2 and 3)
- **Two kinds of project folder:**
  - `generatedOutput`: `.build`, `target`, `.next`, `.nuxt`, `.turbo`, `.parcel-cache`, `.svelte-kit`, `__pycache__`, `.gradle`.
  - `installedDependencies`: `node_modules`, `Pods`.
- **Dependencies:** rated `.review` and never suggested by default. The detail line says "Installed packages. Reinstalling may not restore local edits or private packages."
- **Patch markers:** projects with `patches/`, `patch-package` in package.json, a CocoaPods `post_install` hook, or a `.patch` file next to the Podfile stay Review even if every other rule is relaxed later.
- **DerivedData:** while sizing, look inside for `*.dSYM` and `SourcePackages/checkouts`. If either exists, the folder becomes Review with "Contains release symbols (N dSYMs)" or "Contains package checkouts". `ModuleCache.noindex` stays Rebuildable.
- **Never generic cache:** `.xcarchive` and anything under `Archives`.
- **Tests:**
  - A Podfile next to a patched Pods folder isn't suggested.
  - A `node_modules` with a `patches/` sibling isn't suggested.
  - A DerivedData folder with a nested dSYM becomes Review.
  - A DerivedData folder whose contents can't be read becomes Review.
  - Plain `.build` and `target` folders are still suggested once idle.
  - The source repository itself is never offered.

### PR C: "App data with no owner found" (finding 4)
- **Coverage:** `installedBundleIDs()` returns an `OwnershipInventory` with the IDs it found, the roots it checked, the roots that failed (with errors), and whether it was cancelled.
- **Incomplete inventory:** if any app root failed or the scan was cancelled, no item is marked "no owner". Results say "Couldn't check /Applications/…; not shown".
- **Wording:** the recommendation says "App data with no owner found", never "apps you've deleted". It lists the roots that were checked.
- **Splitting by kind:**
  - Regenerable caches (`Caches`, `HTTPStorages`, `WebKit` caches) can be suggested.
  - Preferences, Application Support, Containers, Group Containers, Cookies, Saved Application State and databases are never pre-checked. They are reviewed one at a time.
- **Owner check at move time:** `PlanItem.orphan` carries the bundle ID as its owner. Just before the move, the executor rechecks that the app isn't installed or running. A newly installed or launched claimant cancels that item.
- **Tests:**
  - An unreadable app root leaves no "no owner" items.
  - A cancelled inventory leaves none either.
  - An app in a custom location is found through the Launch Services lookup.
  - A shared group container under a different ID stays unknown.
  - An app installed after the review blocks the move.
  - An app launched after the review blocks it.
  - A truly uninstalled app's Preferences stay unchecked.

## Phase 2: freshness and honest presentation (P2)

### PR D: Check activity before moving (finding 5)
- **Activity checker:** add an injectable `ActivityChecker`. Before moving a tool-managed folder, it looks for running processes from known build tools (`xcodebuild`, `swift-build`, `node`, `npm`, `pod`, `uv`, `python`). It matches by executable path or working directory, using `proc_pidinfo` and never reading command-line arguments, so no secrets leak.
- **Recent changes:** it also checks for any change inside the folder since the review, using a bounded scan of the newest file dates (capped at about 2,000 entries or 200 ms).
- **When the checker can't tell:** an unknown or failed check blocks that item with "Couldn't confirm it's idle". The executor's two existing checks are kept; this runs again right before the move.
- **Tests:**
  - Same folder, but a nested file changed after the review.
  - A build tool starts after the review.
  - A Node process has its working directory inside `node_modules`.
  - The owner app launches while the folder is being sized.
  - The inspection is denied permission.

### PR E: Coverage and age next to every claim (finding 6)
- **Areas count:** split "5 areas attempted" from "N fully checked". An area with issues counts as attempted.
- **Recommendation age:** each recommendation shows "Checked 6 days ago". Results older than 24 hours say "Estimate from <date>, scan again for current numbers". They are never shown as space available now.
- **Final check:** sizes and identities are refreshed for the selected items only, and never adds new items.
- **Tiles:** keep units visible at every text size. Use the short form "4.6 GB" in tiles, with the exact size in the tooltip.
- **Tests:**
  - A partial failure is shown as partial.
  - A cancelled scan isn't counted as checked.
  - A folder that denies permission is reported.
  - Stale results are labelled.
  - Results are re-evaluated after exclusions change.
  - Narrow and large-text layouts keep units in the smoke render.

## Phase 3: new, narrowly scoped opportunities (P2, after phases 1 and 2)

**"Quit this app first" bucket:** large known caches whose owner app is open go under "Potential space: quit this app first". They're never selected while the app runs, and MacMint never quits the app itself.

**F. WebCatalog adapter:**
- **Targets:** only leaf folders named `Cache`, `Code Cache` and `GPUCache` inside each profile or partition under `~/Library/Application Support/WebCatalog/photon`.
- **Never selected:** a profile or `Partitions` parent, `Cookies`, `Login Data`, `Local Storage`, `IndexedDB`, `Session Storage`, `Service Worker` or account folders.
- **Unknown layout:** Review only.
- **Tests:** synthetic profiles with valuable neighbor folders, symlinks and unknown layouts.

**G. VS Code adapter:**
- **Targets:** `CachedExtensionVSIXs` (older versions only), `Cache`, and `CachedData` folders for commits other than the current one, read from the app's `product.json` commit.
- **Never touched:** `User`, `WebStorage`, workspace state or `~/.vscode/extensions`.
- **While Code is open:** blocked, with the "quit first" note.

**H. Tool-managed caches (uv first, then npm, CocoaPods and SwiftPM):**
- **How it's cleared:** a separate action type runs the tool's own command (`uv cache prune`/`clean`) and respects the tool's lock.
- **Wording:** "This uses uv's own cleanup and can't be restored from History."
- **Never touched:** installed tools or environments.

**I. Space history:** a cache cleaned before is never promised again as savings; only the current measurement counts.

**J. Cloud-repair backups:** offer "move to external drive" only when asked, never delete.

**Never generic junk:**
- Brave
- Claude VM files
- Docker disks and volumes
- Photos libraries
- Codex runtimes, chats and skills
- cloud databases
- release archives

## Order and size

| Order | PR | Size | Risk to ship | Mainly in |
|---|---|---|---|---|
| 1 | A: owner state | M | Low: only makes things stricter | CleanupCatalog, CleanupScanner, Recommendations, OperationExecutor (shared owners) |
| 2 | B: dependencies and dSYMs | M | Low: only makes things stricter | DeveloperStorage, SafetyPolicy |
| 3 | C: ownership inventory | M–L | Low/Med: changes the Removed Apps page | OrphanScanner, Recommendations, OperationPlan, RemovedAppsView |
| 4 | E: coverage and age | M | Low: wording and labels | AppViewModel+SmartCare, OverviewViews, SmartCareViews |
| 5 | D: activity check | L | Med: touches the executor | new ActivityChecker, OperationExecutor |
| 6 | F/G/H: adapters | M each | Med: new targets | new adapter files, catalog |

PRs A, B and C only make recommendations stricter. Expect smaller "found" totals once they ship. That's the honest number, not a regression.

## How every PR is checked

- **Synthetic folders only:** fixture tests use temporary folders, an injected clock, a fake inventory and fake activity. They never touch the owner's Library, projects or Trash.
- **Full route:** at least one test per PR runs recommendation → plan → normalized review → executor with a fake Trash. Scanner-only tests aren't enough.
- **Release checks:** CI must be green on macOS 15 and 26, including the smoke render and the resource limits (limits unchanged).
- **Per-PR table:** each PR description has a table with each finding, whether it was confirmed, the commit, the tests that cover it, and what's still out of scope.
- **Owner permission:** no real-machine cleanup, Full Disk Access change, AI upload or publish without the owner's go-ahead in chat.
