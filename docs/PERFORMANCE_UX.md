# Performance interface review

The user's ProcessX screenshots make the relationship between resource use and action easy to see: a visible summary, aligned CPU/memory columns, a usage bar next to each value, and controls on the same row. Its [official product page](https://avantigroupai.github.io/processx-web/) also describes resource cards that select sorting and columns that keep actions within reach. This is source/design research, not a hands-on certification of ProcessX's measurements or process-control engine.

## Decisions for MacMint

- Give CPU and memory the strongest visual hierarchy. Their cards select the corresponding sort, so a concerning summary leads directly to the relevant app list.
- Use aligned columns, monospaced values, compact app identity, readable usage bars and visible Quit. Keep Force Quit secondary and confirmed through the existing coordinator.
- Keep search, sort direction, result count, Pause and sample freshness close to the list. A paused list must retain its displayed snapshot and say that it is paused.
- Use a neutral workspace in both appearances. Reserve color for concise status and actions; selected rows should not turn the main workspace green.
- Distinguish global CPU utilization from an app's CPU percentage. The global card describes the machine; an app's 100% means one core. Preserve values above 100% and explain how its meter relates to machine capacity.
- Explain memory pressure and keep unknown readings unknown. A large memory number alone does not establish that quitting an app will improve responsiveness.
- State the inventory boundary. Each row is a regular app plus the helper processes in its own process tree (browser renderers, editor extension hosts and the tools they start), with an expandable breakdown. Attribution follows parent links only: each process is counted once, under the nearest running app above it; a reused parent PID (parent started after the child), a missing parent or a launchd parent leaves a process unattributed. Helpers macOS starts on an app's behalf (XPC services, some web content) are therefore not counted, and the status line says so. Remote SSH work appears only as its local client processes; a server's memory is not this Mac's memory.
- Attribution is read-only. Quit, Slow and Auto Tame keep acting on the app's own process only, and Auto Tame decides from that process's CPU, not the family total. The process listing (one `proc_listallpids` plus one BSD-info call per process) runs only while the Performance list is visible.

The UI continues to use the existing lightweight monitor, lease lifetime, adaptive cadence, PID/start-time/owner checks and final action validation. It adds no polling timer, shell sampling or AI inference. Preview fixtures contain display data rather than process-control handles.

GPU measurements, CPU caps, background priority changes and Auto Tame are separate engineering work. A visible control must have an implemented, tested operation; this interface pass does not create those features. In particular, percentage caps require explicit handling of suspension, foreground transitions and crash-safe restoration before they can be offered.

## Verification

Exercise sorting with unknown and nonfinite CPU values, deterministic ties, case-insensitive search, whitespace/PID/bundle filtering and bounded meter fractions. Native captures should cover populated, paused, high-pressure and unavailable-reading states at full and compact window widths, in both appearances. Inspect those artifacts in addition to compiling.

Normal native startup checks remain important: isolated rendering did not catch the earlier MenuBarExtra feedback loop. Real app quitting must be checked only with disposable applications; synthetic fixtures and screenshots establish presentation behavior, not that a user's real work can be interrupted safely. Longer Instruments sessions on Intel and Apple silicon remain necessary before making battery or daily-use CPU/RAM claims.

The macOS 26 offscreen images omit the glass-backed sidebar when captured through `cacheDisplay`; geometry checks alone do not verify its pixels. The Performance detail and the macOS 15 sidebar can be inspected in their artifacts. Ordinary macOS 26 sidebar drawing and interaction remain a separate native check; no Screen Recording permission is requested to work around this capture limitation.

## MacMint's own resource budget

A cleaner that costs noticeable CPU or memory contradicts its purpose, so the packaged-app probe (`scripts/native_startup_test.swift`, `MACMINT_RESOURCE_SCENARIOS=1` in macOS CI) measures MacMint itself and fails the build when a budget is exceeded. Readings are `proc_pid_rusage` CPU-time deltas (percent of one core) and `phys_footprint`, the number Activity Monitor shows as Memory.

| Scenario | What runs | Budget |
|---|---|---|
| (a) Overview idle | Fresh launch, Overview in front, 30 s | CPU ≤ 0.5% |
| (b) Live Performance view | Performance in front with ~10 regular apps, 60 s | CPU ≤ 2% |
| (c) Hidden | Same app hidden on Performance; 30 s measured from 5 s after hiding | CPU ≤ 0.2%, no monitor samples |
| (d) Heavy session | Map 80k generated files, scan 300 generated photos, return to Overview, then hide; 30 s measured from 5 s after hiding | Overview CPU ≤ 0.5%, hidden CPU ≤ 0.2%, settled footprint ≤ 85 MiB, footprint after 35 s hidden ≤ fresh launch + 35 MiB |

Both hidden scenarios start their budget 5 s after hiding. Hiding itself is one-time work (macOS redraws controls as inactive and orders the windows out): on a heavy session's Overview it was one second at about 10% of a core, then 0.00–0.3% per second (CI trace, 2026-10-21). Measuring from the moment of hiding averaged that second into the 30 s window (0.23–0.38%), while (c) already waited. The first 5 s are reported as "hiding" without a budget, and the background memory release 10 s after hiding stays inside the budgeted window.

Ordinary hidden launches (menu bar off/on) must stay under 2% after settling, the live view must take at least five samples a minute, and hidden or Overview launches must take none.

Before and after this work, on CI runners (macOS 15 / macOS 26):

| Scenario | Before | After |
|---|---|---|
| (a) Overview idle CPU | 0.05% / 0.07% | 0.03% / 0.02% |
| (b) Live Performance CPU (60 s) | 2.25% / 1.91% | 0.92% / 0.59% |
| (c) Hidden on Performance CPU | 0.46% / 0.45% (still sampling) | 0.13% / 0.04% (no samples) |
| (d) Session peak footprint | 152.5 / 159.3 MiB | 62.6 / 68.2 MiB |
| (d) Settled on Overview | 149.7 / 157.7 MiB | 53.3 / 66.1 MiB |
| (d) After 30 s hidden | 149.8 / 160.5 MiB | 53.1 / 69.1 MiB |

Why the hidden allowance is 35 MiB rather than 15: after release the compacted map and scan results are about 2-3 MB of a ~30 MB live heap. The rest is runtime and framework state from the screens that were used (Swift metadata, Objective-C method caches, SwiftUI graph), and allocator pages macOS keeps for reuse; macOS 26's allocator keeps about 52 MB dirty for 31 MB live. Returning further would need the scans in a separate process.

Probe launches pass `--resource-probe <temporary folder>`: the app keeps History, exclusions, snapshots and slowdown records in that folder and only reads the generated fixtures. Companion apps (Calculator, Stickies and similar) are launched only on disposable CI runners and only those exact instances are quit. With `MACMINT_PROBE_PROFILE=1` the step also saves `sample`, `heap` and `footprint` output as the `MacMint-Resource-Report` artifact, and the job summary carries the table.

Rules that keep the numbers there:

- Sampling is lease based. Window leases sample only while the workspace is in front (app active, unhidden, a normal window visible and not minimized or covered); the open menu bar popover and Auto Tame keep their own leases. Auto Tame shares the one timer and samples without publishing readings to views.
- Important-usage free space can make macOS compute purgeable space, so it is read at most once a minute. Disk insights (`diskutil`, `tmutil`) are cached for ten minutes.
- Per-sample readings live in `SystemMonitor.live`; only the cards, status text and process rows observe them. Rows are equatable display values built once per reading, meters scale a fill instead of measuring with a GeometryReader, and the row menus sit in their own equatable view.
- Previews, icons and Finder icons are bounded caches. They are released when leaving their screen, when the workspace window closes, after ten seconds hidden or in the background, and on memory-pressure warnings, followed by `malloc_zone_pressure_relief`. Leaving Storage keeps the totals, the visible levels, the trail and every selected item, and drops deeper folders, which are mapped again when opened. Selections, the review queue, History and recovery records are never released.
- Mapping drains an autorelease pool per folder and keeps nodes without the enumerator's prefetched URL values.
