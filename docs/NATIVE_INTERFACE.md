# MacMint native interface

The desktop uses a shared, adaptive SwiftUI design system with seven primary workspaces, contextual tabs, and a persistent review action. Local inspection and recovery stay available before account activation. This redesign changes presentation; the existing planner and executor still authorize every removal.

## Appearance

Settings → Appearance and the Appearance menu offer System, Light, and Dark. The choice uses the same `AppAppearance.storageKey` in Settings and the app scene, persists through launches, and applies with `preferredColorScheme` to the main window and the menu-bar window. Sheets inherit their presenting window's preference. System leaves the preference unset so macOS controls appearance.

`Components.swift` owns semantic surface, text, selection, and status colors. Light uses a pale neutral canvas and white cards; Dark uses graphite surfaces and brighter mint text. Surfaces are opaque, so they work with Reduce Transparency. Increased Contrast strengthens shared cards, fields, and action boundaries. Motion is limited and respects Reduce Motion.

Keep new screens on these tokens rather than introducing fixed light backgrounds. White text belongs on the primary action fill and on deliberately dark storage-map colors. `AppearanceTests` measures contrast for primary and status text against all five content backgrounds in both appearances.

## Shared components and flow

- `PageHeader` keeps the title and explanation together, moves actions below when needed, and has an intrinsic vertical size so it cannot push results outside a compact window.
- `SurfaceCard`, `IconTile`, `SearchField`, `MintButtonStyle`, and `CardButtonStyle` provide consistent spacing and interaction. Cards with actions are real buttons; empty states provide relevant next actions.
- The overview gives storage and Quick Scan priority, separates rebuildable findings from items requiring judgment, and offers focused entries to Storage, Apps, Photos, and Developer. Scan coverage remains inspectable.
- Cleanup separates searching, filtering, selection, and final review. Apps separates its inventory from the inspector and supports the existing drop-to-inspect flow. Photo groups prioritize comparison and an explicit keeper.
- Review collects selections across modules. The final sheet preserves item explanations, remove/keep/exclude/reveal actions, warnings, and the explicit Move to Trash confirmation. Recovery language remains conditional on actual receipts.
- Sidebar destinations remember the most recent tab during navigation. Existing destination IDs and keyboard shortcuts are unchanged. Settings and Help remain at the foot of the sidebar.

## Native visual checks

The macOS workflow exports actual `NSHostingView` window captures, including AppKit-backed lists that `ImageRenderer` alone can omit. Synthetic fixtures exercise populated results without a personal library, account, remote image, or provider request. Each hosting window is released before the next state.

To capture locally from a packaged app:

```sh
MACMINT_SCREENSHOT_DIR="$PWD/.build/interface-previews" ./scripts/smoke_test.sh dist/MacMint.app
```

The suite covers every destination in Light and Dark, populated primary workspaces, compact 980 × 660 windows, final review, onboarding, the menu bar, Help, account access, and command search. CI uploads the PNGs as `MacMint-UI-<commit>` artifacts. Without the screenshot environment variable, the downloaded-package job runs the rendering and coordination checks without exporting files.

These checks establish compilation, layout rendering, palette contrast, and existing selection boundaries. VoiceOver, Full Keyboard Access, live system appearance changes, and real Photos permissions still need interactive Mac verification.
