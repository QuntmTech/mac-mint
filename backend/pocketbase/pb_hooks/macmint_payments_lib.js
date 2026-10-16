// PocketBase's Goja runtime cannot load the Node SDK. This small server-only REST client
// uses Stripe's current API; no key or upstream error body is ever returned to the browser.
const API_VERSION = "2026-08-26.dahlia"
function secret(app, name, environment) {
  const value = $os.getenv(environment)
  if (value) return value
  try { return String(app.findFirstRecordByFilter("app_secrets", "name = {:n}", { n: name }).get("value") || "") }
  catch (_) { return "" }
}
class StripeClient {
  constructor(app) { this.key = secret(app, "stripe_restricted_key", "STRIPE_RESTRICTED_KEY") }
  send(method, path, fields, idempotencyKey) {
    if (!this.key) throw Error("Checkout is unavailable.")
    const headers = { Authorization: "Bearer " + this.key, "Stripe-Version": API_VERSION,
      "Content-Type": "application/x-www-form-urlencoded" }
    if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey
    const body = Object.entries(fields || {}).map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(String(v))).join("&")
    const result = $http.send({ method, url: "https://api.stripe.com/v1/" + path, headers, body, timeout: 20 })
    if (result.statusCode < 200 || result.statusCode >= 300) throw Error("Checkout is unavailable.")
    return result.json
  }
}
function configuration(app) {
  let cfg
  try { cfg = JSON.parse(toString(app.findFirstRecordByFilter("app_config", "key = 'commerce'").get("value"))) } catch (_) { return null }
  if (!cfg || cfg.enabled !== true || !/^price_[A-Za-z0-9]+$/.test(cfg.price_id || "") ||
    !/^[a-z]{3}$/.test(cfg.currency || "") || !Number.isInteger(cfg.amount_cents) || cfg.amount_cents <= 0 ||
    ["pro", "lifetime"].indexOf(cfg.plan) < 0 || !Number.isInteger(cfg.duration_days) || cfg.duration_days < 0 ||
    !Number.isInteger(cfg.max_devices) || cfg.max_devices < 1 || cfg.max_devices > 100 || typeof cfg.livemode !== "boolean") return null
  if (!secret(app, "stripe_restricted_key", "STRIPE_RESTRICTED_KEY") || !secret(app, "stripe_webhook_secret", "STRIPE_WEBHOOK_SECRET")) return null
  // Customers must have a validated consumer build to download before checkout opens.
  try { app.findFirstRecordByFilter("app_releases", "published = true && validated = true && notarized = true && channel = 'stable'") }
  catch (_) { return null }
  return cfg
}
function verifySignature(raw, header, signingSecret, nowSeconds) {
  if (!signingSecret || !header || raw.length > 1048576) return false
  const parts = header.split(","), stamps = parts.filter(p => p.startsWith("t="))
  if (stamps.length !== 1 || !/^t=\d+$/.test(stamps[0])) return false
  const timestamp = Number(stamps[0].slice(2))
  if (Math.abs(nowSeconds - timestamp) > 300) return false
  const expected = $security.hs256(timestamp + "." + raw, signingSecret)
  return parts.filter(p => /^v1=[a-f0-9]{64}$/.test(p)).some(p => $security.equal(p.slice(3), expected))
}
function orderForRequest(app, user, key, cfg) {
  let order
  app.runInTransaction(tx => {
    try { order = tx.findFirstRecordByFilter("checkout_orders", "user = {:u} && request_key = {:k}", { u: user.id, k: key }); return } catch (_) {}
    order = new Record(tx.findCollectionByNameOrId("checkout_orders"))
    order.set("user", user.id); order.set("request_key", key); order.set("state", "created")
    for (const field of ["price_id", "amount_cents", "currency", "plan", "duration_days", "max_devices", "livemode"]) order.set(field, cfg[field])
    tx.save(order)
  })
  return order
}
function checkout(app, user, key) {
  const cfg = configuration(app)
  if (!cfg) throw Error("Checkout is not open yet.")
  const client = new StripeClient(app)
  const order = orderForRequest(app, user, key, cfg)
  const price = client.send("GET", "prices/" + encodeURIComponent(order.get("price_id")))
  if (!price.active || price.type !== "one_time" || price.unit_amount !== order.get("amount_cents") || price.currency !== order.get("currency") || price.livemode !== order.get("livemode")) throw Error("This offer needs attention before purchase.")
  const session = client.send("POST", "checkout/sessions", {
    mode: "payment", "line_items[0][price]": order.get("price_id"), "line_items[0][quantity]": 1,
    client_reference_id: user.id, "metadata[macmint_order]": order.id,
    customer_email: user.get("email"),
    success_url: "https://macmint.co/account?checkout=processing", cancel_url: "https://macmint.co/account?checkout=cancelled",
    integration_identifier: "macmint_hosted_" + order.id.slice(0, 8).replace(/\d/g, n => "abcdefghij"[Number(n)]),
  }, "macmint-order-" + order.id)
  if (!/^cs_[A-Za-z0-9_]+$/.test(session.id || "") || !/^https:\/\/checkout\.stripe\.com\//.test(session.url || "")) throw Error("Checkout could not be opened.")
  app.runInTransaction(tx => {
    const current = tx.findRecordById("checkout_orders", order.id)
    if (current.get("session_id") && current.get("session_id") !== session.id) throw Error("Checkout conflict")
    current.set("session_id", session.id)
    if (current.get("state") !== "fulfilled") current.set("state", "pending")
    tx.save(current)
  })
  return session.url
}
function fulfill(app, session) {
  // A valid event is only a trigger. Retrieve authoritative session + line items from Stripe
  // before granting access; never bind a purchase to an email supplied by the browser.
  if (!/^cs_[A-Za-z0-9_]+$/.test(session.id || "")) throw Error("Invalid session")
  const full = new StripeClient(app).send("GET", "checkout/sessions/" + session.id + "?expand%5B%5D=line_items")
  if (full.payment_status !== "paid") return false
  const orderId = full.metadata && full.metadata.macmint_order
  if (!orderId) throw Error("Missing order")
  const lib = require(`${__hooks}/macmint_lib.js`)
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", orderId)
    const lines = full.line_items && full.line_items.data
    if (full.mode !== "payment" || full.client_reference_id !== order.get("user") || full.amount_total !== order.get("amount_cents") ||
        full.currency !== order.get("currency") || full.livemode !== order.get("livemode") || !lines || lines.length !== 1 ||
        full.line_items.has_more || lines[0].quantity !== 1 || !lines[0].price || lines[0].price.id !== order.get("price_id") ||
        (order.get("session_id") && order.get("session_id") !== full.id)) throw Error("Order mismatch")
    if (order.get("state") === "fulfilled") return
    const license = new Record(tx.findCollectionByNameOrId("licenses"))
    license.set("code", lib.generateCode()); license.set("code_hint", "")
    for (const field of ["plan", "duration_days", "max_devices"]) license.set(field, order.get(field))
    license.set("status", "redeemed"); license.set("source", "stripe"); license.set("order_ref", full.id)
    license.set("redeemed_by", order.get("user")); license.set("redeemed_at", new Date().toISOString())
    tx.save(license)
    const entitlement = lib.ensureEntitlement(tx, order.get("user"))
    lib.applyLicense(entitlement, license); tx.save(entitlement)
    order.set("session_id", full.id); order.set("state", "fulfilled"); tx.save(order)
    lib.logEvent(tx, "checkout_fulfilled", order.get("user"), { order: order.id, session: full.id })
  })
  return true
}
module.exports = { StripeClient, secret, configuration, verifySignature, orderForRequest, checkout, fulfill }
