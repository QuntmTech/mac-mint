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

If the secrets already exist at repository level, recreate them in the environment and delete the repository copies.

All signing and notarization secrets must be present to publish a consumer release. Without the complete set the workflow produces an explicitly marked ad-hoc prerelease. Both paths run package smoke rendering; only the consumer path can enter the public app feed.

## Cutting a release

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist` and `VERSION`.
2. Merge the validated implementation to `main`, then tag the version in `VERSION`: `git tag "v$(cat VERSION)" && git push origin "v$(cat VERSION)"`.
3. Approve the `release` deployment when the **Release** workflow asks. It checks that the tagged commit is on `main`, builds, signs, notarizes and staples in the approved job, then a separate job (the only one with a write token) publishes a GitHub release with `MacMint.zip` and its SHA-256. Workflows otherwise run with a read-only token, and actions are pinned to commit SHAs that Dependabot updates.
4. Publish it to the app's update feed — create an `app_releases` record in PocketBase (`macmint` project):
   `version`, `build`, `channel=stable`, `min_os=14.0`, `download_url` (the GitHub release asset URL, `https://github.com/QuntmTech/mac-mint/releases/download/<tag>/MacMint.zip`; the feed only accepts that form or an `https://macmint.co/` URL, and the app opens nothing else), `sha256`, `size_bytes`, `notes`, `validated=true`, `notarized=true`, `published=true`, `published_at=now`. Record these attestations only after testing the downloaded artifact, quarantine/Gatekeeper installation, local scanning, cleanup and restore on a disposable Mac. The feed rules reject unvalidated artifacts.
   Installed apps see the update within a day (or immediately via Settings → Check Now); the website's account page shows the download.
5. To force older versions to update, raise `min_version` in the `app_config` record with key `client`.

## Verifying a build locally

Every macOS CI run executes the 148 portable core tests and seven native integration tests. The native tests move only their own temporary fixtures through the actual macOS Trash and check receipt identity, name collisions, History commits, no-overwrite restore, alternate destinations and dangling symlinks. Account lifecycle tests use an isolated token store and clock. No test empties Trash or uses a real account.

CI also downloads the uploaded ZIP on a fresh runner, checks its SHA-256, extracts it, verifies its signature and launches its smoke tests. An ad-hoc artifact passing this check is still not a notarized consumer installation. Test the actual Developer ID-signed download with quarantine and Gatekeeper before publishing feed attestations.

```bash
NO_OPEN=1 ./scripts/build_app.sh            # ad-hoc
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=macmint ./scripts/build_app.sh
spctl --assess --type execute --verbose=2 dist/MacMint.app
```

## Deploy checklist (backend hooks and migrations)

Nothing in the repository deploys itself. For each backend rollout:

1. **Back up production PocketBase** (data directory snapshot or the built-in backup) and confirm the backup restores on staging.
2. **Apply migrations in order on staging first**, restored from that backup with the new hooks: `1792108800` baseline through `1792109400`, any `1792109500_*` licensing migrations, then `1792109600_rate_limits`, `1792109610_order_reversals` and `1792109620_ai_limits`. Check `migrate history`. Down migrations deliberately keep payment, refund and accounting evidence.
3. **Set the trusted proxy header.** Rate limits key on the client IP. Behind the CloudPod reverse proxy, PocketBase otherwise sees the proxy's address for everyone, and a per-client limit becomes one global limit. Confirm which header the proxy sets *and overwrites* from the real client (for example `X-Real-IP` or `X-Forwarded-For`; never one a client can supply unchanged), then set Settings → Application → Trusted proxy → headers to it, leaving "use leftmost IP" off. Verify in the request logs that the user IP is your own address, not the proxy's.
4. **Enable and verify rate limits with a non-production client.** `1792109600` installs the rules and enables them only if trusted proxy headers were already configured; otherwise it logs `rate limit rules installed but not enabled` and you enable them in Settings → Rate limits after step 3. From one machine, send 11 bogus `/api/macmint/redeem` requests to staging and expect HTTP 429 on the 11th; from a second network expect no 429; confirm Stripe webhook deliveries are unaffected.
5. **Register the refund and dispute events** (`charge.refunded`, `charge.dispute.created`, `charge.dispute.updated`) on the Stripe webhook endpoint and grant the restricted key Charges and Disputes read access (see [STRIPE_SETUP.md](STRIPE_SETUP.md)). In the sandbox, refund a test purchase and check that the account's entitlement becomes inactive.
6. **Check AI limits.** After `1792109620`, the public `ai` record holds only `enabled` and `features`; budgets and model overrides are in the private `ai_limits` record (`daily_token_budget`, `daily_usd_budget`, `user_daily_usd_cap` (default 1.50), `models`). Allow at least 95 seconds of proxy read time for `/api/macmint/ai/review` and `/api/macmint/ai/organize`, which now wait up to 90 seconds for the provider. Desktop builds currently give up on those requests after 45 seconds, so raise the client timeouts before relying on the longer server limit.
7. **Then production**, in the same order, after a fresh backup. Confirm `GET /api/crons` (superuser) lists `macmint_ai_stale_reservations` (hourly; flags, never frees) and `macmint_retention` (daily; site events older than 180 days, failed-redeem audit rows older than 90 days).
