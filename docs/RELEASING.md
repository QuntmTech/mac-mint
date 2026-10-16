# Releasing MacMint

## One-time setup (needs the Apple Developer account)

Add these repository secrets (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | base64 of the exported "Developer ID Application" certificate + key (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | password used when exporting the .p12 |
| `DEVELOPER_ID_IDENTITY` | e.g. `Developer ID Application: Your Name (TEAMID1234)` |
| `APPLE_ID` | Apple ID email used for notarization |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_APP_PASSWORD` | app-specific password from appleid.apple.com |

All signing and notarization secrets must be present to publish a consumer release. Without the complete set the workflow produces an explicitly marked ad-hoc prerelease. Both paths run package smoke rendering; only the consumer path can enter the public app feed.

## Cutting a release

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist` and `VERSION`.
2. Merge the validated implementation to `main`, then tag the version in `VERSION`: `git tag "v$(cat VERSION)" && git push origin "v$(cat VERSION)"`.
3. The **Release** workflow builds, signs, notarizes, staples, and publishes a GitHub release with `MacMint.zip` and its SHA-256.
4. Publish it to the app's update feed — create an `app_releases` record in PocketBase (`macmint` project):
   `version`, `build`, `channel=stable`, `min_os=14.0`, `download_url` (the GitHub release asset URL), `sha256`, `size_bytes`, `notes`, `validated=true`, `notarized=true`, `published=true`, `published_at=now`. Record these attestations only after testing the downloaded artifact, quarantine/Gatekeeper installation, local scanning, cleanup and restore on a disposable Mac. The feed rules reject unvalidated artifacts.
   Installed apps see the update within a day (or immediately via Settings → Check Now); the website's account page shows the download.
5. To force older versions to update, raise `min_version` in the `app_config` record with key `client`.

## Verifying a build locally

Every macOS CI run executes the 146 portable core tests and seven native integration tests. The native tests move only their own temporary fixtures through the actual macOS Trash and check receipt identity, name collisions, History commits, no-overwrite restore, alternate destinations and dangling symlinks. Account lifecycle tests use an isolated token store and clock. No test empties Trash or uses a real account.

CI also downloads the uploaded ZIP on a fresh runner, checks its SHA-256, extracts it, verifies its signature and launches its smoke tests. An ad-hoc artifact passing this check is still not a notarized consumer installation. Test the actual Developer ID-signed download with quarantine and Gatekeeper before publishing feed attestations.

```bash
NO_OPEN=1 ./scripts/build_app.sh            # ad-hoc
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=macmint ./scripts/build_app.sh
spctl --assess --type execute --verbose=2 dist/MacMint.app
```
