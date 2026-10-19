routerAdd("GET", "/api/macmint/checkout/config", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  e.response.header().set("Cache-Control", "no-store")
  const cfg = payments.configuration(e.app)
  const userId = e.auth && e.auth.collection().name === "users" ? e.auth.id : null
  return e.json(200, cfg ? { enabled: true, ...payments.publicOffer(payments.offerForUser(e.app, cfg, userId)) } : { enabled: false })
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
    if (error.code === "plan_exists") return e.json(409, { error: "plan_exists", message: "Your account already has access or a subscription to manage. Refresh your account or open billing instead of paying again." })
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

routerAdd("POST", "/api/macmint/billing/portal", e => {
  require(`${__hooks}/macmint_lib.js`).noStore(e)
  try { return e.json(200, { url: require(`${__hooks}/macmint_billing.js`).portal(e.app, e.auth.id) }) }
  catch (_) { return e.json(503, { error: "billing_unavailable", message: "Billing could not be opened. Retry, or contact support@macmint.co for subscription help." }) }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/stripe/webhook", e => {
  const payments = require(`${__hooks}/macmint_payments_lib.js`)
  const secret = payments.secret(e.app, "stripe_webhook_secret", "STRIPE_WEBHOOK_SECRET")
  let raw
  try { raw = readerToString(e.request.body, 1048577) } catch (_) { return e.json(400, { error: "bad_body" }) }
  if (!payments.verifySignature(raw, e.request.header.get("Stripe-Signature"), secret, Date.now() / 1000)) return e.json(400, { error: "invalid_signature" })
  let event
  try { event = JSON.parse(raw) } catch (_) { return e.json(400, { error: "bad_event" }) }
  if (!event || typeof event !== "object" || Array.isArray(event) || typeof event.type !== "string") return e.json(400, { error: "bad_event" })
  if (["customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted", "customer.subscription.paused", "customer.subscription.resumed",
    "invoice.paid", "invoice.payment_failed", "invoice.payment_action_required", "invoice.finalization_failed", "invoice.voided", "invoice.marked_uncollectible"].indexOf(event.type) >= 0) {
    try { require(`${__hooks}/macmint_billing.js`).event(e.app, event.type, event.data && event.data.object) }
    catch (_) { return e.json(503, { error: "billing_sync_pending" }) }
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
