# Performance interface review

The user's ProcessX screenshots make the relationship between resource use and action easy to see: a visible summary, aligned CPU/memory columns, a usage bar next to each value, and controls on the same row. Its [official product page](https://avantigroupai.github.io/processx-web/) also describes resource cards that select sorting and columns that keep actions within reach. This is source/design research, not a hands-on certification of ProcessX's measurements or process-control engine.

## Decisions for MacMint

- Give CPU and memory the strongest visual hierarchy. Their cards select the corresponding sort, so a concerning summary leads directly to the relevant app list.
- Use aligned columns, monospaced values, compact app identity, readable usage bars and visible Quit. Keep Force Quit secondary and confirmed through the existing coordinator.
- Keep search, sort direction, result count, Pause and sample freshness close to the list. A paused list must retain its displayed snapshot and say that it is paused.
- Use a neutral workspace in both appearances. Reserve color for concise status and actions; selected rows should not turn the main workspace green.
- Distinguish global CPU utilization from an app's CPU percentage. The global card describes the machine; an app's 100% means one core. Preserve values above 100% and explain how its meter relates to machine capacity.
- Explain memory pressure and keep unknown readings unknown. A large memory number alone does not establish that quitting an app will improve responsiveness.
- State the inventory boundary: current rows cover regular apps' main processes, rather than aggregating every helper or system process. Do not present a browser total or expandable process group without the corresponding inventory and ownership evidence.

The UI continues to use the existing lightweight monitor, lease lifetime, adaptive cadence, PID/start-time/owner checks and final action validation. It adds no polling timer, shell sampling or AI inference. Preview fixtures contain display data rather than process-control handles.

GPU measurements, CPU caps, background priority changes and Auto Tame are separate engineering work. A visible control must have an implemented, tested operation; this interface pass does not create those features. In particular, percentage caps require explicit handling of suspension, foreground transitions and crash-safe restoration before they can be offered.

## Verification

Exercise sorting with unknown and nonfinite CPU values, deterministic ties, case-insensitive search, whitespace/PID/bundle filtering and bounded meter fractions. Native captures should cover populated, paused, high-pressure and unavailable-reading states at full and compact window widths, in both appearances. Inspect those artifacts in addition to compiling.

Normal native startup checks remain important: isolated rendering did not catch the earlier MenuBarExtra feedback loop. Real app quitting must be checked only with disposable applications; synthetic fixtures and screenshots establish presentation behavior, not that a user's real work can be interrupted safely. Longer Instruments sessions on Intel and Apple silicon remain necessary before making battery or daily-use CPU/RAM claims.
