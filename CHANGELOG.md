# Changelog

## 0.8.0 — 2026-10-16
- **Smart Care:** ranked, plain-English recommendations across caches, developer data, removed-app leftovers, Downloads, unused apps, screenshots, firmware, and Mail attachments. Every recommendation opens the normal review. ⌘R runs it.
- **Usage intelligence:** Spotlight "last opened" and "date added". An app or file with no record is never called unused.
- **Downloads review:** files not opened in months, grouped by kind.
- **Storage growth:** "grew since last scan" and a daily free-space history chart.
- **App names and icons** on Cleaner and Developer rows.
- **Instant large files** via Spotlight (verified on disk), with **Full Scan**.
- **Disk insights:** drive health, purgeable space, and local Time Machine snapshots (read-only).
- **⌘K command palette;** VoiceOver, keyboard, and contrast improvements.
- **Faster duplicate scans:** memory went from 1.2 GB to 33 MB on a 100k-file folder. A weekly benchmark workflow and a launch smoke test of every screen now run in CI.

## 0.7.0 — 2026-10-16
- **Photos:** similar and blurry shots, and screenshots, from folders or the Photos library. Library removals go through Photos, so they land in Recently Deleted.
- **Removed-app leftovers:** Library data whose bundle identifier no installed app (or helper) claims. Review-only.
- **More system junk:** Mail attachments, iPhone and iPad firmware (.ipsw), and the Trash size, with an explicit, irreversible Empty Trash.
- **App updates:** an Updates tab covering App Store apps, apps that update themselves (Sparkle), and Homebrew casks.
- **Duplicates:** thumbnails, Quick Look, and auto-select by keeper rule (newest, oldest, shortest path, preferred folders).
- **Safety hardening:**
  - A duplicate's kept copy can't be removed in the same operation.
  - Edited and replaced files are skipped.
  - Paths are canonical and case-insensitive.
  - Roots, Apple data, and the Trash are never targets.
  - Restore checks it's moving the same item.
  - The journal is crash-safe.

## 0.6.0
- In-app update notice, release workflow, and Developer ID signing and notarization hooks.

## 0.5.0
- Performance screen, menu bar companion, low-space alerts and scan reminders, onboarding, launch at login, and browser care (Brave, Arc, Vivaldi, Opera; skipped while open).

## 0.4.0
- One review → Trash → restore pipeline for every action, Undo, a History screen with Restore, a Review queue, and the app icon.
- Storage Explorer (treemap) and Developer & AI storage.

## 0.3.0
- Builds on macOS again. All Phase 0 review findings fixed. Sign-in, redemption codes, and device activation.
