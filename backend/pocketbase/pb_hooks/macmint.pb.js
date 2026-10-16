/// <reference path="../pb_data/types.d.ts" />
// MacMint account + licensing API.
//
// GET  /api/macmint/me                    (user)  account, entitlement, devices
// POST /api/macmint/redeem                (user)  { code } -> unlocks Pro
// POST /api/macmint/devices/activate      (user)  { device_id, name?, model?, os_version?, app_version? }
// POST /api/macmint/devices/deactivate    (user)  { device_id }
// POST /api/macmint/admin/licenses        (superuser) { count, plan, duration_days?, max_devices?, source?, note?, order_ref? }
//
// Collections are locked to clients for writes; every entitlement/device change goes through here.

onRecordAfterCreateSuccess((e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  try {
    lib.ensureEntitlement(e.app, e.record.id)
  } catch (err) {
    console.log("macmint: could not create entitlement for", e.record.id, err)
  }
  e.next()
}, "users")

routerAdd("GET", "/api/macmint/me", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  return e.json(200, lib.mePayload(e.app, e.auth))
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/redeem", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const user = e.auth
  const code = lib.normalizeCode(lib.body(e).code)
  if (code.length < 12 || code.length > 64) {
    return e.json(400, { error: "invalid_code", message: "Enter the full redemption code from your purchase email." })
  }

  let failure = null
  let alreadyRedeemed = false
  e.app.runInTransaction((tx) => {
    let lic = null
    try {
      lic = tx.findFirstRecordByFilter("licenses", "code = {:c}", { c: code })
    } catch (err) {
      lic = null
    }
    if (!lic) {
      failure = { status: 404, error: "invalid_code", message: "That code wasn't recognized. Check it and try again." }
      return
    }
    const status = String(lic.get("status"))
    const owner = String(lic.get("redeemed_by") || "")
    if (status === "revoked") {
      failure = { status: 403, error: "code_revoked", message: "This code has been revoked. Contact support@macmint.co." }
      return
    }
    if (status === "redeemed") {
      if (owner === user.id) {
        alreadyRedeemed = true
        return
      }
      failure = { status: 409, error: "code_used", message: "This code has already been redeemed on another account." }
      return
    }

    lic.set("status", "redeemed")
    lic.set("redeemed_by", user.id)
    lic.set("redeemed_at", new Date().toISOString())
    tx.save(lic)

    const ent = lib.ensureEntitlement(tx, user.id)
    lib.applyLicense(ent, lic)
    tx.save(ent)
    lib.logEvent(tx, "license_redeemed", user.id, { license: lic.id })
  })

  if (failure) {
    lib.logEvent(e.app, "redeem_failed", user.id, { reason: failure.error })
    return e.json(failure.status, { error: failure.error, message: failure.message })
  }
  const payload = lib.mePayload(e.app, user)
  payload.redeemed = true
  payload.already_redeemed = alreadyRedeemed
  return e.json(200, payload)
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/devices/activate", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const user = e.auth
  const data = lib.body(e)
  const deviceId = String(data.device_id || "").trim()
  if (!/^[A-Za-z0-9-]{16,64}$/.test(deviceId)) {
    return e.json(400, { error: "bad_request", message: "Missing or malformed device_id." })
  }

  const ent = lib.entitlementPayload(lib.ensureEntitlement(e.app, user.id))
  if (!ent.active) {
    return e.json(402, {
      error: "no_active_plan",
      message: "This account doesn't have an active MacMint plan. Redeem a code or purchase at macmint.co.",
      entitlement: ent
    })
  }

  let device = null
  try {
    device = e.app.findFirstRecordByFilter("devices", "user = {:u} && device_id = {:d}", { u: user.id, d: deviceId })
  } catch (err) {
    device = null
  }

  if (!device) {
    const existing = lib.devices(e.app, user.id)
    const limit = ent.max_devices > 0 ? ent.max_devices : lib.DEFAULT_MAX_DEVICES
    if (existing.length >= limit) {
      lib.logEvent(e.app, "device_limit", user.id, { limit: limit })
      return e.json(409, {
        error: "device_limit",
        message: "MacMint is already active on " + existing.length + " Mac" + (existing.length === 1 ? "" : "s") +
          ". Remove one from your account at macmint.co/account, then try again.",
        limit: limit,
        devices: existing.map(lib.devicePayload)
      })
    }
    device = new Record(e.app.findCollectionByNameOrId("devices"))
    device.set("user", user.id)
    device.set("device_id", deviceId)
    lib.logEvent(e.app, "device_activated", user.id, { device_id: deviceId })
  }

  device.set("name", lib.clean(data.name, 200) || "Mac")
  device.set("model", lib.clean(data.model, 100))
  device.set("os_version", lib.clean(data.os_version, 40))
  device.set("app_version", lib.clean(data.app_version, 40))
  device.set("last_seen", new Date().toISOString())
  e.app.save(device)

  const payload = lib.mePayload(e.app, user)
  payload.device = lib.devicePayload(device)
  return e.json(200, payload)
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/devices/deactivate", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const user = e.auth
  const deviceId = String(lib.body(e).device_id || "").trim()
  if (!deviceId) return e.json(400, { error: "bad_request", message: "Missing device_id." })
  let device = null
  try {
    device = e.app.findFirstRecordByFilter("devices", "user = {:u} && device_id = {:d}", { u: user.id, d: deviceId })
  } catch (err) {
    device = null
  }
  if (device) {
    e.app.delete(device)
    lib.logEvent(e.app, "device_deactivated", user.id, { device_id: deviceId })
  }
  return e.json(200, { ok: true })
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/admin/licenses", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const data = lib.body(e)
  const count = Math.floor(Number(data.count || 1))
  const plan = String(data.plan || "pro")
  const durationDays = Math.max(0, Math.floor(Number(data.duration_days || 0)))
  const maxDevices = Math.min(100, Math.max(1, Math.floor(Number(data.max_devices || lib.DEFAULT_MAX_DEVICES))))
  const source = String(data.source || "manual")
  if (!(count >= 1 && count <= 500)) return e.json(400, { error: "bad_request", message: "count must be 1-500" })
  if (["pro", "lifetime"].indexOf(plan) < 0) return e.json(400, { error: "bad_request", message: "plan must be pro or lifetime" })
  if (["stripe", "manual", "promo", "demo"].indexOf(source) < 0) return e.json(400, { error: "bad_request", message: "bad source" })

  const collection = e.app.findCollectionByNameOrId("licenses")
  const codes = []
  e.app.runInTransaction((tx) => {
    for (let i = 0; i < count; i++) {
      const code = lib.generateCode()
      const r = new Record(collection)
      r.set("code", code)
      r.set("code_hint", code.slice(-4))
      r.set("plan", plan)
      r.set("duration_days", durationDays)
      r.set("max_devices", maxDevices)
      r.set("status", "available")
      r.set("source", source)
      r.set("note", lib.clean(data.note, 500))
      r.set("order_ref", lib.clean(data.order_ref, 200))
      tx.save(r)
      codes.push({ id: r.id, code: lib.formatCode(code) })
    }
  })
  lib.logEvent(e.app, "licenses_minted", "", { count: count, plan: plan, source: source })
  return e.json(200, { codes: codes })
}, $apis.requireSuperuserAuth())
