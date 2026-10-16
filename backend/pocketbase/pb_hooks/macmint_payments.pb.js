routerAdd("GET", "/api/macmint/checkout/config", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  e.response.header().set("Cache-Control", "no-store")
  const cfg = payments.configuration(e.app)
  return e.json(200, cfg ? { enabled: true, amount_cents: cfg.amount_cents, currency: cfg.currency, duration_days: cfg.duration_days, max_devices: cfg.max_devices } : { enabled: false })
})

routerAdd("POST", "/api/macmint/checkout", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  if (!e.auth.get("verified")) return e.json(403, { error: "verify_email", message: "Verify your account email before purchasing." })
  const key = String(lib.body(e).request_key || "")
  if (!/^[a-f0-9-]{36}$/.test(key)) return e.json(400, { error: "bad_request", message: "Missing checkout request ID." })
  try { return e.json(200, { url: payments.checkout(e.app, e.auth, key) }) }
  catch (_) { return e.json(503, { error: "checkout_unavailable", message: "Checkout could not be opened. Please try again later." }) }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/stripe/webhook", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  const secret = payments.secret(e.app, "stripe_webhook_secret", "STRIPE_WEBHOOK_SECRET")
  let raw
  try { raw = readerToString(e.request.body, 1048577) } catch (_) { return e.json(400, { error: "bad_body" }) }
  if (!payments.verifySignature(raw, e.request.header.get("Stripe-Signature"), secret, Date.now() / 1000)) return e.json(400, { error: "invalid_signature" })
  let event
  try { event = JSON.parse(raw) } catch (_) { return e.json(400, { error: "bad_event" }) }
  const session = event.data && event.data.object
  if (!session || !session.metadata || !session.metadata.macmint_order) return e.json(200, { received: true })
  if (event.type === "checkout.session.async_payment_failed") {
    try { e.app.runInTransaction(tx => {
      const order = tx.findRecordById("checkout_orders", session.metadata.macmint_order)
      if (order.get("session_id") === session.id && order.get("state") !== "fulfilled") {
        order.set("state", "failed"); tx.save(order)
      }
    }) } catch (_) { return e.json(503, { error: "fulfillment_pending" }) }
  }
  if (["checkout.session.completed", "checkout.session.async_payment_succeeded"].indexOf(event.type) >= 0) {
    try { payments.fulfill(e.app, event.data.object) }
    catch (_) { return e.json(503, { error: "fulfillment_pending" }) } // Stripe retries; transaction prevents duplicate grants.
  }
  return e.json(200, { received: true })
}, $apis.bodyLimit(1048576))

// Public feed records must refer to validated, notarized consumer artifacts.
onRecordCreate(e => {
  if (e.record.get("published") && (!e.record.get("validated") || !e.record.get("notarized") ||
    !/^[a-f0-9]{64}$/.test(String(e.record.get("sha256"))) || !/^https:\/\//.test(String(e.record.get("download_url"))))) throw Error("Validate and notarize the release before publishing it.")
  e.next()
}, "app_releases")
onRecordUpdate(e => {
  if (e.record.get("published") && (!e.record.get("validated") || !e.record.get("notarized") ||
    !/^[a-f0-9]{64}$/.test(String(e.record.get("sha256"))) || !/^https:\/\//.test(String(e.record.get("download_url"))))) throw Error("Validate and notarize the release before publishing it.")
  e.next()
}, "app_releases")
