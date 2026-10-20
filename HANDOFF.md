# MacMint — start here for independent review

Updated 2026-10-19. This is the entry point for Claude Code or another reviewer. Start with [installation and first-run setup](docs/INSTALLATION_AND_ONBOARDING.md), then the [earlier six-phase delivery checklist](docs/UNINSTALL_AND_TAMING.md) and [PR #33](https://github.com/QuntmTech/mac-mint/pull/33). The complete earlier change history and architecture are in [docs/CLAUDE_CODE_HANDOFF.md](docs/CLAUDE_CODE_HANDOFF.md).

## Free-trial checkout funnel — 2026-10-20

Every homepage call-to-action now opens `/start`, a plan page for MacMint Pro, Annual (7-day free trial; 1/2/5 Macs at US$39.95/59.95/99.95 per year, from server configuration). "Start free trial" goes to the tier's Stripe Payment Link; the signed webhook records a private purchase claim; `/welcome` creates the account once (or links an existing account for that email) and `/download` serves the validated DMG. This supersedes the earlier US$39.99/three-day/three-Mac offer. Read the funnel section and go-live checklist in [Stripe setup](docs/STRIPE_SETUP.md), `macmint_funnel.js`, `macmint_download.js` and `backend/tests/funnel_integration.py`. Nothing was configured in Stripe or deployed.

## Latest public-readiness and recurring billing extension — 2026-10-19

Start with [public-readiness review](docs/PUBLIC_READINESS_REVIEW.md) and [Stripe setup](docs/STRIPE_SETUP.md) for this pass (paths are under `docs/` from the repository root). The owner approved **US$39.99/year with a three-day free trial**; the existing three-Mac allowance is retained. Checkout remains disabled until the intended Stripe business account, sandbox lifecycle, email delivery, deployment and signed consumer download pass acceptance.

Recurring access now lives in private `billing_subscriptions`, independently of redeemed/one-time licenses. Read `macmint_billing.js`, the subscription migration and disposable subscription integration fixture. Review authoritative ownership, trial-only expiry, first-charge/renewal failures, absolute invoice periods, concurrent sync generations, terminal-state latching, portal cancellation and one-trial eligibility. `BillingCard` and `Checkout` expose these terms and owner-bound management without granting access from browser returns. Old one-time orders remain compatible. No live Stripe account setup or charge is claimed.

Additional fixes reject malformed expiry as unlimited access, bind delayed AI availability/request continuations to their session, populate library screenshots from PhotoKit metadata, and block overlapping photo mutation. Source review also covers planner/executor/recovery, uninstaller, organization, process controls, preview caches, onboarding/permissions and release boundaries. The review document records the scope and remaining native/provider evidence; it is not a zero-bug or complete-public-launch certification.

## Goal and current progress

Review a native Mac storage/cleanup app for everyday owners and developers, with particular attention to data safety, recovery, privacy, account boundaries, native usability and CPU/RAM use. The user requested an independent set of eyes on the implementation and subsequent refinements.

Review current `origin/main`; historical SHAs and counts below are checkpoints. The installation extension at `2c6013c` adds a universal-capable DMG pipeline, downloaded-image verification, current-copy installation guidance, restart-resumable setup, consistent Quick Scan dispatch after dismissal and same-account purchase instructions. Its [native checks](https://github.com/QuntmTech/mac-mint/actions/runs/39204402387) and [backend/website checks](https://github.com/QuntmTech/mac-mint/actions/runs/39204402359) identify the implementation head and final results. Documentation commits may follow. Apple signing credentials were absent; consumer publication and the actual quarantined installation/permission walkthrough remain open release gates.

The earlier six-phase extension adds clearer app uninstall, timed manual slowdown, opt-in Auto Tame with saved exceptions and recovery intents, bulk photo selection, review-deck preview fixes, bounded image caches and native memory measurements. It retains the earlier safety/recovery work, local inspection before sign-in, optional AI, preview-first organization, Stripe readiness, permission guidance and neutral themes. That checklist distinguishes automated evidence from the actual user's iCloud-library and memory-profile checks.

## Get the repository

Repository: **https://github.com/QuntmTech/mac-mint**.

For a fresh review checkout on a Mac, run the following in Terminal. If the destination already exists, inspect it first or choose another new directory; do not overwrite it.

```bash
mkdir -p "$HOME/Developer"
cd "$HOME/Developer"
git clone https://github.com/QuntmTech/mac-mint.git mac-mint-review
cd mac-mint-review
git status --short --branch
git log -8 --oneline --decorate
```

If authentication is required, use the user's existing GitHub credential flow. Do not request tokens in the transcript. In an existing checkout, inspect `git status` before pulling or switching; preserve local/uncommitted installation fixes. `git fetch origin` can update remote references without modifying that working tree. For an isolated review from it:

```bash
git fetch origin
git worktree add --detach ../mac-mint-independent-review origin/main
cd ../mac-mint-independent-review
```

The shared Linux source path is `/home/qrkit/src/mac-mint`. `/home/qrkit/macmint.co` is a deployed website directory, **not** the source repository. The user's older Mac installation checkout had local fixes; do not assume its path, HEAD or installed bundle is current.

## How the app works

| Flow | Main boundary and behavior |
| --- | --- |
| Launch and navigation | SwiftUI `MacCleanerApp` creates the models/scenes. `RootView` provides seven primary workspaces, contextual tabs, Review, Settings and Help. Replayable onboarding explains optional access; scans start explicitly. |
| Local inspection | Portable scanners feed `AppViewModel` findings, coverage and selections. Inspection, exclusions and local recovery remain available without an active paid account. |
| Reviewed cleanup | Shared selections become an `OperationPlanner` plan. The coordinator checks paid mutation access; the executor revalidates identity, keepers, exclusions and owners before moving supported items to Trash. Durable journals remain until History commits. |
| Recovery | `HistoryStore`, `RecoveryService` and `RestoreCoordinator` reconcile interrupted work and restore supported receipts without overwriting conflicts. Uncertain moves stay uncertain. |
| Photos | Folder files use filesystem review/Trash. Photo-library assets use PhotoKit confirmation and Recently Deleted. Deck swipes change selections; they do not immediately delete. |
| AI and Organizer | Desktop requests go to authenticated PocketBase routes; the Anthropic key stays server-side. Explain/Review/Ask are advisory. Organizer previews proposed names/moves, then requires approval and local policy checks; it has its own durable Undo records. |
| Account and purchase | `AccountStore` manages session/entitlement/offline grace. Hosted Stripe Checkout is fulfilled through verified, idempotent server handling; a browser return URL grants no access. Live pricing/setup is pending. |
| Performance | A utility sampler uses visible-consumer leases and adaptive cadence. Main-process Quit/Force Quit and reversible background priority recheck identity/owner. Opt-in Auto Tame reuses sampling; exceptions persist and restoration is journaled. Hard CPU/RAM caps, GPU data and grouped helper totals remain unimplemented. |

Source map: `Sources/MacCleanerCore` for portable policy/engines; `Sources/MacCleanerApp` for native UI/adapters/coordinators; `backend/pocketbase/pb_hooks` and `pb_migrations` for PocketBase/Goja; `web` for Vite/React account/checkout; `ChatGPT sites the homepage V1` for the separate homepage/demo. Read section 15 of the detailed handoff for exact review files and tests.

## Verification and build

The previous delivery's [main native CI](https://github.com/QuntmTech/mac-mint/actions/runs/39065968758) and [backend/web CI](https://github.com/QuntmTech/mac-mint/actions/runs/39065968760) passed (220 tests, 113 rendered states). [PR #33 checks](https://github.com/QuntmTech/mac-mint/pull/33/checks) contain the latest expanded native suite, 119 rendered states, disposable-app priority test, 2,000-image memory gate and packaged RAM/CPU measurements, including an active Performance scene. Check the final head SHA and conclusions; the old counts are historical and repeated packaging runs are not additional unique coverage.

On macOS 14+ with a Swift 6/Xcode toolchain:

```bash
swift test
NO_OPEN=1 ./scripts/build_app.sh
MACMINT_SCREENSHOT_DIR="$PWD/.build/interface-previews" ./scripts/smoke_test.sh dist/MacMint.app
```

The generated local app is `dist/MacMint.app`; this does not replace the user's installed Test.app. For normal scene checks, read `docs/PERMISSIONS_AND_STARTUP.md` and use `./scripts/native_startup_test.sh dist/MacMint.app` on a disposable graphical Mac with no existing MacMint instance. Linux syntax parsing cannot establish native compilation. Section 14 of the full handoff has backend, web and benchmark commands.

## What worked and what failed

- Shared planner/executor policy, durable intents and idempotent history preserve removal/recovery authority across modules. AI proposes; local rules decide what can be applied.
- Session/scan generations prevent delayed results from reviving old state. Photo review progress survives navigation; cancellations forward to supported thumbnail APIs.
- An idempotent MenuBarExtra/AppStorage setter fixed the startup feedback loop reported by the user's installation chat. Normal-scene tests now supplement isolated view renders.
- Explicit `@Sendable` notification and launch callbacks corrected older-SDK actor-isolation traps caught in native CI.
- Passing unit tests and isolated renders had missed the real startup freeze. Do not repeat the assumption that those alone prove a responsive installed app.
- Probing another app's protected directories was not a reliable Full Disk Access status query; that probe was removed.
- The first Performance viewport assertion counted the sidebar inset twice. It was corrected without reducing the three/five visible-row requirement.
- macOS 26 `cacheDisplay` images omit the system-composited glass sidebar. The normal-window sidebar still needs visual/interactive inspection; a green render count does not establish its pixels.
- Stripe connector attempts failed despite reconnection. No real account/sandbox, Price or live payment was configured through that connector. Recheck availability before operational setup.

## Review priorities and next steps

1. Read the full handoff and compare the original baseline `05ecb65417f2d0a7a3c16748a2abd39284c7cf91` with current `origin/main`. Use the subsystem file map; distinguish historical checkpoints from the current status.
2. Challenge keeper preservation, exclusions/aliases/mounted volumes, journal-to-History durability, uncertain outcomes, restore conflicts, and Organizer Apply/Undo recovery with meaningful fault injection.
3. Challenge stale account/AI callbacks, consent preview/request equality, redaction and transactional usage/payment accounting. Inspect serialized requests using synthetic adversarial names; do not send personal data or incur live provider charges as a substitute for fixture tests.
4. On a Mac, test ordinary startup, menu-bar toggling, light/dark/System appearance, actual permission grant/deny/re-enable flows, keyboard/VoiceOver, the macOS 26 sidebar, and normal/force quit using disposable apps. Profile sustained CPU/RAM with Instruments; short idle samples are not a battery guarantee.
5. Before paid launch, complete pricing and intended Stripe account setup, staging payment/webhook/activation journeys, external email delivery, authenticated AI staging/canary, and Developer ID signing/notarization/Gatekeeper/update-feed validation. Source commits and existing keys do not prove these gates are complete.
6. Return findings by severity with file/line, trigger, consequence, evidence, proposed correction and a meaningful verification method. Separate confirmed defects, hypotheses, untested paths and feature requests. Review first; preserve existing work and avoid unrelated rewrites or production changes.

Keep the user's decisions: useful scanning before sign-in; recovery after expiry/sign-out; optional AI; explicit preview/approval for organization; Stripe only; neutral workspace backgrounds; opt-in reversible Auto Tame with never-slow exceptions. Do not claim hard CPU/RAM caps, automatic memory reclamation, complete helper-process coverage or unsupported external-volume mutation. Do not put credentials into code, logs or this handoff.
