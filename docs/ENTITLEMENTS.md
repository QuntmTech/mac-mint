# Signed offline entitlements

MacMint unlocks paid features without the server only with an **entitlement assertion** the server signed with Ed25519 for one account and one Mac. The app verifies it with public keys compiled into the binary. Nothing the app writes to disk is trusted on its own: the old `account.json` cache (plain JSON bound to a hash of a token the user already holds) is ignored and deleted.

Online behavior is unchanged: a successful `/api/macmint/me` still unlocks, including from a server that predates assertions, but that access lasts for the running app only.

## Wire format

`/api/macmint/me?device_id=…`, `/api/macmint/devices/activate` and `/api/macmint/redeem` (with `device_id` in the body) add `entitlement_assertion` when the named Mac is an active device of an active plan and a signing key is configured. The field is additive; nothing else in the responses changed.

```
base64url(canonical JSON payload) "." base64url(64-byte Ed25519 signature over the payload bytes)

{"active":true,"device_id":"…","expires_at":null,"issued_at":1800000000,"kid":"mm-ent-2026-10",
 "offline_until":1801209600,"plan":"pro","user_id":"…","v":1}
```

Times are integer Unix seconds. `offline_until = issued_at + offline_grace_days`, capped by `expires_at`. `offline_grace_days` comes from the public `app_config` record `client` (`{"offline_grace_days": 14}`; default 14, clamped to 0–60).

Server: [`macmint_entitlement.js`](../backend/pocketbase/pb_hooks/macmint_entitlement.js) with vendored [tweetnacl-js 1.0.3](../backend/pocketbase/pb_hooks/macmint_nacl.js) (verbatim; npm integrity and file hash in its header and re-checked by `backend/tests/entitlements.test.cjs`). App: [`EntitlementAssertion.swift`](../Sources/MacCleanerCore/EntitlementAssertion.swift) (claims and policy, portable) and [`AccountEntitlementVerifier.swift`](../Sources/MacCleanerApp/AccountEntitlementVerifier.swift) (CryptoKit).

## What the app accepts

- Online: the assertion, when present, must verify (signature, known `kid`, `v` 1, user, this Mac, active). A failure is treated as a failed check. No assertion means a legacy server: unlock this run only.
- Offline or after a restart: a verified assertion from the Keychain with `now < offline_until`, before `expires_at`, and `now` no earlier than five minutes before the latest time this Mac has seen (the high-water mark, kept in the same Keychain item and never earlier than `issued_at`). Every verified online assertion re-anchors the mark to its server `issued_at`, so a Mac whose clock ran ahead isn't locked out once the clock is corrected; later checks advance it again.
- Quiet foreground checks (at most every 15 minutes while access is valid and online; every activation while offline) keep valid access through 404/408/425/429/5xx, TLS and verification failures. A quiet network failure switches to offline, so the signed `offline_until` window, not the running app's last online check, decides from then on. An expired session (401) or a definitive answer (no active plan, this Mac removed) removes access. Launch and explicit retries fall back to valid offline evidence for transient failures, never for TLS or verification failures. Cancellation changes nothing about the account; an interrupted launch or retry settles on valid offline evidence or a Try Again panel.

## Device activation

Explicit actions on this Mac — sign-in, Redeem, Check Purchase, freeing a slot from the device-limit panel, and "Activate this Mac" — send `reactivate: true`; the server still enforces the device limit. Background paths (launch, foreground refresh, periodic recheck) never do. When verification finds this Mac without an active device row they call activate with `reactivate: false`: a Mac that never had a row is registered, and one removed from the account gets `409 device_deactivated` and shows "Activate this Mac".

## Keys

| | Where |
| --- | --- |
| Private signing seed | `MACMINT_ENTITLEMENT_SIGNING_KEY` env var, or the superuser-only `app_secrets` record `entitlement_signing_key` (same lookup order as `anthropic_api_key`). Value: `<kid>:<base64 32-byte Ed25519 seed>`. The production seed for `mm-ent-2026-10` was generated on 2026-10-17 and is held by the operator in a private env file outside the repository. Never commit it, paste it into a ticket, or reuse it in tests. |
| Public keys | `CryptoKitEntitlementVerifier.productionKeys` in the app, a `kid → base64 raw key` list. |

Without a usable key the server omits assertions and logs `macmint: no entitlement signing key configured` once per process. Online access keeps working; offline access fails closed.

Check that a configured seed matches the app before deploying (prints only the public key):

```sh
node -e 'const c=require("crypto");const[k,s]=process.env.MACMINT_ENTITLEMENT_SIGNING_KEY.split(":");const p=c.createPrivateKey({key:Buffer.concat([Buffer.from("302e020100300506032b657004220420","hex"),Buffer.from(s,"base64")]),format:"der",type:"pkcs8"});console.log(k,c.createPublicKey(p).export({format:"der",type:"spki"}).subarray(-32).toString("base64"))'
```

### Rotation

1. Generate a new pair with a **new** `kid` (never reuse a `kid` for a different seed) (`crypto.generateKeyPairSync('ed25519')`, raw 32-byte seed and public key).
2. Add the public key to `productionKeys` and ship that app release. Keep the old `kid`.
3. When enough installs have the release, switch the server value to the new `kid:seed`. Apps without the new `kid` cannot verify its assertions, so their explicit checks fail (quiet checks keep existing access); do not switch early.
4. Remove the old `kid` from the app only after its last assertions have passed `offline_until` (at most the grace period after the switch).

There is no revocation list. A leaked seed lets anyone forge offline access for any account until the app stops trusting its `kid`; rotate immediately and ship a release without it.

## Deploying (operator steps)

Nothing here was deployed by the change itself. Staging first, then production:

1. Deploy `macmint.pb.js`, `macmint_entitlement.js` and `macmint_nacl.js` together. No migration is required.
2. Put the seed into `app_secrets` as `entitlement_signing_key` (superuser dashboard or API), or set the environment variable and restart the service. Use a separate staging key unless staging must accept production apps.
3. Optionally set `offline_grace_days` in the `client` config record.
4. Verify: `GET /api/macmint/me?device_id=<an active device>` returns `entitlement_assertion`; its payload names that device; the signature verifies with the public key above; a removed device gets none.
5. Then release the app.

**Order matters.** The app is safe to ship before the backend (online unlock still works), but until the backend signs assertions an app restart without network access stays locked rather than using the forgeable cache. Deploy and verify the backend first.

## Performance

Pure-JS Ed25519 is slow under Goja. Measured with the real PocketBase 0.40.5 integration suite on a loaded 12-core host: the first signature in a process including key derivation took about 3–5 s, later signatures with the cached key about 1.2–1.7 s, a reused assertion about 10 ms, and `/me` without an assertion about 25 ms. The derived key is cached per process, and an assertion is reused for the same user, device, plan, expiry, key and grace for up to 12 hours, so a Mac normally costs at most a couple of signatures a day. An authenticated user who churns device activations can still force signatures; enable PocketBase rate limits for `/api/macmint/devices/*`, and move signing to native code if load grows.

## Residual risks

- **Binary patching or a debugger** can skip any client-side check. Code signing and notarization prove origin, not integrity at runtime.
- **Local TLS interception**: someone who installs their own root CA and rewrites `/me` can fake an online "active" answer (or strip the assertion), because unsigned online answers are still accepted for compatibility. That access lasts for the running app only. A later release can require assertions online once every production server signs.
- **Clock and Keychain games**: restoring an older copy of the Keychain item and winding the clock back can reuse an assertion's window, but never before its `issued_at`. Doing so repeatedly means keeping the Mac's clock wrong and the server unreachable. Conversely, a Mac whose clock runs more than five minutes behind the server cannot use offline access until its clock is corrected (online access is unaffected).
- **Device cloning**: the device ID is a random UUID in user defaults, not a hardware identifier. Copying it and the Keychain item to another Mac copies offline access for at most one window.
- **Offline user binding is only as strong as the Keychain item.** On restart, the stored record's own `userId` is what the assertion is checked against. Someone who can edit the Keychain item could swap in another account's captured assertion that names this device ID. That is no worse than sharing credentials, and it is bounded by that assertion's `offline_until` (14 days or less).
- **Key rotation edges.** (a) Assertion reuse in `issue()` is keyed by `kid`, not by the seed. If the seed changes but the `kid` stays the same, assertions signed with the old seed can still be served for up to 12 h, and apps trusting that `kid` would reject the new ones. Always change the `kid` when rotating. (b) An app that doesn't know a new `kid` rejects those assertions, so an explicit activation or check fails with `invalid_assertion`. This is intentional: ship the new public key in an app release before the server signs with it.
- **Server key exposure** and **server CPU** as described above.
