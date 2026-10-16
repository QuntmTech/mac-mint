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

Without these secrets the release workflow still runs, producing an ad-hoc signed build (fine for testing, blocked by Gatekeeper for customers).

## Cutting a release

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Resources/Info.plist` and `VERSION`.
2. Merge to `main`, then tag: `git tag v0.6.0 && git push origin v0.6.0`.
3. The **Release** workflow builds, signs, notarizes, staples, and publishes a GitHub release with `MacMint.zip` and its SHA-256.
4. Publish it to the app's update feed — create an `app_releases` record in PocketBase (`macmint` project):
   `version`, `build`, `channel=stable`, `min_os=14.0`, `download_url` (the GitHub release asset URL), `sha256`, `size_bytes`, `notes`, `published=true`, `published_at=now`.
   Installed apps see the update within a day (or immediately via Settings → Check Now); the website's account page shows the download.
5. To force older versions to update, raise `min_version` in the `app_config` record with key `client`.

## Verifying a build locally

```bash
NO_OPEN=1 ./scripts/build_app.sh            # ad-hoc
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=macmint ./scripts/build_app.sh
spctl --assess --type execute --verbose=2 dist/MacMint.app
```
