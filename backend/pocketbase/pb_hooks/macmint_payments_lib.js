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
// Trusted server configuration only. Goja has no browser URL implementation, so
// accept a strict origin grammar instead of attempting permissive URL parsing.
function webOrigin(value, livemode) {
  if (value === undefined) return "https://macmint.co"
  if (typeof value !== "string" || value.length > 300) return null
  const match = /^(https?):\/\/([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*)(?::([1-9][0-9]{0,4}))?$/i.exec(value)
  if (!match || match[2].length > 253 || (match[3] && Number(match[3]) > 65535)) return null
  const scheme = match[1].toLowerCase(), host = match[2].toLowerCase()
  if (scheme !== "https" && !(livemode === false && (host === "localhost" || host === "127.0.0.1"))) return null
  const port = match[3] && !((scheme === "https" && match[3] === "443") || (scheme === "http" && match[3] === "80")) ? ":" + match[3] : ""
  return scheme + "://" + host + port
}
// Pure validation can also be used by the offline operator readiness checker.
function validConfiguration(cfg, nowMillis = Date.now()) {
  return !!(cfg && typeof cfg === "object" && !Array.isArray(cfg) &&
    typeof cfg.price_id === "string" && /^price_[A-Za-z0-9]+$/.test(cfg.price_id) &&
    typeof cfg.currency === "string" && /^[a-z]{3}$/.test(cfg.currency) &&
    Number.isSafeInteger(cfg.amount_minor) && cfg.amount_minor > 0 && cfg.amount_minor <= 99999999 &&
    ["pro", "lifetime"].indexOf(cfg.plan) >= 0 && Number.isSafeInteger(cfg.duration_days) && cfg.duration_days >= 0 &&
    // Bound date arithmetic, without choosing a commercial term or recurring cadence.
    cfg.duration_days * 86400000 + nowMillis <= 8640000000000000 &&
    Number.isSafeInteger(cfg.max_devices) && cfg.max_devices >= 1 && cfg.max_devices <= 100 &&
    typeof cfg.livemode === "boolean" && typeof cfg.enabled === "boolean" &&
    ((cfg.plan === "lifetime") === (cfg.duration_days === 0)) && webOrigin(cfg.web_origin, cfg.livemode) !== null)
}
// A diagnostic contains reason codes only: never echo config records or secret values.
function readiness(app) {
  let cfg
  const reasons = []
  try { cfg = JSON.parse(toString(app.findFirstRecordByFilter("app_config", "key = 'commerce'").get("value"))) }
  catch (_) { reasons.push("commerce_not_configured") }
  const valid = validConfiguration(cfg)
  if (!valid && reasons.indexOf("commerce_not_configured") < 0) reasons.push("commerce_config_invalid")
  if (cfg && cfg.enabled !== true) reasons.push("commerce_disabled")
  if (!secret(app, "stripe_restricted_key", "STRIPE_RESTRICTED_KEY")) reasons.push("stripe_key_missing")
  if (!secret(app, "stripe_webhook_secret", "STRIPE_WEBHOOK_SECRET")) reasons.push("webhook_secret_missing")
  // Customers must have a validated consumer build to download before checkout opens.
  try { app.findFirstRecordByFilter("app_releases", "published = true && validated = true && notarized = true && channel = 'stable'") }
  catch (_) { reasons.push("validated_release_missing") }
  return { ready: valid && cfg.enabled === true && reasons.length === 0, reasons, config: valid ? cfg : null }
}
function configuration(app) {
  const result = readiness(app)
  return result.ready ? result.config : null
}
function validRequestKey(key) { return typeof key === "string" && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(key) }
function checkoutStatus(app, user, key) {
  let order
  try { order = app.findFirstRecordByFilter("checkout_orders", "user = {:u} && request_key = {:k}", { u: user.id, k: key }) }
  catch (_) { return { state: "not_found", can_start_new: false } }
  const state = String(order.get("state"))
  if (["created", "pending", "fulfilled", "failed", "expired"].indexOf(state) < 0) throw Error("Unknown checkout state")
  const result = { state, can_start_new: state === "failed" || state === "expired" }
  const snapshot = { enabled: true }
  for (const field of ["price_id", "amount_minor", "currency", "plan", "duration_days", "max_devices", "livemode"]) snapshot[field] = order.get(field)
  if (validConfiguration(snapshot)) {
    result.offer = {}
    for (const field of ["amount_minor", "currency", "plan", "duration_days", "max_devices"]) result.offer[field] = snapshot[field]
  }
  return result
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
    // Different tabs/browsers must resume the same unresolved purchase, not create
    // independently payable sessions. Check and insert share the order transaction.
    const pending = tx.findRecordsByFilter("checkout_orders", "user = {:u} && (state = 'created' || state = 'pending')", "created", 2, 0, { u: user.id }) || []
    if (pending.length === 1 && validRequestKey(pending[0].get("request_key"))) {
      throw { code: "checkout_in_progress", request_key: pending[0].get("request_key") }
    }
    if (pending.length) throw { code: "checkout_attention" }
    order = new Record(tx.findCollectionByNameOrId("checkout_orders"))
    order.set("user", user.id); order.set("request_key", key); order.set("state", "created")
    order.set("customer_email", String(user.get("email") || ""))
    order.set("web_origin", webOrigin(cfg.web_origin, cfg.livemode))
    for (const field of ["price_id", "amount_minor", "currency", "plan", "duration_days", "max_devices", "livemode"]) order.set(field, cfg[field])
    tx.save(order)
  })
  return order
}
function checkout(app, user, key) {
  const cfg = configuration(app)
  if (!cfg) throw Error("Checkout is not open yet.")
  const client = new StripeClient(app)
  const order = orderForRequest(app, user, key, cfg)
  if (order.get("state") === "fulfilled") throw { code: "checkout_complete" }
  if (["failed", "expired"].indexOf(order.get("state")) >= 0) throw { code: "checkout_expired" }
  // Retrieve an existing session instead of POSTing again. Stripe can prune idempotency
  // keys after 24 hours; the durable order/session association lasts beyond that window.
  if (order.get("session_id")) {
    const existing = client.send("GET", "checkout/sessions/" + encodeURIComponent(order.get("session_id")))
    return checkoutURL(existing, order, user)
  }
  // If a response was lost before its session ID committed, only retry within Stripe's
  // guaranteed retention window. Never create an orphan replacement for an old order.
  const created = Date.parse(String(order.get("created") || ""))
  if (!Number.isFinite(created) || Date.now() - created >= 23 * 3600000) throw { code: "checkout_expired" }
  // Historical unbound orders may already have POSTed with an unknown email. Changing
  // parameters under the same idempotency key is unsafe; webhooks can still reconcile them.
  if (!order.get("customer_email")) throw Error("Checkout needs reconciliation.")
  const price = client.send("GET", "prices/" + encodeURIComponent(order.get("price_id")))
  if (!price.active || price.type !== "one_time" || price.unit_amount !== order.get("amount_minor") || price.currency !== order.get("currency") || price.livemode !== order.get("livemode")) throw Error("This offer needs attention before purchase.")
  // Old orders used this original hardcoded origin. Never replace it with current
  // configuration while retrying a potentially accepted provider request.
  const origin = order.get("web_origin") || "https://macmint.co"
  if (webOrigin(origin, order.get("livemode")) !== origin) throw Error("Invalid checkout origin")
  const session = client.send("POST", "checkout/sessions", {
    mode: "payment", "line_items[0][price]": order.get("price_id"), "line_items[0][quantity]": 1,
    client_reference_id: user.id, "metadata[macmint_order]": order.id,
    customer_email: order.get("customer_email"),
    success_url: origin + "/account?checkout=processing", cancel_url: origin + "/account?checkout=cancelled",
    integration_identifier: "macmint_hosted_" + order.id.slice(0, 8).replace(/\d/g, n => "abcdefghij"[Number(n)]),
  }, "macmint-order-" + order.id)
  if (!/^cs_[A-Za-z0-9_]+$/.test(session.id || "")) throw Error("Checkout could not be opened.")
  app.runInTransaction(tx => {
    const current = tx.findRecordById("checkout_orders", order.id)
    if (current.get("session_id") && current.get("session_id") !== session.id) throw Error("Checkout conflict")
    current.set("session_id", session.id)
    if (current.get("state") === "created") current.set("state", "pending")
    tx.save(current)
  })
  return checkoutURL(session, app.findRecordById("checkout_orders", order.id), user)
}
function checkoutURL(session, order, user) {
  if (session.id !== order.get("session_id") || session.mode !== "payment" ||
      session.client_reference_id !== user.id || !session.metadata || session.metadata.macmint_order !== order.id ||
      session.livemode !== order.get("livemode")) throw Error("Checkout session mismatch")
  if (order.get("state") === "fulfilled" || session.status === "complete" || session.payment_status === "paid") throw { code: "checkout_complete" }
  if (session.status === "expired" || session.expires_at * 1000 <= Date.now() || ["failed", "expired"].indexOf(order.get("state")) >= 0) throw { code: "checkout_expired" }
  if (session.status !== "open" || !Number.isFinite(session.expires_at) ||
      !/^https:\/\/checkout\.stripe\.com\//.test(session.url || "")) throw Error("Checkout could not be opened.")
  return session.url
}
function authoritativeSession(app, session) {
  if (!session || !/^cs_[A-Za-z0-9_]+$/.test(session.id || "")) throw Error("Invalid session")
  const full = new StripeClient(app).send("GET", "checkout/sessions/" + session.id + "?expand%5B%5D=line_items")
  if (!full || full.id !== session.id || !full.metadata || !full.metadata.macmint_order) throw Error("Invalid session response")
  return full
}
function verifyOrderSession(order, full) {
  const lines = full.line_items && full.line_items.data
  if (full.mode !== "payment" || full.client_reference_id !== order.get("user") || full.amount_total !== order.get("amount_minor") ||
      full.currency !== order.get("currency") || full.livemode !== order.get("livemode") || !lines || lines.length !== 1 ||
      full.line_items.has_more || lines[0].quantity !== 1 || !lines[0].price || lines[0].price.id !== order.get("price_id") ||
      (order.get("session_id") && order.get("session_id") !== full.id)) throw Error("Order mismatch")
}
function fulfill(app, session) {
  // A signed event is only a trigger. Retrieve authoritative session + line items.
  return fulfillSession(app, authoritativeSession(app, session))
}
function fulfillSession(app, full) {
  if (full.payment_status !== "paid") return false
  const orderId = full.metadata.macmint_order
  const lib = require(`${__hooks}/macmint_lib.js`)
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", orderId)
    verifyOrderSession(order, full)
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
function recordTerminalSession(app, session, state) {
  const full = authoritativeSession(app, session)
  // Duplicate or out-of-order terminal events cannot downgrade a successful payment.
  if (full.payment_status === "paid") return fulfillSession(app, full)
  if (state === "expired" && full.status !== "expired") return false
  if (state === "failed" && (full.status !== "complete" || full.payment_status !== "unpaid")) return false
  if (["expired", "failed"].indexOf(state) < 0) throw Error("Invalid checkout transition")
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", full.metadata.macmint_order)
    verifyOrderSession(order, full)
    if (order.get("state") === "fulfilled") return
    order.set("session_id", full.id); order.set("state", state); tx.save(order)
  })
  return true
}
module.exports = { StripeClient, secret, configuration, validConfiguration, readiness, webOrigin, validRequestKey, checkoutStatus, verifySignature, orderForRequest, checkout, fulfill, recordTerminalSession }
