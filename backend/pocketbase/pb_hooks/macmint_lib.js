/// <reference path="../pb_data/types.d.ts" />
// Shared helpers for macmint.pb.js. Not a hook file itself (no .pb.js suffix);
// PocketBase route handlers run in isolated contexts, so each one require()s this.

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
const CODE_PREFIX = "MINT"
const DEFAULT_MAX_DEVICES = 3

function body(e) {
  try {
    const info = e.requestInfo()
    return info && info.body ? info.body : {}
  } catch (err) {
    return {}
  }
}

function noStore(e) {
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
}

function parseDate(value) {
  const s = String(value || "").trim()
  if (!s) return null
  const d = new Date(s.replace(" ", "T"))
  return isNaN(d.getTime()) ? null : d
}

function normalizeCode(value) {
  return String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "")
}

function formatCode(normalized) {
  return String(normalized).match(/.{1,4}/g).join("-")
}

function generateCode() {
  return CODE_PREFIX + $security.randomStringWithAlphabet(16, CODE_ALPHABET)
}

function clean(value, max) {
  return String(value || "").replace(/[\u0000-\u001f\u007f]/g, "").trim().slice(0, max)
}

function logEvent(app, event, userId, detail) {
  try {
    const r = new Record(app.findCollectionByNameOrId("audit_log"))
    r.set("event", event)
    if (userId) r.set("user", userId)
    r.set("detail", detail || {})
    app.save(r)
  } catch (err) { /* audit is best-effort */ }
}

function findEntitlement(app, userId) {
  try {
    return app.findFirstRecordByFilter("plan_entitlements", "user = {:u}", { u: userId })
  } catch (err) {
    return null
  }
}

function ensureEntitlement(app, userId) {
  const existing = findEntitlement(app, userId)
  if (existing) return existing
  const r = new Record(app.findCollectionByNameOrId("plan_entitlements"))
  r.set("user", userId)
  r.set("plan", "free")
  r.set("status", "active")
  r.set("source", "signup")
  r.set("max_devices", 0)
  app.save(r)
  return r
}

function entitlementPayload(r) {
  const plan = String(r.get("plan") || "free")
  let status = String(r.get("status") || "active")
  const exp = parseDate(r.get("expires_at"))
  const invalidExpiry = Boolean(String(r.get("expires_at") || "").trim()) && exp === null
  const lapsed = exp !== null && exp.getTime() <= Date.now()
  if (plan === "pro" && status === "active" && (lapsed || invalidExpiry)) status = "expired"
  return {
    plan: plan,
    status: status,
    active: plan === "pro" && status === "active",
    expires_at: exp ? exp.toISOString() : null,
    max_devices: Number(r.get("max_devices") || 0),
    source: String(r.get("source") || "")
  }
}

// Never overwrite a redeemed/lifetime license when a subscription renews or ends.
function effectiveEntitlement(app, userId, record) {
  const base = entitlementPayload(record || ensureEntitlement(app, userId))
  if (base.status === "revoked" || base.status === "suspended") return base
  const recurring = require(`${__hooks}/macmint_billing.js`).access(app, userId)
  if (!recurring) return base
  if (!base.active) return recurring
  return { ...base, expires_at: base.expires_at === null ? null :
    new Date(Math.max(Date.parse(base.expires_at), Date.parse(recurring.expires_at))).toISOString(),
    max_devices: Math.max(base.max_devices, recurring.max_devices) }
}

// Applies a redeemed license to an entitlement record (caller saves it).
// Time-limited codes extend from the later of now or the current expiry.
function applyLicense(ent, lic) {
  const plan = String(lic.get("plan"))
  const days = Number(lic.get("duration_days") || 0)
  const current = entitlementPayload(ent)
  if (plan === "lifetime" || days <= 0) {
    ent.set("expires_at", "")
  } else if (!(current.active && current.expires_at === null)) {
    const base = current.active && current.expires_at ? new Date(current.expires_at).getTime() : Date.now()
    ent.set("expires_at", new Date(Math.max(base, Date.now()) + days * 86400000).toISOString())
  }
  const licDevices = Number(lic.get("max_devices") || DEFAULT_MAX_DEVICES)
  ent.set("max_devices", Math.max(Number(ent.get("max_devices") || 0), licDevices))
  ent.set("plan", "pro")
  ent.set("status", "active")
  ent.set("source", String(lic.get("source")) === "demo" ? "demo" : "license")
  ent.set("license", lic.id)
}

function devices(app, userId) {
  // A failed count must not be interpreted as zero occupied slots.
  return app.findRecordsByFilter("devices", "user = {:u} && deactivated = false", "-last_seen", 200, 0, { u: userId }) || []
}

// Count, reactivation decision, and write share one transaction so concurrent Macs cannot
// both consume the last slot. Deactivated rows remain as tombstones for old clients.
function activateDevice(app, user, data) {
  let payload
  app.runInTransaction((tx) => {
    const ent = effectiveEntitlement(tx, user.id)
    if (!ent.active) throw { status: 402, error: "no_active_plan", message: "An active MacMint plan is required." }
    let device
    try { device = tx.findFirstRecordByFilter("devices", "user = {:u} && device_id = {:d}", { u: user.id, d: data.device_id }) } catch (_) {}
    if (device && device.get("deactivated") && data.reactivate !== true) {
      throw { status: 409, error: "device_deactivated", message: "This Mac was removed from your account. Sign in again to activate it explicitly." }
    }
    if (!device || device.get("deactivated")) {
      const existing = devices(tx, user.id), limit = ent.max_devices > 0 ? ent.max_devices : DEFAULT_MAX_DEVICES
      if (existing.length >= limit) throw { status: 409, error: "device_limit", message: "Remove another Mac from your account before activating this one.", limit, devices: existing.map(devicePayload) }
    }
    if (!device) {
      device = new Record(tx.findCollectionByNameOrId("devices"))
      device.set("user", user.id); device.set("device_id", data.device_id)
    }
    device.set("deactivated", false)
    device.set("name", clean(data.name, 200) || "Mac")
    device.set("model", clean(data.model, 100)); device.set("os_version", clean(data.os_version, 40))
    device.set("app_version", clean(data.app_version, 40)); device.set("last_seen", new Date().toISOString())
    tx.save(device)
    logEvent(tx, "device_activated", user.id, { device_id: data.device_id })
    payload = devicePayload(device)
  })
  return payload
}

function devicePayload(d) {
  return {
    id: d.id,
    device_id: String(d.get("device_id") || ""),
    name: String(d.get("name") || "Mac"),
    model: String(d.get("model") || ""),
    os_version: String(d.get("os_version") || ""),
    app_version: String(d.get("app_version") || ""),
    last_seen: String(d.get("last_seen") || "")
  }
}

function mePayload(app, user) {
  const ent = ensureEntitlement(app, user.id)
  return {
    user: {
      id: user.id,
      email: String(user.get("email") || ""),
      name: String(user.get("name") || ""),
      verified: Boolean(user.get("verified"))
    },
    entitlement: effectiveEntitlement(app, user.id, ent),
    billing: require(`${__hooks}/macmint_billing.js`).summary(app, user.id),
    devices: devices(app, user.id).map(devicePayload),
    server_time: new Date().toISOString()
  }
}

module.exports = {
  activateDevice: activateDevice,
  DEFAULT_MAX_DEVICES: DEFAULT_MAX_DEVICES,
  body: body,
  noStore: noStore,
  normalizeCode: normalizeCode,
  formatCode: formatCode,
  generateCode: generateCode,
  clean: clean,
  logEvent: logEvent,
  ensureEntitlement: ensureEntitlement,
  entitlementPayload: entitlementPayload,
  effectiveEntitlement: effectiveEntitlement,
  applyLicense: applyLicense,
  devices: devices,
  devicePayload: devicePayload,
  mePayload: mePayload
}
