/// <reference path="../pb_data/types.d.ts" />
// MacMint account + licensing API.
//
// GET  /api/macmint/me?device_id=          (user)  account, entitlement, devices
// POST /api/macmint/redeem                (user)  { code, device_id? } -> unlocks Pro
// POST /api/macmint/devices/activate      (user)  { device_id, reactivate?, name?, model?, os_version?, app_version? }
// POST /api/macmint/devices/deactivate    (user)  { device_id }
// POST /api/macmint/admin/licenses        (superuser) { count, plan, duration_days?, max_devices?, source?, note?, order_ref? }
// site_events (anonymous A/B funnel events): `user` is attached from the auth token only.
//
// Collections are locked to clients for writes; every entitlement/device change goes through here.
// When device_id names an active device of an active plan, responses also carry a signed
// `entitlement_assertion` for offline access (macmint_entitlement.js). The field is additive.

onRecordAfterCreateSuccess((e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  try {
    lib.ensureEntitlement(e.app, e.record.id)
  } catch (err) {
    console.log("macmint: could not create entitlement for", e.record.id, err)
  }
  e.next()
}, "users")

onRecordCreateRequest((e) => {
  if (e.auth && e.auth.collection().name === "users") {
    e.record.set("user", e.auth.id)
  }
  e.next()
}, "site_events")

routerAdd("GET", "/api/macmint/me", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  const entitlements = require(`${__hooks}/macmint_entitlement.js`)
  lib.noStore(e)
  let deviceId = ""
  try { deviceId = String(e.requestInfo().query["device_id"] || "").trim() } catch (err) { deviceId = "" }
  return e.json(200, entitlements.attach(e.app, lib.mePayload(e.app, e.auth), deviceId))
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/redeem", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  const entitlements = require(`${__hooks}/macmint_entitlement.js`)
  lib.noStore(e)
  const user = e.auth
  const input = lib.body(e)
  const code = lib.normalizeCode(input.code)
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
  const payload = entitlements.attach(e.app, lib.mePayload(e.app, user), String(input.device_id || "").trim())
  payload.redeemed = true
  payload.already_redeemed = alreadyRedeemed
  return e.json(200, payload)
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/devices/activate", (e) => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  const entitlements = require(`${__hooks}/macmint_entitlement.js`)
  lib.noStore(e)
  const user = e.auth
  const data = lib.body(e)
  const deviceId = String(data.device_id || "").trim()
  if (!/^[A-Za-z0-9-]{16,64}$/.test(deviceId)) {
    return e.json(400, { error: "bad_request", message: "Missing or malformed device_id." })
  }

  try {
    data.device_id = deviceId
    const device = lib.activateDevice(e.app, user, data)
    const payload = entitlements.attach(e.app, lib.mePayload(e.app, user), deviceId)
    payload.device = device
    return e.json(200, payload)
  } catch (err) {
    if (err.status) return e.json(err.status, { error: err.error, message: err.message, limit: err.limit, devices: err.devices })
    return e.json(503, { error: "activation_unavailable", message: "Activation could not be saved. Please try again." })
  }
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
    e.app.runInTransaction((tx) => {
      const current = tx.findRecordById("devices", device.id)
      current.set("deactivated", true)
      tx.save(current)
      lib.logEvent(tx, "device_deactivated", user.id, { device_id: deviceId })
    })
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
