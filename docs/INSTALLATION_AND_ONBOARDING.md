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
