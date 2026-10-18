# App removal, resource controls and photo review — 2026-10-18

This checklist covers the user's complete request, including the two follow-up Photos reports. It supersedes the earlier handoff's statement that Auto Tame is future work. Implementation and validation are separate columns; update the final evidence before merging.

| Phase | Requested behavior | Implementation | Validation |
| --- | --- | --- | --- |
| 1 | Uninstall apps with related caches/metadata; preserve settings when desired | Choose App/Find Apps entry points, categorized consequences, Library matching including ByHost preferences, conservative shared-data defaults, existing reviewed Trash/History pipeline | Portable scanner/executor fixtures; native compile/render pending |
| 2 | Manual slowdown; intelligent automatic mode; never-slow exceptions | Timed Darwin background priority, opt-in Auto Tame, persisted exceptions, Restore/Restore All, lifecycle restoration and durable recovery intents | Policy/storage tests and injected controller faults; disposable native fixture and native UI gates pending |
| 3 | Bulk select and deselect Photos | Current tab, group and all-result deselection; protected keepers; single inventory pass for folder selections | Cross-inventory and PhotoKit-identifier tests; native bulk-selection render pending |
| 4 | Review deck advances but every image is blank | Local 256px fallback, degraded-image preservation, bounded request timeout/cancellation, retry, focus, Skip for unavailable previews, no blind queueing | Callback/fallback tests; real affected iCloud library remains a manual check |
| 5 | Thorough review and push to main | Review implementation, run regression/native gates, inspect screenshots, refresh handoff and merge | In progress on the feature branch |

## Removal boundaries

Apps already had an uninstall engine. This work makes it discoverable and improves its evidence rather than adding another removal path. App bundles plus explicitly selected related files go through the existing planner, final ownership/identity/exclusion checks, durable journal, Trash receipt and History acknowledgment. Related data depends on a successful app-bundle move; failed app removal cannot independently delete its data.

The scanner checks known user Library locations. Exact identifiers can be suggested; name-based and shared matches require judgment. Another installed copy with the same identifier makes matching data shared and unselected. Symlinks and excluded descendants cannot be promoted into removable app data. Nested helper bundles must be removed with the parent app. Caches/logs are distinguished from settings, local databases, projects, saved state and shared containers. The final review marks non-disposable data for attention. System-wide privileged helpers, Keychain secrets, cloud-account data and arbitrary files outside the allowlist are not claimed to be completely removed.

## Slowdown boundaries

The mechanism is `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` and its reversible zero-policy counterpart. It lowers CPU, disk and network priority. It is a scheduling preference, not a hard CPU percentage or RAM cap. It does not suspend a process, inject code, change nice values, purge RAM, or require a privileged helper. Lower priority may make downloads and background work take longer. Existing app sampling covers regular apps' main processes, not helper-process groups.

Manual slowdown lasts 15 minutes or one hour and is restored when the user switches to the app. Auto Tame is off at each MacMint launch. Once enabled it reuses the existing adaptive sampler with an eight-second lease, even when the Performance view is hidden or its display is paused. It requires a background app to sustain at least 80% of one core for 20 seconds while whole-machine CPU is at least 65%. It affects at most two automatic targets; restores after 30 seconds of cooling, after five minutes, when foregrounded, or when excepted; and applies a two-minute cooldown. Missing/nonfinite readings never establish hot activity. Gaps over 25 seconds discard sustained-load evidence. Low Power Mode/thermal cadence limits still apply. No AI requests or high-frequency polling are involved.

Saved exceptions apply to manual and automatic slowdown and survive app relaunches. Auto Tame excludes Apple/system apps and common calling/audio identifiers by default. This list cannot identify every real-time workload: user exceptions remain necessary for custom recording, games and other time-sensitive software. Memory pressure continues to inform Quit guidance; high RAM use alone does not trigger forced memory reclamation or automatic termination.

Identity checks include boot identity, PID, kernel birth time, app bundle ID/path, regular-app status, and same-user ownership immediately before each syscall. A small durable intent is saved before mutation and removed only after restoration (or proof the original process is gone/changed). Query failures remain uncertain and retain the receipt. An exclusive advisory lock prevents two MacMint instances controlling the same recovery journal. Normal quit and system sleep restore controlled apps. After a force quit/crash, reopen MacMint to retry restoration; the priority flag can otherwise remain until the target exits. The OS does not provide this app an atomic check-and-change process handle.

Darwin's external background flag is shared OS state, not an ownership-token API. MacMint tracks its own requests; it does not claim to snapshot or restore arbitrary priority changes made simultaneously by another controller. In particular, `getpriority(PRIO_DARWIN_PROCESS, target)` is not used as proof of another process's baseline: the inspected XNU getter reads `current_task()` for its policy. Native tests check the actual same-user set/clear calls and refusal of a replaced birth identity, not an exact CPU or battery outcome.

Primary references: [Apple setpriority manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setpriority.2.html), [Apple's current XNU resource implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_resource.c), [Darwin public resource constants](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/resource.h).

## Photo review boundaries

Bulk actions only change selections. The current keeper of each similar group stays protected, including user keeper overrides. Folder selections propagate across other inventories in one pass; library assets stay on their separate PhotoKit path. A bulk action invalidates the deck's old Undo trail so an earlier swipe cannot undo a newer selection decision. Deletion continues to require review and either Trash or PhotoKit confirmation.

The reported deck screenshot showed a local-preview failure while Keep advanced normally. Analysis requested 256px local thumbnails, while the deck requested up to 1200px, which can require an iCloud resource even when a small thumbnail is local. Preview loading now retries at 256px locally and accepts an already delivered degraded thumbnail if the larger representation is unavailable. Requests time out after 10 seconds locally/45 seconds with explicitly requested network access and cancel the underlying PhotoKit request. Advancing/cancellation cannot display a previous asset's fallback. Cloud access still requires the explicit button; no analysis cloud download was added.

An unavailable deck image offers Retry/Open Photos and Skip. Queue removal is blocked until a preview for that exact asset is visible. Arrow keys get initial focus; gestures still change selections, not files. Callback tests and synthetic renders cannot reproduce the user's actual iCloud account, local resource eviction or permissions; that journey remains a manual acceptance check.

## Validation evidence

- Portable suite: first expanded run passed 177 tests with zero failures. Final run and native evidence will be recorded below.
- Linux frontend syntax parsing passed for the changed native files. This is not semantic AppKit/SwiftUI compilation.
- New native tests cover durable intent ordering, corrupt/unwritable storage, uncertain/failed restore, relaunch recovery, exceptions, replaced identities, bulk keeper/queue behavior, and PhotoKit degraded/timeout/cancellation paths.
- `NativeTamingTests` compiles and launches its own uniquely identified disposable AppKit app and exercises the actual Darwin adapter. It never targets an existing user app.
- Smoke fixtures include light/dark compact/full tamed/protected rows and Photos bulk selection. Existing minimum visible-row assertions remain enabled.
