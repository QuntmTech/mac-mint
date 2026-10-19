# Installation and first-run improvements

The default journey is download → open the disk image → drag MacMint to Applications → open the installed copy → inspect locally → optionally connect the purchasing account → review a paid operation. Permissions remain optional and appear at the point of use. No new background scanner, login item, AI request or automatic cleanup is introduced.

| Phase | Concrete change | Acceptance |
| --- | --- | --- |
| Installer | Add a DMG with an Applications shortcut and short installation instructions; retain ZIP compatibility. Consumer releases contain both Apple Silicon and Intel code. | On macOS, mount the generated/downloaded DMG read-only, verify the app, shortcut, architecture, signature and checksums. |
| First launch | Explain when the running copy is outside Applications; resume the access step after quitting/reopening; keep an explicit local-scan action. | Portable tests cover installed/downloaded/read-only/translocated locations and interrupted/completed setup. Native smoke checks cover all setup steps in light/dark appearances. |
| Purchase and permissions | Explain the same-account activation path in setup and next to the account download; keep scanning/recovery accessible; show Settings links and the exact running copy. | Existing account lifecycle and permission tests remain green. No account, consent or paid access is granted by an installer. |
| Release | Sign/notarize/staple the app and DMG before consumer publication; document verification and publish only validated feed records. | Consumer builds fail without credentials; ad-hoc packages remain developer previews. No Gatekeeper bypass instructions. |

Repository signing secrets were absent when this work began. Apple Developer ID credentials and an actual quarantined consumer download/permission walkthrough remain release prerequisites. CI builds and smoke checks are not a substitute for that final Gatekeeper and interactive permission check. Pricing and consumer release publication are outside this change; the existing paid-access semantics remain unchanged.

## Implemented interfaces

- `FirstRunSetup.swift`: advisory path classification and persisted setup progress, covered by portable tests.
- `InstallationGuide.swift`: current-copy instructions in the welcome step and permission settings.
- `OnboardingView.swift`: restart resume, same-account connection, stable footer and page reset; completion is handed back to the presenter so scanning starts after dismissal.
- `build_app.sh`, `build_dmg.sh`, `notarize.sh`, `verify_installer.sh`: architecture, signing, acceptance, disk-image and isolated-copy checks.
- `InstallationSteps.tsx`: account-download instructions tailored to DMG versus ZIP, including same-account activation and optional permissions.

Notarization failure tests use synthetic tools and credentials; they never contact Apple. Browser download tests use intercepted fixture accounts and do not charge a card. Native interactive permission grants and an actual Developer ID consumer download still require the final release walkthrough.

## Validation record — 2026-10-19

Implementation `2c6013c` passed [native CI](https://github.com/QuntmTech/mac-mint/actions/runs/39204402387) and [backend/website CI](https://github.com/QuntmTech/mac-mint/actions/runs/39204402359). Later documentation commits do not change the tested implementation.

- macOS 15 and 26: 251 test cases, zero failures and one expected skip in the opt-in-volume run; packaging repeats add the expected volume-fixture skip. Each build rendered 123 interface states. Representative light/dark setup and installation captures were inspected.
- Both native builds passed ordinary startup, menu-bar off/on, the live Performance scene, idle CPU/physical-footprint limits and graceful Quit. Fresh runners verified the downloaded ZIP and DMG, app signatures, checksums, Applications shortcut and isolated copy, then passed downloaded-package startup. The macOS 15 app contains verified arm64 and x86_64 slices; this does not substitute for Intel hardware acceptance.
- Local portable suite: 181 tests passed. Setup persistence/location regressions and four notarization failure checks passed. Shell syntax, workflow lint, SwiftUI syntax, website lint, TypeScript and production builds passed.
- All 39 browser tests passed in CI. A local parallel run had one five-second example-scan timeout; the isolated rerun passed without changing its deadline. Both new DMG/ZIP instruction cases passed locally.
- The tested website build was deployed. Read-only checks passed seven desktop account/recovery routes and phone navigation/layout without JavaScript errors, missing assets or mutating requests.

The first native packaging run found an incorrect argument order in the architecture verifier. Both calls were fixed before the successful final run. Repository signing secrets were rechecked and remained absent. No consumer tag, public feed record or pricing configuration was published by this work.
