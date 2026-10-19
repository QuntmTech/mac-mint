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

Every macOS CI run executes the 148 portable core tests and seven native integration tests. The native tests move only their own temporary fixtures through the actual macOS Trash and check receipt identity, name collisions, History commits, no-overwrite restore, alternate destinations and dangling symlinks. Account lifecycle tests use an isolated token store and clock. No test empties Trash or uses a real account.

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
