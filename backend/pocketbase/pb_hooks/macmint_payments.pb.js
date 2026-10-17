routerAdd("GET", "/api/macmint/checkout/config", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  e.response.header().set("Cache-Control", "no-store")
  const cfg = payments.configuration(e.app)
  return e.json(200, cfg ? { enabled: true, amount_minor: cfg.amount_minor, currency: cfg.currency, plan: cfg.plan, duration_days: cfg.duration_days, max_devices: cfg.max_devices } : { enabled: false })
})

routerAdd("POST", "/api/macmint/checkout", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  if (!e.auth.get("verified")) return e.json(403, { error: "verify_email", message: "Verify your account email before purchasing." })
  const key = String(lib.body(e).request_key || "")
  if (!payments.validRequestKey(key)) return e.json(400, { error: "bad_request", message: "Missing checkout request ID." })
  try { return e.json(200, { url: payments.checkout(e.app, e.auth, key) }) }
  catch (error) {
    if (error.code === "checkout_in_progress") return e.json(409, { error: "checkout_in_progress", request_key: error.request_key, message: "Another checkout is open for your account. Resume that checkout instead of starting a second payment." })
    if (error.code === "checkout_attention") return e.json(409, { error: "checkout_attention", message: "Your earlier checkout attempts need to be checked before starting another payment. Contact support; do not pay again." })
    if (error.code === "checkout_complete") return e.json(409, { error: "checkout_complete", message: "This checkout is already complete or processing. Refresh your account to check access; do not pay again." })
    if (error.code === "checkout_expired") return e.json(409, { error: "checkout_expired", message: "This checkout is no longer open. Check its confirmed status before starting another attempt." })
    return e.json(503, { error: "checkout_unavailable", message: "Checkout could not be opened. Please try again later." })
  }
}, $apis.requireAuth("users"))

// Polling is intentionally database-only. Missing/ambiguous requests never authorize
// another purchase; only an authoritative terminal event makes a new attempt safe.
routerAdd("GET", "/api/macmint/checkout/status", e => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  lib.noStore(e)
  const key = String(e.request.url.query().get("request_key") || "")
  if (!payments.validRequestKey(key)) return e.json(400, { error: "bad_request", message: "Missing checkout request ID." })
  try { return e.json(200, payments.checkoutStatus(e.app, e.auth, key)) }
  catch (_) { return e.json(503, { error: "checkout_status_unavailable", message: "Checkout status could not be checked. Please retry." }) }
}, $apis.requireAuth("users"))

routerAdd("GET", "/api/macmint/admin/commerce/readiness", e => {
  require(`${__hooks}/macmint_lib.js`).noStore(e)
  const result = require(`${__hooks}/macmint_payments_lib.js`).readiness(e.app)
  return e.json(200, { ready: result.ready, reasons: result.reasons })
}, $apis.requireSuperuserAuth())

routerAdd("POST", "/api/macmint/stripe/webhook", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  const secret = payments.secret(e.app, "stripe_webhook_secret", "STRIPE_WEBHOOK_SECRET")
  let raw
  try { raw = readerToString(e.request.body, 1048577) } catch (_) { return e.json(400, { error: "bad_body" }) }
  if (!payments.verifySignature(raw, e.request.header.get("Stripe-Signature"), secret, Date.now() / 1000)) return e.json(400, { error: "invalid_signature" })
  let event
  try { event = JSON.parse(raw) } catch (_) { return e.json(400, { error: "bad_event" }) }
  if (!event || typeof event !== "object" || Array.isArray(event) || typeof event.type !== "string") return e.json(400, { error: "bad_event" })
  // Refunds and disputes revoke the order's license and recompute access. Charges are not
  // tagged with the order, so the handler maps their payment intent back to it.
  if (["charge.refunded", "charge.dispute.created", "charge.dispute.updated"].indexOf(event.type) >= 0) {
    try { payments.reverse(e.app, event.type, event.data && event.data.object) }
    catch (_) { return e.json(503, { error: "reversal_pending" }) }
    return e.json(200, { received: true })
  }
  const session = event.data && event.data.object
  if (!session || !session.metadata || !session.metadata.macmint_order) return e.json(200, { received: true })
  if (["checkout.session.expired", "checkout.session.async_payment_failed"].indexOf(event.type) >= 0) {
    try { payments.recordTerminalSession(e.app, session, event.type === "checkout.session.expired" ? "expired" : "failed") }
    catch (_) { return e.json(503, { error: "fulfillment_pending" }) }
  }
  if (["checkout.session.completed", "checkout.session.async_payment_succeeded"].indexOf(event.type) >= 0) {
    try { payments.fulfill(e.app, event.data.object) }
    catch (_) { return e.json(503, { error: "fulfillment_pending" }) } // Stripe retries; transaction prevents duplicate grants.
  }
  return e.json(200, { received: true })
}, $apis.bodyLimit(1048576))

routerAdd("POST", "/api/macmint/admin/licenses/revoke", e => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const data = lib.body(e)
  const ref = { license: lib.clean(data.license, 40), code: lib.clean(data.code, 80), order: lib.clean(data.order, 40), reason: lib.clean(data.reason, 200) }
  if (!ref.license && !ref.code && !ref.order) return e.json(400, { error: "bad_request", message: "Provide a license, code or order." })
  try { return e.json(200, require(`${__hooks}/macmint_payments_lib.js`).revokeLicense(e.app, ref)) }
  catch (error) {
    if (error.code === "not_found") return e.json(404, { error: "not_found", message: "No matching license." })
    return e.json(503, { error: "revoke_failed", message: "The license could not be revoked. Nothing was changed." })
  }
}, $apis.requireSuperuserAuth())

// Applies Stripe's authoritative session state to a stuck order (missing terminal webhook
// or checkout_attention). `session` is only used when the order never recorded one.
routerAdd("POST", "/api/macmint/admin/checkout/reconcile", e => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const data = lib.body(e)
  const ref = { order: lib.clean(data.order, 40), session: lib.clean(data.session, 200), confirm_expired_without_session: data.confirm_expired_without_session === true }
  if (!ref.order) return e.json(400, { error: "bad_request", message: "Provide an order." })
  try { return e.json(200, require(`${__hooks}/macmint_payments_lib.js`).reconcileOrder(e.app, ref)) }
  catch (error) {
    if (error.code === "not_found") return e.json(404, { error: "not_found", message: "No matching order." })
    if (["session_unknown", "too_recent", "session_mismatch", "bad_request", "conflict"].indexOf(error.code) >= 0) return e.json(409, { error: error.code })
    return e.json(503, { error: "reconcile_failed", message: "Stripe state could not be applied. Nothing was changed." })
  }
}, $apis.requireSuperuserAuth())

// Public feed records must refer to validated, notarized consumer artifacts on a trusted host.
onRecordCreate(e => {
  if (!require(`${__hooks}/macmint_payments_lib.js`).publishableRelease(e.record)) throw Error("Validate and notarize the release, and use a trusted HTTPS download URL, before publishing it.")
  e.next()
}, "app_releases")
onRecordUpdate(e => {
  if (!require(`${__hooks}/macmint_payments_lib.js`).publishableRelease(e.record)) throw Error("Validate and notarize the release, and use a trusted HTTPS download URL, before publishing it.")
  e.next()
}, "app_releases")
