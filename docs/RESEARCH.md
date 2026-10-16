# Research ledger — macOS cleaner hybrid base

Research date: 2026-08-30

## Primary permissive references

### TJ-84/Mac-Cleaner — BSD-3-Clause
https://github.com/TJ-84/Mac-Cleaner

Useful ideas studied:
- SwiftUI app + shared core + privileged helper separation
- actor/async architecture
- modular cleanup/application/files/system domains
- progressive duplicate verification
- protected-path + trash-first safety model

No source code was copied into this base.

### EPeiffer94/Marmot — MIT
https://github.com/EPeiffer94/Marmot

Useful ideas studied:
- visual change-plan philosophy
- dry-run/review/apply mental model
- risk badges and explainability
- history/audit trail
- trash-first deletion and protected personal zones

No source code was copied into this base.

### Bojun-Vvibe/Purger — MIT
https://github.com/Bojun-Vvibe/Purger

Useful ideas studied:
- small native SwiftUI footprint
- transparent cleanup targets
- all removals routed to Trash
- developer-space cleanup orientation

No source code was copied into this base.

### kandikoushik/disk-cleaner — Apache-2.0
https://github.com/kandikoushik/disk-cleaner

Useful ideas studied:
- parallel scan orientation
- plugin/target mindset
- developer cleanup categories
- multi-pass hash duplicate detection
- menu-bar/status expansion path

No source code was copied into this base.

### syahrul84/cleanUp — MIT
https://github.com/syahrul84/cleanUp

Useful ideas studied:
- honest product language around cache/RAM behavior
- native SwiftUI + Trash-only cleaning
- one-click smart scan
- user-level app leftovers, duplicates, large files, startup inventory

No source code was copied into this base.

## Research-only references — do not copy into a commercial derivative

### bruce019 / Pearcleaner family — Apache-2.0 + Commons Clause
https://github.com/alienator88/Pearcleaner

Pearcleaner's licensing prohibits monetizing Pearcleaner or modified versions. It is excellent research for app-uninstall UX, Finder integration, privileged-helper boundaries, leftovers, and app metadata, but its source is intentionally not incorporated here.

### tw93/Mole — GPL-3.0
https://github.com/tw93/Mole

Mole is a mature reference for cleanup categories, dry-run, whitelisting, uninstall scope, developer cleanup, and operational safety. GPL code was not incorporated so this base can remain permissively licensed.

## Commercial product reference

### CleanMyMac
https://macpaw.com/cleanmymac

Current product patterns studied:
- Smart Care / one-entry scan
- system junk, duplicates, large/old files
- app uninstaller/updater
- login/background items
- maintenance and protection as separate domains
- privileged helper for elevated operations

The base intentionally does **not** claim malware protection. A real malware engine requires a separate detection/signature/update/security program and should not be represented by a superficial file-name scanner.

## Hybrid decisions

| Decision | Source pattern | Base implementation |
|---|---|---|
| Native UI | Multiple SwiftUI cleaners | SwiftUI/AppKit desktop app |
| Core/UI split | Mac-Cleaner | Foundation-only `MacCleanerCore` + UI adapter |
| Smart Scan | CleanMyMac/Mac-Cleaner/CleanUp | async coordinator for cleanup/apps/startup |
| Safety | Marmot/CleanUp/Mac-Cleaner | protected paths, risk levels, Trash-first |
| Duplicate detection | Mac-Cleaner/CleanUp/disk-cleaner | size → sample SHA-256 → streaming full SHA-256 |
| App leftovers | Pearcleaner/Mac-Cleaner | fresh bundle-ID/name matcher across user Library roots |
| Privileged operations | CleanMyMac/Pearcleaner/Mac-Cleaner | deliberately deferred to signed helper boundary |
| History | Marmot | local JSON action log |
| Startup management | Multiple | read-only inventory first; avoid brittle privileged mutation |
