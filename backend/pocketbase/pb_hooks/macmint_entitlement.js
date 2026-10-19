/// <reference path="../pb_data/types.d.ts" />
// Signed entitlement assertions for offline access (not a hook file itself).
//
// The app may unlock without the server only with an Ed25519 assertion it can verify against a
// public key compiled into the app. The payload is canonical JSON (sorted keys, no whitespace,
// integer Unix seconds); the wire form is base64url(payload) + "." + base64url(signature).
//
// The private key is a 32-byte Ed25519 seed written as "<kid>:<base64 seed>" in the
// MACMINT_ENTITLEMENT_SIGNING_KEY environment variable or, on hosts where the service can't be
// restarted with new env, the superuser-only app_secrets record "entitlement_signing_key". It is
// never logged or returned. Without a usable key no assertion is issued: online access still
// works, offline access fails closed. See docs/ENTITLEMENTS.md.
//
// Pure-JS Ed25519 is slow under Goja (seconds, not milliseconds, per scalar multiplication), so
// the derived signing key is kept for the process and an assertion is reused for the same
// user/device/entitlement binding for up to REUSE_SECONDS. A reused assertion's offline window is
// at most that much shorter; any change to plan, status, expiry, key or grace re-signs.

const VERSION = 1
const DEFAULT_OFFLINE_GRACE_DAYS = 14
const MAX_OFFLINE_GRACE_DAYS = 60
const KEY_ID = /^[A-Za-z0-9._-]{1,64}$/
const DEVICE_ID = /^[A-Za-z0-9-]{16,64}$/
const REUSE_SECONDS = 12 * 3600
const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function nacl() {
  // nacl-fast.js probes self.crypto first and otherwise require("crypto"), which Goja lacks
  // ("Invalid module"). A temporary self.crypto keeps it on the browser branch. Ed25519 signing
  // is deterministic and never draws randomness; anything that would gets "no PRNG".
  const g = globalThis
  const shim = typeof g.self === "undefined"
  if (shim) g.self = { crypto: { getRandomValues: function () { throw new Error("no PRNG") } } }
  try {
    return require(`${__hooks}/macmint_nacl.js`)
  } finally {
    if (shim) delete g.self
  }
}

function canonicalJSON(value) {
  if (value === null) return "null"
  if (typeof value === "boolean") return value ? "true" : "false"
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new Error("canonical JSON allows only safe integers")
    return String(value)
  }
  if (typeof value === "string") return JSON.stringify(value)
  if (Array.isArray(value)) return "[" + value.map(canonicalJSON).join(",") + "]"
  if (typeof value === "object") {
    return "{" + Object.keys(value).sort().map((k) => JSON.stringify(k) + ":" + canonicalJSON(value[k])).join(",") + "}"
  }
  throw new Error("unsupported canonical JSON value")
}

function utf8(text) {
  const out = []
  for (let i = 0; i < text.length; i++) {
    let c = text.charCodeAt(i)
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
      const d = text.charCodeAt(i + 1)
      if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++ }
    }
    if (c < 0x80) out.push(c)
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63))
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63))
  }
  return new Uint8Array(out)
}

function base64url(bytes) {
  let out = ""
  for (let i = 0; i < bytes.length; i += 3) {
    const n = (bytes[i] << 16) | ((bytes[i + 1] || 0) << 8) | (bytes[i + 2] || 0)
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63]
    if (i + 1 < bytes.length) out += B64[(n >> 6) & 63]
    if (i + 2 < bytes.length) out += B64[n & 63]
  }
  return out.replace(/\+/g, "-").replace(/\//g, "_")
}

// Accepts standard or URL-safe base64, with or without padding. Returns null when malformed.
function decodeBase64(text) {
  const clean = String(text || "").trim().replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "")
  if (!/^[A-Za-z0-9+/]*$/.test(clean) || clean.length % 4 === 1) return null
  const out = []
  let buffer = 0, bits = 0
  for (let i = 0; i < clean.length; i++) {
    buffer = (buffer << 6) | B64.indexOf(clean[i])
    bits += 6
    if (bits >= 8) { bits -= 8; out.push((buffer >> bits) & 255) }
  }
  return new Uint8Array(out)
}

function parseSigningKey(value) {
  const text = String(value || "").trim()
  const split = text.indexOf(":")
  if (split <= 0) return null
  const kid = text.slice(0, split), seed = decodeBase64(text.slice(split + 1))
  if (!KEY_ID.test(kid) || !seed || seed.length !== 32) return null
  return { kid: kid, seed: seed }
}

function warnOnce(app, key, message) {
  try {
    const store = app.store()
    if (store.has(key)) return
    store.set(key, true)
  } catch (err) { /* no shared store: log every time rather than never */ }
  console.log(message)
}

function configuredKey(app) {
  let raw = $os.getenv("MACMINT_ENTITLEMENT_SIGNING_KEY")
  if (!raw) {
    try {
      raw = String(app.findFirstRecordByFilter("app_secrets", "name = 'entitlement_signing_key'").get("value") || "")
    } catch (err) {
      raw = ""
    }
  }
  if (!raw) {
    warnOnce(app, "macmint.entitlement.no_key", "macmint: no entitlement signing key configured; offline assertions are not issued")
    return null
  }
  const key = parseSigningKey(raw)
  if (!key) warnOnce(app, "macmint.entitlement.bad_key", "macmint: entitlement signing key is malformed (expected <kid>:<base64 32-byte seed); offline assertions are not issued")
  return key
}

function jsonField(value) {
  if (value && typeof value === "object" && !Array.isArray(value) && value.constructor === Object) return value
  try { return JSON.parse(toString(value)) } catch (err) { return null }
}

function offlineGraceDays(app) {
  let cfg = null
  try { cfg = jsonField(app.findFirstRecordByFilter("app_config", "key = 'client'").get("value")) } catch (err) { cfg = null }
  const days = cfg && cfg.offline_grace_days
  if (typeof days !== "number" || !isFinite(days)) return DEFAULT_OFFLINE_GRACE_DAYS
  return Math.min(MAX_OFFLINE_GRACE_DAYS, Math.max(0, Math.floor(days)))
}

function seconds(iso) {
  if (iso === null || iso === undefined || iso === "") return null
  const ms = Date.parse(String(iso))
  return isNaN(ms) ? null : Math.floor(ms / 1000)
}

// What offline evidence may vouch for. `entitlement` is the effective (license + subscription)
// answer, already capped by the paid-through or trial end. A subscription with payment trouble
// may keep online access while Stripe retries, but gets no fresh offline assertion; only a
// one-time license that is active on its own still signs. Unreadable billing state fails closed.
function offlineBasis(app, userId, entitlement) {
  if (!entitlement || entitlement.active !== true) return null
  let troubled
  try {
    troubled = app.findRecordsByFilter("billing_subscriptions",
      "user = {:u} && terminal = false && (status = 'past_due' || status = 'unpaid')", "", 1, 0, { u: userId }) || []
  } catch (err) {
    return null
  }
  if (!troubled.length) return entitlement
  let record
  try { record = app.findFirstRecordByFilter("plan_entitlements", "user = {:u}", { u: userId }) } catch (err) { return null }
  const license = require(`${__hooks}/macmint_lib.js`).entitlementPayload(record)
  return license.active ? license : null
}

// entitlement is entitlementPayload() output; expires_at is ISO 8601 or null.
function assertionPayload(kid, userId, deviceId, entitlement, issuedAt, graceDays) {
  const expiresAt = seconds(entitlement.expires_at)
  let offlineUntil = issuedAt + graceDays * 86400
  if (expiresAt !== null) offlineUntil = Math.min(offlineUntil, expiresAt)
  return {
    v: VERSION,
    kid: kid,
    user_id: String(userId),
    device_id: String(deviceId),
    plan: String(entitlement.plan),
    active: entitlement.active === true,
    expires_at: expiresAt,
    issued_at: issuedAt,
    offline_until: offlineUntil
  }
}

// secretKey is the 64-byte tweetnacl form (seed || public key).
function signWithSecretKey(payload, secretKey) {
  const message = utf8(canonicalJSON(payload))
  return base64url(message) + "." + base64url(nacl().sign.detached(message, secretKey))
}

function sign(payload, seed) {
  return signWithSecretKey(payload, nacl().sign.keyPair.fromSeed(seed).secretKey)
}

function shared(app) {
  try { return app.store() } catch (err) { return null }
}

function secretKey(app, key) {
  const store = shared(app), id = "macmint.entitlement.secret"
  const source = key.kid + ":" + base64url(key.seed)
  const cached = store && store.get(id)
  if (cached && cached.source === source) {
    const bytes = decodeBase64(cached.secret)
    if (bytes && bytes.length === 64) return bytes
  }
  const derived = nacl().sign.keyPair.fromSeed(key.seed).secretKey
  if (store) store.set(id, { source: source, secret: base64url(derived) })
  return derived
}

// Returns the compact assertion, or null when this device isn't active for an active plan, the
// plan's billing is in trouble, or no signing key is configured. `devices` is the account's
// active (non-deactivated) device list.
function issue(app, userId, deviceId, effective, devices) {
  const id = String(deviceId || "")
  if (!userId || !DEVICE_ID.test(id) || !effective || effective.active !== true) return null
  if (!(devices || []).some((d) => d.device_id === id)) return null
  const entitlement = offlineBasis(app, userId, effective)
  if (!entitlement) return null
  const key = configuredKey(app)
  if (!key) return null
  try {
    const now = Math.floor(Date.now() / 1000), grace = offlineGraceDays(app)
    const binding = canonicalJSON({ grace: grace, payload: assertionPayload(key.kid, userId, id, entitlement, 0, grace) })
    const store = shared(app), slot = "macmint.entitlement.assertion." + userId + "." + id
    const previous = store && store.get(slot)
    if (previous && previous.binding === binding && previous.issued <= now && now - previous.issued < REUSE_SECONDS) {
      return previous.value
    }
    const value = signWithSecretKey(assertionPayload(key.kid, userId, id, entitlement, now, grace), secretKey(app, key))
    if (store) store.set(slot, { binding: binding, issued: now, value: value })
    return value
  } catch (err) {
    warnOnce(app, "macmint.entitlement.sign_failed", "macmint: entitlement assertion signing failed; offline assertions are not issued")
    return null
  }
}

// Adds `entitlement_assertion` to a mePayload() result when one can be issued. Additive only.
function attach(app, payload, deviceId) {
  const assertion = issue(app, payload.user.id, deviceId, payload.entitlement, payload.devices)
  if (assertion) payload.entitlement_assertion = assertion
  return payload
}

module.exports = {
  VERSION: VERSION,
  DEFAULT_OFFLINE_GRACE_DAYS: DEFAULT_OFFLINE_GRACE_DAYS,
  REUSE_SECONDS: REUSE_SECONDS,
  canonicalJSON: canonicalJSON,
  utf8: utf8,
  base64url: base64url,
  decodeBase64: decodeBase64,
  parseSigningKey: parseSigningKey,
  offlineGraceDays: offlineGraceDays,
  offlineBasis: offlineBasis,
  assertionPayload: assertionPayload,
  sign: sign,
  issue: issue,
  attach: attach
}
