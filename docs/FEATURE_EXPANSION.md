# Photo review, process controls, and file organization

The product direction is fast inspection with explicit, reversible decisions. The user selected **preview proposed names and moves, then approve** for AI organization. That choice applies before adding watched-folder automation.

## Implemented in this branch

### Photo review deck

Photos → Review deck offers one large, aspect-fit preview, left/right swipe or arrow-key choices, progress, comparison, keeper protection, and Undo choice. Left queues removal; right keeps the item. It does not delete on a gesture. The existing reviewed Trash flow handles folder files, and PhotoKit's system confirmation handles library assets. Library deletion may sync to other devices, and recovery remains through Photos.

The current pass reviews the scan's photos. Similar, blurry, and screenshot views remain available alongside it. Similarity is a local perceptual judgment; exact duplicate detection remains the hashing-based Duplicates tool. Changing a keeper is explicit. A new scan resets the deck; removing unrelated files does not.

Folder preview decoding is serialized off the main actor, with cancellation before opening queued work. Photo previews have a 32 MiB estimated LRU cache budget; Quick Look previews have 16 MiB. Views release their retained image on disappearance. These are **cache budgets**, not a promise that the whole application uses 48 MiB. Visible images, metadata, decoded buffers, and frameworks require additional memory. Modification timestamps invalidate edited image previews, including PhotoKit assets.

Photo scan indexes resolve group membership, filename candidates, and selected IDs without traversing the full library per choice. The 100,000-photo benchmark includes these indexes and repeated queue lookups so their memory cost remains inside the existing gate.

### Running apps

Performance lists regular user applications with search, CPU/memory sorting, PID, memory footprint, and main-process CPU. 100% app CPU means one core; the system gauge represents all cores. Helper-process aggregation is not implemented; Activity Monitor remains the complete process view.

Quit asks the app to save and exit normally. Force Quit has a separate destructive confirmation. Before sending either request, MacMint verifies the LaunchServices application object, bundle identifier, kernel process birth time, and current user ownership. MacMint, Finder, Dock, loginwindow, SystemUIServer, Control Center, PID 1, and unknown bundle identities cannot be controlled here. A returned success means the request was sent, not that termination has completed.

Kernel/filesystem sampling runs in a serial utility actor. Idempotent view leases select the fastest visible consumer and stop polling when none remain. The Performance window pauses its lease while inactive, and offers Pause/Resume. The menu-bar popover owns its own lease. Sampling slows to at least eight seconds in Low Power Mode and twelve seconds during serious/critical thermal pressure, with timer tolerance. No app icons are loaded by the sampler. XNU's rusage CPU and wall-time counters share the Mach absolute timebase; their deltas are divided directly, avoiding a nanosecond assumption on Apple silicon.

This is monitoring and explicit process control. **Automatic background-app throttling is not implemented.**

### Organizer

Storage → Organize opens a bounded, shallow inventory of supported local documents and media. At most 500 direct entries are inspected, 100 eligible files and 24 existing destination subfolders are retained. The UI reports the limit and skipped entries. It excludes symlinks, hard-linked files, placeholders, managed photo libraries, packages, app data, repositories, hidden files, unsupported file types, and saved exclusions. It currently handles files, not folder renaming or recursive reorganization.

File-type suggestions and manual name/destination edits work locally. AI suggestions use the current names only; they cannot infer document contents. A separate consent sheet freezes and displays the complete outbound names/IDs for every request. No full path, file bytes, image, or document text is transmitted by the Organizer. Names can still disclose personal information, and the consent copy says so. Canceling, signing out, changing folders/exclusions, withdrawing AI consent, or closing the organizer invalidates pending advice.

The provider supplies known file IDs, known destination-folder IDs, a proposed basename, and a reason. The backend and portable core validate these again. The provider supplies no absolute paths or executable actions. Extensions are preserved. Invalid names, traversal, unknown IDs, duplicate destinations, collisions, changed sources, replaced/symlinked parents, cross-volume moves, and mounted volumes below home are rejected. Nothing is selected automatically, and editing deselects the row until the user approves it again.

Apply checks paid authority and exclusions in the app coordinator. A durable record is written before each move. Exclusive descriptor-relative renames refuse overwrite. Source identity/metadata and opened directory identities are checked immediately before movement. The resulting file identity is verified too; directories are synced afterward. A post-move persistence failure retains the intent for reconciliation. Operation IDs make retries idempotent.

Organization History is separate from Trash receipts and is reachable from main History without activation. Undo writes its intent first and refuses changed files or occupied original locations. Uncertain moves remain explicit. Corrupt records are retained and reported while readable records remain available. Unrelated scan findings/selections survive; changed paths and affected storage maps are invalidated.

The Anthropic route uses structured output, the existing transactional request/currency/token reservation engine, cache-token settlement, model allowlist, plan checks, and a separate daily allowance. **`features.organize` must explicitly be true; absence means off.** Migration `1792109300_organization.js` adds accounting and defaults the feature off. No production configuration has been changed.

## Research and resulting choices

- [NameQuick on Setapp](https://setapp.com/apps/namequick) is a likely match for the remembered app. Its content-based naming, templates, watched folders, and filing rules establish useful workflow references. [Its official site](https://www.namequick.app/) describes review-first operation, history, provider selection, and local-model options. MacMint starts with name-only, reviewed proposals; content extraction needs a new privacy contract and resource limits.
- [App Tamer's management documentation](https://www.stclairsoft.com/AppTamer/help/pages/managing.html) describes background suspension, lower priority, efficiency-core preferences, periodic waking, and exceptions for browsers/audio. This makes Auto Tame a lifecycle/scheduling subsystem, not a button that periodically kills high-CPU apps.
- [Apple's NSRunningApplication guidance](https://developer.apple.com/documentation/appkit/nsrunningapplication) says application identity should not be reduced to the PID. [Force termination](https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate%28%29) may return before exit. The implementation respects both limits.
- [Apple XNU rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) and [task counters](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c) establish the shared Mach counter units used by process CPU calculations.
- [Anthropic structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs) use `output_config.format`. Schema compliance does not establish safe filesystem behavior; local validation and approval remain authoritative.
- [Apple's FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html) describes coalescing, overflow, and catch-up requirements. A future watcher must rescan on lost events rather than treating each event as a complete change record.

## Next stages and acceptance gates

1. **Validate this pass on a real Mac.** Exercise trackpad gestures, keyboard focus, VoiceOver, cloud-only previews, real photo deletion/recovery, unresponsive test apps, sign-in within the Organizer, and full/damaged storage. Profile app idle, open Performance, fast photo navigation, and cancellation using Instruments on Intel and Apple silicon. Synthetic CI gates do not establish battery life or production responsiveness.
2. **Enable AI organization in staging.** Apply the migration; test authenticated proposals, invalid/malicious names, unchanged suggestions, empty results, quota exhaustion, timeouts, concurrent reservations, and provider refusals. Then run a small, explicitly cost-bounded Anthropic canary. Keep the production feature off until this passes.
3. **Add templates before autonomous filing.** Offline naming patterns, date/sequence rules, and reusable destination choices offer predictable value without a network request. Keep previews, collision checks, preserved extensions, and the same journal/Undo engine.
4. **Add selected-folder watching.** Use FSEvents with a small selected scope, debounce bursts, wait for stable writes, ignore downloads/temp files, suppress MacMint's own moves, and queue bounded batches. One inference request may run at a time. Respect low power, heat, offline state, account budgets, and active cleanup. New batches become proposals. Automatic name sharing requires a separate, explicit persistent grant for that folder; per-request consent in this version does not authorize it.
5. **Prototype Auto Tame independently.** Start with observation and suggested rules. Establish which supported public OS controls can lower background resource use and restore it reliably. A foreground app, audio/video call, download, build, backup, or user-protected app must not be suspended blindly. Test foreground transitions, sleep/wake, exit/crash recovery, identity reuse, and privilege requirements using disposable apps. Never auto-force-quit. Do not ship a “CPU limit” label for ordinary niceness or MacMint's own sampling controls.
6. **Expand organization only after recovery evidence.** Content-based document/image naming needs format-specific extractors, strict byte/page/pixel/time limits, previewed content consent, and prompt-injection tests. Folder renaming, recursive moves, new-directory creation, cloud sync, and external volumes need their own identity, dependency, and recovery tests before being exposed.

## Validation evidence to retain

Portable regression cases cover no-overwrite Apply/Undo, repeated operation IDs, source replacement, traversal/extensions/IDs, exclusions, symlink destinations, pre-move disk failure, post-move interrupted intent, corrupt journal preservation, and bounded inspection. Native coordinator tests cover activation, local Undo with unavailable exclusions, and preservation of unrelated photo/file selections. Existing macOS CI compiles the app, exercises native Trash/volume/account cases, captures light/dark UI states, and launches the downloaded ZIP on a separate runner. Backend tests use a disposable PocketBase, loopback provider, and local SMTP; they do not spend provider money or modify production.
