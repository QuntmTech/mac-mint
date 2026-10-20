# Releasing MacMint

## One-time setup (needs the Apple Developer account)

Create the `release` environment first (Settings → Environments → New environment):

- **Required reviewers**: the owner (and optionally a second maintainer). Every tag build waits for this approval before any signing secret is exposed.
- **Deployment branches and tags**: *Selected branches and tags*, add the tag rule `v*`.
- Protect `main` (require a pull request and passing checks). The release job refuses tags whose commit is not on `main`, which only helps if `main` itself cannot be pushed to directly.
- Add a tag ruleset (Settings → Rules → Rulesets, target tags `v*`) that restricts creation, update and deletion of release tags to the owner. This is required: the release checks run from the tagged commit's own workflow file, so anyone who could push an arbitrary `v*` tag could remove them, leaving the environment approval as the only gate.

Add these as **environment secrets of `release`** (Settings → Environments → release → Environment secrets), not repository secrets. Repository secrets are available to any workflow run, so they would bypass the approval:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | base64 of the exported "Developer ID Application" certificate + key (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | password used when exporting the .p12 |
| `DEVELOPER_ID_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID1234)` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com |

`SPARKLE_ED_PRIVATE_KEY` (the Sparkle update-signing key, see [UPDATES.md](UPDATES.md#keys)) is already set as a **repository** secret, because the developer feed on `main` also uses it. The release job can read it too.

If the secrets already exist at repository level, recreate them in the environment and delete the repository copies.

All signing and notarization secrets must be present to publish a consumer release. Without the complete set the workflow produces an explicitly marked ad-hoc prerelease. Both paths run package smoke rendering; only the consumer path can enter the public app feed.

## Cutting a release

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist` and `VERSION`; `build_app.sh` refuses to build when they differ. Do not edit `CFBundleVersion`: the script stamps the commit count of HEAD into the bundle, and Sparkle compares that number.
2. Merge the validated implementation to `main`, then tag the version in `VERSION`: `git tag "v$(cat VERSION)" && git push origin "v$(cat VERSION)"`.
3. Approve the `release` deployment when the **Release** workflow asks. It checks that the tagged commit is on `main`, then builds, signs, notarizes and staples in the approved job. A separate job, the only one with a write token, verifies the digests and publishes a GitHub release with `MacMint.dmg`, the compatibility `MacMint.zip`, and their separate SHA-256 files. Workflows otherwise run with a read-only token, and actions are pinned to commit SHAs that Dependabot updates.
   For a Developer ID-signed, notarized build, the approved job also signs `MacMint.zip` with the Sparkle key and writes `appcast.xml`. It verifies the signature against the bundle's `SUPublicEDKey` and `CFBundleVersion`, and the release carries the file. Installed copies on the stable channel find it at `releases/latest/download/appcast.xml` and update in one click ([UPDATES.md](UPDATES.md)). An ad-hoc tag build gets no appcast: it stays a pre-release and the log says it was skipped.
4. Publish it to the app's update feed — create an `app_releases` record in PocketBase (`macmint` project):
   `version`, `build`, `channel=stable`, `min_os=14.0`, `download_url` (the GitHub release asset URL of the DMG, `https://github.com/QuntmTech/mac-mint/releases/download/<tag>/MacMint.dmg`; the feed only accepts that form or an `https://macmint.co/` URL, and the app opens nothing else), `sha256`, `size_bytes`, `notes`, `validated=true`, `notarized=true`, `published=true`, `published_at=now`. Record these attestations only after testing the downloaded artifact, quarantine/Gatekeeper installation, local scanning, cleanup and restore on a disposable Mac. The feed rules reject unvalidated artifacts.
   The website's account page shows the download. Installed apps update through Sparkle; this record still drives the in-app banner's fallback download and the minimum-version gate.
5. To force older versions to update, raise `min_version` in the `app_config` record with key `client`.

## Developer builds

Every push to `main` that passes the macOS workflow publishes the pre-release `dev-build-N` and updates `appcast-dev.xml` on the `dev-feed` pre-release. The workflow keeps the newest 10 builds. Copies that opted into developer builds install them from Settings → Updates. Nothing needs to be tagged, and no tags or releases should be created by hand. To check the signing and appcast steps from a branch without publishing, run `gh workflow run macos.yml --ref <branch>` and inspect the `developer-feed-<sha>` artifact.

## Verifying a build locally

Every macOS CI run executes the portable core suite and native integration tests. The native tests move only their own temporary fixtures through the actual macOS Trash and check receipt identity, name collisions, History commits, no-overwrite restore, alternate destinations and dangling symlinks. Account lifecycle tests use an isolated token store and clock. No test empties Trash or uses a real account.

CI also downloads the uploaded ZIP on a fresh runner, checks its SHA-256, extracts it, verifies its signature and launches its smoke tests. An ad-hoc artifact passing this check is still not a notarized consumer installation. Test the actual Developer ID-signed download with quarantine and Gatekeeper before publishing feed attestations.

```bash
NO_OPEN=1 ./scripts/build_app.sh            # ad-hoc
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=macmint ./scripts/build_app.sh
spctl --assess --type execute --verbose=2 dist/MacMint.app
```

## Drag-to-Applications installer

`build_app.sh` now produces `MacMint.dmg` plus its SHA-256 alongside the ZIP. The DMG contains MacMint.app, an Applications shortcut and three-step installation/account instructions. It uses built-in macOS tools and does not require Finder automation permission. Local builds use the current architecture; release builds set `MACMINT_ARCHS="arm64 x86_64"` and verify both slices. The macOS 15 CI package also builds both architectures.

Consumer packaging notarizes/staples the app first, recreates its compatibility ZIP, then signs/notarizes/staples the disk image. The notary helper requires an explicit `Accepted` response; a zero tool exit status alone is not approval. An unsigned/not-notarized build is marked **MacMint Preview** and cannot be represented as a consumer release. No quarantine removal, Gatekeeper bypass or automatic installation is offered.

```sh
NO_OPEN=1 MACMINT_ARCHS="arm64 x86_64" \
  REQUIRE_NOTARIZATION=1 SIGN_IDENTITY="Developer ID Application: …" \
  NOTARY_PROFILE=macmint ./scripts/build_app.sh
EXPECTED_ARCHS="arm64 x86_64" REQUIRE_NOTARIZATION=1 \
  ./scripts/verify_installer.sh dist/MacMint.dmg
```

The verifier mounts read-only, checks checksum/signature/bundle identity/architectures, checks the Applications shortcut, and verifies an isolated copy. It never writes into the real Applications folder or grants access. The downloaded-package CI job verifies the uploaded DMG again on a fresh runner. Feed `download_url`, `sha256` and `size_bytes` must all describe the **same DMG**, rather than mixing the DMG URL with the ZIP checksum. Retain the ZIP as an alternative archive.

Before public feed publication, download the signed DMG through a browser on a disposable Mac. Verify Gatekeeper/quarantine, copying/replacing an older app, ejecting the image, first launch, first local scan, denial/re-enabling permissions, access-step resume after a requested restart, same-account purchase activation, a reviewed cleanup and Restore. Check macOS 14 compatibility and both Intel/Apple Silicon hardware before claiming those journeys were tested. CI ad-hoc artifacts do not meet this release gate.

## Deploy checklist (backend hooks and migrations)

Nothing in the repository deploys itself. For each backend rollout:

1. **Back up production PocketBase** (data directory snapshot or the built-in backup) and confirm the backup restores on staging.
2. **Apply migrations in order on staging first**, restored from that backup with the new hooks: `1792108800` baseline through `1792109400`, `1792109500_subscriptions`, then `1792109600_rate_limits`, `1792109610_order_reversals` (also adds subscription hold fields to `billing_subscriptions`, created by `1792109500_subscriptions`) and `1792109620_ai_limits`. Check `migrate history`. Down migrations deliberately keep payment, refund and accounting evidence.
3. **Set the trusted proxy header.** Rate limits key on the client IP. Behind the CloudPod reverse proxy, PocketBase otherwise sees the proxy's address for everyone, and a per-client limit becomes one global limit. Confirm which header the proxy sets *and overwrites* from the real client (for example `X-Real-IP` or `X-Forwarded-For`; never one a client can supply unchanged), then set Settings → Application → Trusted proxy → headers to it, leaving "use leftmost IP" off. Verify in the request logs that the user IP is your own address, not the proxy's.
4. **Enable and verify rate limits with a non-production client.** `1792109600` installs the rules and enables them only if trusted proxy headers were already configured; otherwise it logs `rate limit rules installed but not enabled` and you enable them in Settings → Rate limits after step 3. From one machine, send 11 bogus `/api/macmint/redeem` requests to staging and expect HTTP 429 on the 11th; from a second network expect no 429; confirm Stripe webhook deliveries are unaffected.
5. **Register the refund and dispute events** (`charge.refunded`, `charge.dispute.created`, `charge.dispute.updated`) on the Stripe webhook endpoint and grant the restricted key Charges, Disputes and Invoices (including invoice payments) read access (see [STRIPE_SETUP.md](STRIPE_SETUP.md)). In the sandbox, refund a one-time purchase and a subscription invoice and check that the account's entitlement becomes inactive, and that a later renewal does not restore the held subscription until `POST /api/macmint/admin/billing/release-hold`.
6. **Check AI limits.** After `1792109620`, the public `ai` record holds only `enabled` and `features`; budgets and model overrides are in the private `ai_limits` record (`daily_token_budget`, `daily_usd_budget`, `user_daily_usd_cap` (default 1.50), `models`). Allow at least 95 seconds of proxy read time for `/api/macmint/ai/review` and `/api/macmint/ai/organize`, which now wait up to 90 seconds for the provider. Desktop builds wait 100 seconds for these two requests.
7. **Then production**, in the same order, after a fresh backup. Confirm `GET /api/crons` (superuser) lists `macmint_ai_stale_reservations` (hourly; flags, never frees) and `macmint_retention` (daily; site events older than 180 days, failed-redeem audit rows older than 90 days).

## Installing a test build on a Mac in about a minute

CI already builds, tests and packages every push on macOS 15 and 26, so a test Mac never needs to compile. With the GitHub CLI signed in (`brew install gh && gh auth login`):

```bash
./scripts/install_dev_build.sh                # latest green build of main
./scripts/install_dev_build.sh my-branch      # latest green build of a branch
./scripts/install_dev_build.sh --pr 42        # a pull request's branch
./scripts/install_dev_build.sh --rollback     # put the previous copy back
```

The script picks the newest successful `macOS build` run, downloads the universal `macos-15` artifact (it runs on macOS 14 or later), checks its SHA-256 against CI's checksum and verifies the code signature. It then quits MacMint gracefully (it never force-quits), backs up the current app and `~/Library/Application Support/MacMint` to `~/MacMint-backups/<time>/` (it keeps the newest five), installs to `/Applications`, and relaunches. Artifacts expire after 14 days. The `install-script` CI job exercises install, reinstall and rollback on a disposable runner for every push.
