# In-app updates

MacMint updates itself with [Sparkle 2](https://sparkle-project.org) (2.10.0, pinned in `Package.swift`). Open **Settings → Updates** or choose **MacMint → Check for Updates…**, click **Install Update**, then **Install and Relaunch**. Sparkle downloads the archive, verifies it, replaces the app and reopens it. If MacMint finds an update on its daily background check while you are working, it shows a banner instead of interrupting. **Install…** in the banner opens the same Sparkle window.

With **Automatically download and install updates** on, Sparkle downloads in the background and installs the update the next time MacMint quits.

## Channels

| Channel | Feed | Contains | Published by |
|---|---|---|---|
| Stable (default) | `https://github.com/QuntmTech/mac-mint/releases/latest/download/appcast.xml` | The newest Developer ID-signed, notarized `v*` release | `release.yml`, only when the build is Developer ID-signed and notarized |
| Developer | `https://github.com/QuntmTech/mac-mint/releases/download/dev-feed/appcast-dev.xml` | The 10 newest builds of `main` | `macos.yml`, after the macOS CI passes on a push to `main` |

- **Build numbers.** `scripts/build_app.sh` writes these values into the bundle's copied Info.plist: `CFBundleVersion` = `git rev-list --count HEAD`, `CFBundleShortVersionString` from `VERSION`, and `MacMintGitCommit` = the full SHA. Sparkle compares `CFBundleVersion`, so each commit on `main` has a higher number than the one before it. Settings shows `Version 0.9.0 (build N · abc1234)`. Builds need complete git history: the CI checkouts use `fetch-depth: 0`, and the script refuses to build from a shallow clone.
- **Developer builds.** For each push to `main` whose macOS build, startup, smoke and downloaded-package checks pass, the workflow creates the GitHub pre-release `dev-build-N` with the macOS 15 universal `MacMint.zip`. It signs that zip with Sparkle's `sign_update` and verifies the signature against `SUPublicEDKey` (see below). It then uploads `appcast-dev.xml` to the fixed `dev-feed` pre-release. Each item lists the commit subjects since the previous developer build as plain text. Releases and tags older than the newest 10 `dev-build-*` are deleted. The publishing job is the only job with `contents: write`, and it runs no repository code. Pull requests and forks never reach either job.
- **Stable.** When a `v*` tag builds with the complete Developer ID and notarization secrets, the approved `release` job signs `MacMint.zip` and writes `appcast.xml` (one item). The publish job attaches the file to the GitHub release. `releases/latest` resolves to the newest release that is not a pre-release. Ad-hoc tag builds stay pre-releases without an appcast, and the log says why. **No stable appcast exists yet.** Stable users see "up to date" or a feed error until the first notarized release.
- **Switching.** Sparkle never downgrades. If you turn developer builds off, you keep your current build until a stable release has a higher build number. Turning them on checks the developer feed right away.

### Developer builds on the owner's Mac

1. Settings → Updates → turn on **Receive developer builds (may be unstable)**. The choice is stored as `co.macmint.updates.channel` (`stable` by default, or `developer`).
2. Click **Check for Updates…**.

## First install

Copies installed before this change have no updater, so install MacMint once the old way:

1. Download `MacMint.zip` from the newest **MacMint developer build N** pre-release on GitHub (or from the `MacMint-macos-15-<sha>` artifact of a CI run).
2. Quit MacMint, unzip, and replace `/Applications/MacMint.app` with the new copy. History and exclusions are stored outside the app.
3. Open it. Developer builds are ad-hoc signed and not notarized, so macOS asks once: choose **Open** in Finder's context menu, or **Open Anyway** in System Settings → Privacy & Security.

After that, every update takes one click from Settings, the banner or the menu. Run MacMint from `/Applications`. A copy opened from Downloads or a disk image is translocated and cannot replace itself.

## What protects an update

- **EdDSA (Ed25519).** Every archive is signed with the private key. The app holds the public key in `SUPublicEDKey` (Info.plist). Before installing, Sparkle verifies the signature over the downloaded bytes with the key from the *installed* copy. A changed archive, or one signed by any other key, is rejected.
- **Allowlist.** `UpdaterController` reads only the two feeds above. It refuses any item whose download is not a `github.com/QuntmTech/mac-mint/releases/download/<tag>/<file>` asset (`ReleaseChecker.trustedUpdateURL`). Feeds may also use `releases/latest/download/<file>`. The appcast script applies the same rule to every item it writes.
- **Code signature.** Sparkle checks that the new bundle's code signature is valid. With Developer ID signing it also requires the installer's connections to come from the same Team ID.
- **No system profile** (`SUEnableSystemProfiling` = NO). Checks run every 24 hours (`SUScheduledCheckInterval` = 86400) and are on by default (`SUEnableAutomaticChecks` = YES), so no permission prompt appears.
- **Work in progress.** If Install and Relaunch is chosen while MacMint is moving, restoring or organizing files, `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` holds the relaunch. The banner and Settings say the update will finish afterwards. The install continues when the operation ends. If a new operation starts in the moment between that and the quit, MacMint waits for it and then quits for the installer. The usual "Quit while MacMint is working?" question is not asked a second time.
- **Server gate kept.** `UpdateService` still reads the PocketBase release record and `app_config.client.min_version`. It checks at launch and after each Sparkle cycle; its own 24-hour timer is gone. When the server reports a newer or required version, MacMint asks Sparkle quietly (`checkForUpdateInformation`). If Sparkle has the update, the banner's button installs it. Otherwise the banner keeps the download-page fallback.

## Ad-hoc developer builds: verified in Sparkle's source

Ad-hoc signatures have a different designated requirement (a cdhash) in every build, so the code-signing match can never succeed between two developer builds. The Sparkle 2.10.0 source (`eef1a53`) was read to confirm that such updates are still accepted:

- `Sparkle/SUUpdateValidator.m`, `validateUpdateForHost:`. A bundle update is accepted when *either* the EdDSA signature verifies with the old app's public key *or* the code signature matches the old app's designated requirement ("We allow failure of one of them"). For ad-hoc → ad-hoc, EdDSA passes and the code-signing match fails, which is allowed. The only other requirement is `SUCodeSigningVerifier codeSignatureIsValidAtBundleURL:`, a validity check with no requirement, and a correctly ad-hoc-signed bundle passes it. The basic policy also rejects removing the public key or the code signature. Neither applies here.
- `Autoupdate/SUCodeSigningVerifier.m`, `validateConnection:`. Installer connections need a Team ID requirement only when the installer has a Team ID. Ad-hoc code has none, so the connection is allowed.
- Quarantine. MacMint is not sandboxed, has no `LSFileQuarantineEnabled`, and sets no `SUEnableDownloaderService`. Sparkle therefore downloads in-process with `NSURLSession`, and macOS adds no `com.apple.quarantine` attribute. Sparkle also clears quarantine on the new bundle anyway (`SUPlainInstaller`, `releaseItemFromQuarantineAtRootURL:`) and on its copied `Updater.app` (`SUInstallerLauncher`).

**Outcome:** ad-hoc → ad-hoc updates are accepted on EdDSA alone. The fallback (a self-signed "MacMint Developer" certificate in `DEV_SIGNING_P12`) is not needed and was not created. Developer builds therefore trust only the EdDSA key: protect it as the release key. CI cannot click through an interactive update, so the owner's test below is the end-to-end proof.

## Bundle layout and signing

`build_app.sh` copies `Sparkle.framework` from the SwiftPM artifact into `Contents/Frameworks`. It also checks `Package.resolved` for the pinned Sparkle revision and adds the `@executable_path/../Frameworks` runtime path. Sparkle's XPC services are deleted: Sparkle needs them only for sandboxed apps, and MacMint enables none of the `SUEnable*Service` keys. Signing goes inside-out with one identity: `Autoupdate`, `Updater.app`, `Sparkle.framework`, then the app. The default is ad-hoc. With `SIGN_IDENTITY` set, each item gets the hardened runtime and a secure timestamp, and only the app gets the entitlements. `codesign --verify --deep --strict` must pass. The smoke test also checks that Sparkle loads from `Contents/Frameworks`, that the XPC services are absent, that the public key and both feeds are valid, and that the build is stamped.

## Keys

- **Private key:** `/home/qrkit/.secrets/macmint-sparkle-ed25519.key` (mode 600) on the build host. It holds the base64 32-byte Ed25519 seed, the format of Sparkle's `generate_keys -x` and `sign_update --ed-key-file`. Keep an offline copy in a password manager. It must never be committed, printed or pasted into an issue.
- **CI:** the repository secret `SPARKLE_ED_PRIVATE_KEY` (`gh secret set SPARKLE_ED_PRIVATE_KEY < <key file>`). It is a repository secret because the developer feed on `main` and the branch dry run both need it. Anyone who can push a workflow to this repository can read it. Once the dry run is no longer needed, consider moving it into an environment limited to `main` and `v*`, with that environment added to the `developer-appcast` job. Protecting `main` (docs/RELEASING.md) matters for the same reason.
- **Public key:** `SUPublicEDKey` in `Resources/Info.plist` (`26Xmi1lVmgcxuH8fISWtnjnoam3w+bYQhJ/9X40k5Zw=`).
- **Planned rotation:** generate a new key and put the new public key in Info.plist. Keep signing with the **old** secret until the copies in use have installed a build that carries the new key, then replace the secret. Sparkle checks an archive against the installed copy's key, so this transition build is accepted. Copies that skip it can only follow by reinstalling. With Developer ID-signed stable releases, Sparkle also accepts a new key when the code signature matches the installed copy.
- **If the key leaks:** rotate as above as soon as possible and treat the leak as an incident. The leaked key can sign updates that copies holding the old key will install. Developer builds have no code-signing backstop.

## What Developer ID changes for stable users

Once the `DEVELOPER_ID_*` and Apple notarization secrets are in the `release` environment (docs/RELEASING.md), tag builds are signed, notarized, stapled and published as full releases with `appcast.xml`. Stable users then get:

- Gatekeeper-approved downloads with no first-launch override.
- Two independent update checks. EdDSA, plus the code signature must keep the same Team ID. That makes key rotation through code signing possible.
- Installer connections restricted to that Team ID.
- Ad-hoc developer installs that switch to stable accept the signed release, because the EdDSA key matches. From then on they are Developer ID-signed.

## Testing

- `node --test tests/sparkle_appcast.test.mjs` covers appcast generation, numeric build ordering, de-duplication, the keep limit, plain-text escaping of commit subjects, the URL allowlist, and Ed25519 verification (tampered archive, wrong key, version or length mismatch). It runs in the backend CI.
- `swift test` covers channel persistence, feed and URL allowlists and build info in Core (Linux and macOS). On macOS it also covers the relaunch gate and the channel and postpone logic of `UpdaterController` (`UpdaterTests`).
- `macos.yml` checks the stamped version and commit, the Sparkle link, absent XPC services, deep signature verification, the smoke render (including update banner states) and the normal-startup gate with Sparkle embedded.
- **Dry run:** `gh workflow run macos.yml --ref <branch>` builds everything, signs and verifies `appcast-dev.xml`, and uploads the `developer-feed-<sha>` artifact without publishing.

### Owner end-to-end test

1. With developer builds on, install build N (see First install) and confirm Settings shows `Version 0.9.0 (build N · …)`.
2. Merge any change to `main` and wait for the macOS workflow's **Publish developer build** job.
3. In MacMint, click **Check for Updates…**. The window should offer build N+k (k = commits merged). Click **Install Update**, then **Install and Relaunch**.
4. MacMint should relaunch, with Settings showing build N+k.
5. Optional: start a cleanup, then choose Install and Relaunch. The banner should say the update waits. The relaunch should happen right after the cleanup, without the quit question.

## Limitations

- No stable appcast until the first Developer ID-signed, notarized release. Developer builds are not notarized.
- Updates are full archives (no deltas). The appcast itself is not signed (`SURequireSignedFeed` is off); the archive signature is what Sparkle trusts.
- A run that finishes out of order never moves `appcast-dev.xml` backwards, but the feed can then miss an older item. Only the newest item matters for updating.
- Updating needs write access to the app's folder. For `/Applications`, Sparkle asks for an administrator password if needed.
