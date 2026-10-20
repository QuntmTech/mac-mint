# Startup and permission setup

MacMint opens its workspace without starting a scan. First launch presents three setup steps: local inspection and recovery, optional access guidance, and optional helpers. **Set Up Later**, **Open Workspace**, and Escape do not scan. **Run Quick Scan** starts the scan explicitly. Settings → Permissions & setup → Review Setup reopens the guide without resetting exclusions, History or account data.

## Access at the point of use

| Access | When it is needed | What MacMint provides |
| --- | --- | --- |
| Files & Folders | A chosen scan reaches a protected folder | macOS's normal prompt with purpose text; Settings shortcut and written navigation path |
| Full Disk Access | Optional broader coverage of protected app data | Enable/add-current-app instructions, Reveal This App, and a Settings shortcut |
| Photos | An explicit Photos-library scan | Explanation before the native request; denied/restricted guidance and a folder-photo alternative |
| Notifications | Enabling a low-space alert or scan reminder | Native request for undetermined access, current status, and Settings recovery after denial |
| App Management | macOS requires access while changing another app | Written Privacy & Security → App Management guidance; independent from Full Disk Access |
| Login Items | Enabling Open MacMint at login | Explicit registration and approval-required guidance using the public System Settings opener |

Opening Settings does not grant permission. A macOS version may ignore a pane anchor; the guide always includes the written path, and failed links fall back to opening System Settings. App Management deliberately opens the general Privacy & Security page rather than relying on an undocumented pane anchor. After changing access, return and rescan when ready; quit/reopen if macOS asks.

There is no supported generic Full Disk Access status query. MacMint no longer tests access by listing another app's container or Safari directory, and never labels the switch enabled from such a probe. Read-only Photos and notification status refreshes do not request new access. See [Apple DTS's Full Disk Access discussion](https://developer.apple.com/forums/thread/114452), [App Management guidance](https://support.apple.com/en-au/guide/mac-help/mchl211c911f/mac), and the public [Login Items settings API](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems()).

The current features do not need Accessibility, Screen Recording, Input Monitoring, camera, microphone or a privileged helper. Purpose strings describe the file/folder, app-data, app-bundle and Photos operations actually performed. Obsolete Finder-automation wording was removed; MacMint's Trash action opens Finder for review.

Settings, Help, and scan-issue details provide access guidance. Photos distinguishes undetermined, authorized, limited, denied and restricted states. Granting access never selects files or executes removal. Notifications remain optional; failed or denied scheduling does not consume the reminder cooldown. Permission requests are tied to explicit actions rather than launch or foreground polling.

## Startup freeze fix

The user's installation handoff reported a frozen normal window and nearly one CPU core in use on Apple Silicon/macOS 26.5, despite passing unit and isolated-view rendering tests. The local diagnosis isolated a feedback loop around `MenuBarExtra(isInserted: $showMenuBar)` and its `@AppStorage` binding. The handoff reported that an idempotent setter restored responsiveness with the menu bar both off and on; its final release replacement/walkthrough was still pending.

The source now uses that setter: an unchanged insertion state is not republished. Menu-bar state changes still persist, and the full scene remains present. Temporary diagnostic changes from the other Mac were not imported. Source delivery does not replace the locally installed app or establish that its pending installation steps finished.

The main canvas, panels and selected rows also use neutral grays/white in light mode and charcoal in dark mode. Green is retained as a small accent/action color, rather than a full workspace tint.

## Verification

Keep both native gates:

```sh
NO_OPEN=1 ./scripts/build_app.sh
./scripts/smoke_test.sh dist/MacMint.app
./scripts/native_startup_test.sh dist/MacMint.app
```

The rendering smoke path intentionally bypasses normal scene creation. The new external startup probe launches the ordinary packaged app with menu-bar insertion off and on. It checks launch completion, normal-window metadata, idle CPU after settling (under 2% of a core), and bounded graceful Quit. In the build job, `MACMINT_RESOURCE_SCENARIOS=1` adds the resource budgets described in `docs/PERFORMANCE_UX.md`. It does not use Accessibility or screen pixels. It refuses an already-running MacMint and cleans up only the exact new process bearing its random probe marker. Preference overrides are process arguments; the probe does not reset settings, account data, exclusions or History. Run it on a disposable graphical Mac test environment, as CI does.

CI tests both macOS 15 and macOS 26, including archive checksum/signature, downloaded-bundle rendering and ordinary startup. These tests target the reported launch failure; they do not establish daily-use battery performance or exercise permission dialogs. Interactive checks remain necessary: actual System Settings destinations, grant/deny/restricted Photos, limited library coverage, folder denial, returning after access changes, notification denial/re-enable, Login Items approval, keyboard navigation and VoiceOver. The user's installed release and macOS 26.5 walkthrough remain separate verification.

The macOS 26 offscreen `cacheDisplay` artifacts currently show the system-composited sidebar as blank white, including in dark appearance. The same source renders sidebar controls in macOS 15 artifacts. Layout geometry remains checked, but those macOS 26 images do not establish that the sidebar painted correctly in a normal window. Inspect the ordinary app interactively on macOS 26; do not treat a successful render count as visual certification. The app requests neither Screen Recording nor Accessibility access for these checks.

## Installation and interrupted setup

The welcome step and Settings permission card now identify installed, downloaded, read-only-volume, translocated and development copies. This is installation advice, not a Full Disk Access detector. Open Applications / Show This Copy are explicit Finder actions; the app does not copy itself, replace an older app, elevate privileges or remove quarantine. Install/open the intended copy before granting access.

Setup stores its current step under `setup.currentStep`. Quitting during the access step resumes there on first-run restart; finishing or choosing Set Up Later keeps the existing `care.onboardingDone` key compatible and clears the saved step. Reviewing completed setup starts at Welcome. Each page opens at its top. The final step offers optional same-account purchase connection without making sign-in mandatory. Escape closes the account sheet back to setup.

The setup completion callback starts the same Quick Scan as the dashboard, after the setup sheet has dismissed. Skipping or closing the guide does not start a scan. Photos/notifications remain requested only by explicit feature actions, and helpers preserve their existing opt-in preferences.
