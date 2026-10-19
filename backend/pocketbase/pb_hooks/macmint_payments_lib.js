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
    validBillingTerms(cfg) && webOrigin(cfg.web_origin, cfg.livemode) !== null)
}
function billingMode(value) { return value.billing_mode || "payment" }
function validBillingTerms(cfg) {
  if (billingMode(cfg) === "payment") return (cfg.plan === "lifetime") === (cfg.duration_days === 0)
  return billingMode(cfg) === "subscription" && cfg.plan === "pro" && cfg.duration_days === 0 &&
    (cfg.trial_days === undefined || Number.isSafeInteger(cfg.trial_days) && cfg.trial_days >= 0 && cfg.trial_days <= 30) &&
    ["month", "year"].indexOf(cfg.billing_interval) >= 0 && cfg.billing_interval_count === 1 &&
    typeof cfg.portal_configuration_id === "string" && /^bpc_[A-Za-z0-9]+$/.test(cfg.portal_configuration_id)
}
function publicOffer(cfg) {
  const offer = {}
  for (const field of ["amount_minor", "currency", "plan", "duration_days", "max_devices"]) offer[field] = cfg[field]
  if (billingMode(cfg) === "subscription") {
    offer.billing_mode = "subscription"; offer.billing_interval = cfg.billing_interval; offer.billing_interval_count = cfg.billing_interval_count
    offer.trial_days = cfg.trial_days || 0
  }
  return offer
}
function offerForUser(app, cfg, userId) {
  if (billingMode(cfg) !== "subscription" || !userId) return cfg
  return { ...cfg, trial_days: require(`${__hooks}/macmint_billing.js`).trialUsed(app, userId) ? 0 : cfg.trial_days || 0 }
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
  if (["created", "pending", "fulfilled", "failed", "expired", "refunded", "disputed"].indexOf(state) < 0) throw Error("Unknown checkout state")
  let repeat = false
  if (state === "fulfilled") {
    const lib = require(`${__hooks}/macmint_lib.js`)
    const billing = require(`${__hooks}/macmint_billing.js`)
    repeat = !lib.effectiveEntitlement(app, user.id).active && billing.canRepurchase(app, user.id, order)
  }
  // A refunded one-time order is a verified terminal outcome; a disputed one is not reopened.
  const result = { state, can_start_new: state === "failed" || state === "expired" || state === "refunded" || repeat }
  const snapshot = { enabled: true }
  for (const field of ["price_id", "amount_minor", "currency", "plan", "duration_days", "max_devices", "livemode", "billing_mode", "billing_interval", "billing_interval_count", "portal_configuration_id", "trial_days"]) snapshot[field] = order.get(field)
  if (validConfiguration(snapshot)) {
    result.offer = publicOffer(snapshot)
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
    const lib = require(`${__hooks}/macmint_lib.js`)
    if (require(`${__hooks}/macmint_billing.js`).hasOngoing(tx, user.id) ||
        billingMode(cfg) === "subscription" && lib.effectiveEntitlement(tx, user.id).active) throw { code: "plan_exists" }
    order = new Record(tx.findCollectionByNameOrId("checkout_orders"))
    order.set("user", user.id); order.set("request_key", key); order.set("state", "created")
    order.set("customer_email", String(user.get("email") || ""))
    order.set("web_origin", webOrigin(cfg.web_origin, cfg.livemode))
    for (const field of ["price_id", "amount_minor", "currency", "plan", "duration_days", "max_devices", "livemode"]) order.set(field, cfg[field])
    order.set("billing_mode", billingMode(cfg))
    if (billingMode(cfg) === "subscription") {
      order.set("trial_days", offerForUser(tx, cfg, user.id).trial_days)
      for (const field of ["billing_interval", "billing_interval_count", "portal_configuration_id"]) order.set(field, cfg[field])
      const previous = require(`${__hooks}/macmint_billing.js`).customer(tx, user.id, cfg.livemode)
      if (previous) order.set("customer_id", previous)
    }
    tx.save(order)
  })
  return order
}
function checkout(app, user, key) {
  const cfg = configuration(app)
  if (!cfg) throw Error("Checkout is not open yet.")
  if (billingMode(cfg) === "subscription") {
    const access = require(`${__hooks}/macmint_lib.js`).effectiveEntitlement(app, user.id)
    if (["revoked", "suspended"].indexOf(access.status) >= 0) throw { code: "account_restricted" }
  }
  const client = new StripeClient(app)
  const order = orderForRequest(app, user, key, cfg)
  if (order.get("state") === "fulfilled") throw { code: "checkout_complete" }
  if (["failed", "expired", "refunded", "disputed"].indexOf(order.get("state")) >= 0) throw { code: "checkout_expired" }
  // Retrieve an existing session instead of POSTing again. Stripe can prune idempotency
  // keys after 24 hours; the durable order/session association lasts beyond that window.
  if (order.get("session_id")) {
    const existing = client.send("GET", "checkout/sessions/" + encodeURIComponent(order.get("session_id")))
    return checkoutURL(existing, order, user)
  }
  // If a response was lost before its session ID committed, only retry within Stripe's
  // guaranteed retention window. Never create an orphan replacement for an old order.
  const created = Date.parse(String(order.get("created") || ""))
  if (!Number.isFinite(created) || Date.now() - created >= 23 * 3600000) throw { code: "checkout_attention" }
  // Historical unbound orders may already have POSTed with an unknown email. Changing
  // parameters under the same idempotency key is unsafe; webhooks can still reconcile them.
  if (!order.get("customer_email")) throw { code: "checkout_attention" }
  const mode = order.get("billing_mode") || "payment"
  const price = client.send("GET", "prices/" + encodeURIComponent(order.get("price_id")))
  if (!price.active || price.type !== (mode === "subscription" ? "recurring" : "one_time") || price.unit_amount !== order.get("amount_minor") || price.currency !== order.get("currency") || price.livemode !== order.get("livemode")) throw Error("This offer needs attention before purchase.")
  if (mode === "subscription" && (!price.recurring || price.recurring.interval !== order.get("billing_interval") || price.recurring.interval_count !== order.get("billing_interval_count") || price.recurring.usage_type !== "licensed")) throw Error("This recurring offer needs attention before purchase.")
  if (mode === "subscription") require(`${__hooks}/macmint_billing.js`).verifyPortalConfiguration(client, order.get("portal_configuration_id"), order.get("livemode"))
  // Old orders used this original hardcoded origin. Never replace it with current
  // configuration while retrying a potentially accepted provider request.
  const origin = order.get("web_origin") || "https://macmint.co"
  if (webOrigin(origin, order.get("livemode")) !== origin) throw Error("Invalid checkout origin")
  const fields = {
    mode, "line_items[0][price]": order.get("price_id"), "line_items[0][quantity]": 1,
    client_reference_id: user.id, "metadata[macmint_order]": order.id,
    success_url: origin + "/account?checkout=processing", cancel_url: origin + "/account?checkout=cancelled",
    integration_identifier: "macmint_hosted_" + order.id.slice(0, 8).replace(/\d/g, n => "abcdefghij"[Number(n)]),
  }
  if (order.get("customer_id")) fields.customer = order.get("customer_id")
  else fields.customer_email = order.get("customer_email")
  if (mode === "subscription") {
    fields["subscription_data[metadata][macmint_order]"] = order.id
    fields.payment_method_collection = "always"
    if (order.get("trial_days") > 0) fields["subscription_data[trial_period_days]"] = order.get("trial_days")
  }
  const session = client.send("POST", "checkout/sessions", fields, "macmint-order-" + order.id)
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
  if (session.id !== order.get("session_id") || session.mode !== (order.get("billing_mode") || "payment") ||
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
  const total = order.get("billing_mode") === "subscription" && order.get("trial_days") > 0 ? 0 : order.get("amount_minor")
  if (full.mode !== (order.get("billing_mode") || "payment") || full.client_reference_id !== order.get("user") || full.amount_total !== total ||
      full.currency !== order.get("currency") || full.livemode !== order.get("livemode") || !lines || lines.length !== 1 ||
      full.line_items.has_more || lines[0].quantity !== 1 || !lines[0].price || lines[0].price.id !== order.get("price_id") ||
      (order.get("session_id") && order.get("session_id") !== full.id)) throw Error("Order mismatch")
}
function fulfill(app, session) {
  // A signed event is only a trigger. Retrieve authoritative session + line items.
  const full = authoritativeSession(app, session)
  verifyOrderSession(app.findRecordById("checkout_orders", full.metadata.macmint_order), full)
  if (full.mode === "subscription") return require(`${__hooks}/macmint_billing.js`).fulfill(app, full)
  return fulfillSession(app, full)
}
function fulfillSession(app, full) {
  if (full.payment_status !== "paid") return false
  const orderId = full.metadata.macmint_order
  const lib = require(`${__hooks}/macmint_lib.js`)
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", orderId)
    verifyOrderSession(order, full)
    // A refunded or disputed payment never regains access from a replayed success event.
    if (REVERSED.indexOf(order.get("state")) >= 0) return
    if (order.get("state") === "fulfilled") {
      // Older fulfilled orders learn their payment intent from a replayed event.
      if (!order.get("payment_intent") && PAYMENT_INTENT.test(full.payment_intent || "")) { order.set("payment_intent", full.payment_intent); tx.save(order) }
      return
    }
    const license = new Record(tx.findCollectionByNameOrId("licenses"))
    license.set("code", lib.generateCode()); license.set("code_hint", "")
    for (const field of ["plan", "duration_days", "max_devices"]) license.set(field, order.get(field))
    license.set("status", "redeemed"); license.set("source", "stripe"); license.set("order_ref", full.id)
    license.set("redeemed_by", order.get("user")); license.set("redeemed_at", new Date().toISOString())
    tx.save(license)
    const entitlement = lib.ensureEntitlement(tx, order.get("user"))
    lib.applyLicense(entitlement, license); tx.save(entitlement)
    order.set("session_id", full.id); order.set("state", "fulfilled")
    if (PAYMENT_INTENT.test(full.payment_intent || "")) order.set("payment_intent", full.payment_intent)
    tx.save(order)
    lib.logEvent(tx, "checkout_fulfilled", order.get("user"), { order: order.id, session: full.id })
  })
  return true
}
function recordTerminalSession(app, session, state) {
  return applyTerminal(app, authoritativeSession(app, session), state)
}
function applyTerminal(app, full, state) {
  // A failed delayed payment can still own an incomplete/past-due subscription.
  // Bind and synchronize it before permitting replacement checkout; session failure
  // alone is not proof that recurring billing has ended.
  if (full.mode === "subscription" && full.subscription) return require(`${__hooks}/macmint_billing.js`).fulfill(app, full)
  if (full.mode === "subscription" && full.status !== "expired") throw Error("Subscription termination is not yet verified")
  // Duplicate or out-of-order terminal events cannot downgrade a successful payment.
  if (full.payment_status === "paid") return full.mode === "subscription" ? require(`${__hooks}/macmint_billing.js`).fulfill(app, full) : fulfillSession(app, full)
  if (state === "expired" && full.status !== "expired") return false
  if (state === "failed" && (full.status !== "complete" || full.payment_status !== "unpaid")) return false
  if (["expired", "failed"].indexOf(state) < 0) throw Error("Invalid checkout transition")
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", full.metadata.macmint_order)
    verifyOrderSession(order, full)
    if (["fulfilled"].concat(REVERSED).indexOf(order.get("state")) >= 0) return
    order.set("session_id", full.id); order.set("state", state); tx.save(order)
  })
  return true
}

// ---------- refunds, disputes and operator recovery ----------

const REVERSED = ["refunded", "disputed"]
const PAYMENT_INTENT = /^pi_[A-Za-z0-9_]+$/
function timestamp(value) {
  const parsed = Date.parse(String(value || "").trim().replace(" ", "T"))
  return Number.isFinite(parsed) ? parsed : null
}
function lib() { return require(`${__hooks}/macmint_lib.js`) }
// Lookup errors propagate (and roll back the caller's transaction); only "no row" is null.
function orderLicense(app, order) {
  if (!order.get("session_id")) return null
  const rows = app.findRecordsByFilter("licenses", "order_ref = {:s} && source = 'stripe'", "", 1, 0, { s: order.get("session_id") }) || []
  return rows.length ? rows[0] : null
}
// Rebuilds a license-derived entitlement from the user's remaining redeemed licenses,
// replaying the same extension rule as applyLicense in redemption order. Operator-managed
// entitlements (manual grants, or a revoked/suspended account restriction, which also
// blocks subscriptions) are left untouched for review. Subscription access is separate
// (billing_subscriptions) and is reported through effectiveEntitlement.
function recomputeEntitlement(app, userId) {
  const shared = lib()
  const ent = shared.ensureEntitlement(app, userId)
  const status = String(ent.get("status"))
  if (String(ent.get("source")) === "manual" || status === "revoked" || status === "suspended") {
    shared.logEvent(app, "entitlement_review", userId, { reason: String(ent.get("source")) === "manual" ? "manual_entitlement" : "restricted_account" })
    return shared.effectiveEntitlement(app, userId, ent)
  }
  const licenses = app.findRecordsByFilter("licenses", "redeemed_by = {:u} && status = 'redeemed'", "redeemed_at,created", 1000, 0, { u: userId }) || []
  let expires = 0, lifetime = false, devices = 0, last = null
  for (const license of licenses) {
    const at = timestamp(license.get("redeemed_at")) || timestamp(license.get("created")) || Date.now()
    const days = Number(license.get("duration_days") || 0)
    if (String(license.get("plan")) === "lifetime" || days <= 0) lifetime = true
    else if (!lifetime) expires = Math.max(expires, at) + days * 86400000
    devices = Math.max(devices, Number(license.get("max_devices") || shared.DEFAULT_MAX_DEVICES))
    last = license
  }
  if (!last) {
    // The plain no-license state. "revoked" is reserved for operator account restrictions.
    ent.set("plan", "free"); ent.set("status", "active"); ent.set("expires_at", ""); ent.set("max_devices", 0); ent.set("license", "")
  } else {
    ent.set("plan", "pro"); ent.set("status", "active"); ent.set("expires_at", lifetime ? "" : new Date(expires).toISOString())
    ent.set("max_devices", devices); ent.set("license", last.id)
    ent.set("source", String(last.get("source")) === "demo" ? "demo" : "license")
  }
  app.save(ent)
  return shared.effectiveEntitlement(app, userId, ent)
}
// Marks the order, revokes its license and recomputes access in one transaction.
// Replays are no-ops; a partial refund or a dispute inquiry only flags the order for review.
const REVIEW_ONLY = ["partial_refund", "dispute_inquiry"]
function applyReversal(app, orderId, kind, details) {
  let outcome
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", orderId)
    const state = String(order.get("state"))
    if (REVERSED.indexOf(state) >= 0) { outcome = { result: "unchanged", state }; return }
    if (details.payment_intent && !order.get("payment_intent")) order.set("payment_intent", details.payment_intent)
    if (REVIEW_ONLY.indexOf(kind) >= 0) {
      const refunded = Math.max(Number(order.get("refunded_minor") || 0), Math.floor(Number(details.refunded_minor) || 0))
      if (order.get("attention") === kind && Number(order.get("refunded_minor") || 0) === refunded) { outcome = { result: "unchanged", state }; return }
      order.set("refunded_minor", refunded); order.set("attention", kind); tx.save(order)
      lib().logEvent(tx, "checkout_" + kind, order.get("user"), { order: order.id, refunded_minor: refunded, reference: details.reference || "" })
      outcome = { result: "review", state }
      return
    }
    if (kind === "refunded") order.set("refunded_minor", Math.floor(Number(details.refunded_minor) || Number(order.get("amount_minor")) || 0))
    order.set("state", kind); order.set("reversed_at", new Date().toISOString()); tx.save(order)
    const license = orderLicense(tx, order)
    let entitlement = null
    if (license) {
      if (license.get("status") !== "revoked") { license.set("status", "revoked"); tx.save(license) }
      if (license.get("redeemed_by")) entitlement = recomputeEntitlement(tx, license.get("redeemed_by"))
    }
    lib().logEvent(tx, "checkout_" + kind, order.get("user"), { order: order.id, license: license ? license.id : "", reference: details.reference || "" })
    outcome = { result: "revoked", state: kind, entitlement }
  })
  return outcome
}
// Subscription access is held on its billing_subscriptions row rather than revoked: the
// row keeps syncing with Stripe, but access() ignores it and renewals never clear the hold.
// Only the superuser release route re-grants. Replays and second reversals are no-ops.
function applySubscriptionReversal(app, rowId, kind, details) {
  const shared = lib()
  let outcome
  app.runInTransaction(tx => {
    const row = tx.findRecordById("billing_subscriptions", rowId)
    const subscription = String(row.get("subscription_id")), hold = String(row.get("access_hold") || "")
    const reference = String(details.reference || ""), amount = Math.floor(Number(details.refunded_minor) || 0)
    if (hold) { outcome = { result: "unchanged", hold, subscription }; return }
    if (REVIEW_ONLY.indexOf(kind) >= 0) {
      if (row.get("attention") === kind && row.get("attention_reference") === reference && Number(row.get("refunded_minor") || 0) === amount) { outcome = { result: "unchanged", subscription }; return }
      row.set("attention", kind); row.set("attention_reference", reference); row.set("refunded_minor", amount); tx.save(row)
      shared.logEvent(tx, "subscription_" + kind, row.get("user"), { subscription, reference, refunded_minor: amount })
      outcome = { result: "review", subscription }
      return
    }
    row.set("access_hold", kind); row.set("held_at", new Date().toISOString()); row.set("hold_reference", reference)
    if (kind === "refunded") row.set("refunded_minor", amount)
    tx.save(row)
    shared.logEvent(tx, "subscription_access_held", row.get("user"), { subscription, hold: kind, reference, reason: details.reason || "" })
    outcome = { result: "held", hold: kind, subscription, entitlement: shared.effectiveEntitlement(tx, row.get("user")) }
  })
  return outcome
}
// A subscription invoice's payment intent maps through Stripe's InvoicePayment to the
// invoice and its subscription; the subscription must be MacMint's, bound to the same
// customer and mode. Payments of other products return null.
function subscriptionForPaymentIntent(app, client, paymentIntent, livemode) {
  const billing = require(`${__hooks}/macmint_billing.js`)
  const list = client.send("GET", "invoice_payments?payment%5Btype%5D=payment_intent&payment%5Bpayment_intent%5D=" + encodeURIComponent(paymentIntent) + "&limit=1")
  const entry = list && Array.isArray(list.data) && list.data.length === 1 ? list.data[0] : null
  if (!entry || !entry.payment || entry.payment.payment_intent !== paymentIntent) return null
  const invoiceId = typeof entry.invoice === "string" ? entry.invoice : entry.invoice && entry.invoice.id
  if (!/^in_[A-Za-z0-9_]+$/.test(invoiceId || "")) return null
  const invoice = client.send("GET", "invoices/" + encodeURIComponent(invoiceId))
  if (!invoice || invoice.id !== invoiceId) throw Error("Invoice mismatch")
  const subscriptionId = billing.invoiceSubscription(invoice)
  if (!/^sub_[A-Za-z0-9_]+$/.test(subscriptionId || "")) return null
  let row = billing.known(app, subscriptionId)
  // Bind a MacMint subscription whose checkout events were missed; another product's stays unknown.
  if (!row) { billing.sync(app, subscriptionId); row = billing.known(app, subscriptionId) }
  if (!row) return null
  const customer = typeof invoice.customer === "string" ? invoice.customer : invoice.customer && invoice.customer.id
  if (customer !== row.get("customer_id") || invoice.livemode !== row.get("livemode") || livemode !== row.get("livemode")) throw Error("Subscription invoice mismatch")
  return row
}
function subscriptionRow(app, ref) {
  const billing = require(`${__hooks}/macmint_billing.js`)
  if (ref.subscription) return /^sub_[A-Za-z0-9_]+$/.test(ref.subscription) ? billing.known(app, ref.subscription) : null
  let order
  try { order = app.findRecordById("checkout_orders", ref.order) } catch (_) { return null }
  if (order.get("billing_mode") !== "subscription" || !order.get("subscription_id")) return null
  const row = billing.known(app, order.get("subscription_id"))
  return row && row.get("order") === order.id ? row : null
}
function isSubscriptionOrder(app, orderId) {
  try { return app.findRecordById("checkout_orders", orderId).get("billing_mode") === "subscription" } catch (_) { return false }
}
// Superuser re-grant after a refund, dispute or operator hold has been resolved.
function releaseSubscriptionHold(app, ref) {
  const row = subscriptionRow(app, ref)
  if (!row) throw { code: "not_found" }
  const shared = lib()
  let result
  app.runInTransaction(tx => {
    const current = tx.findRecordById("billing_subscriptions", row.id)
    const hold = String(current.get("access_hold") || "")
    if (hold) {
      current.set("access_hold", ""); current.set("attention", "hold_released"); current.set("attention_reference", hold); tx.save(current)
      shared.logEvent(tx, "subscription_hold_released", current.get("user"), { subscription: current.get("subscription_id"), hold, reason: ref.reason || "" })
    }
    result = { subscription: String(current.get("subscription_id")), released: !!hold, previous_hold: hold, entitlement: shared.effectiveEntitlement(tx, current.get("user")) }
  })
  return result
}
function orderForPaymentIntent(app, client, paymentIntent) {
  try { return app.findFirstRecordByFilter("checkout_orders", "payment_intent = {:p}", { p: paymentIntent }) } catch (_) {}
  // Orders fulfilled before payment intents were recorded: ask Stripe which session owns it.
  const list = client.send("GET", "checkout/sessions?payment_intent=" + encodeURIComponent(paymentIntent) + "&limit=1")
  const session = list && Array.isArray(list.data) && list.data.length === 1 ? list.data[0] : null
  if (!session || session.payment_intent !== paymentIntent || !session.metadata || !session.metadata.macmint_order) return null
  let order
  try { order = app.findRecordById("checkout_orders", session.metadata.macmint_order) } catch (_) { return null }
  return order.get("session_id") === session.id ? order : null
}
// A signed charge/dispute event is only a trigger: the authoritative object decides.
// One-time orders revoke their license; subscription invoices hold that subscription's
// access. Events for payments that are not MacMint's are acknowledged and ignored.
function reverse(app, type, object) {
  const client = new StripeClient(app)
  let charge, kind
  if (type === "charge.refunded") {
    if (!object || !/^(ch|py)_[A-Za-z0-9_]+$/.test(object.id || "")) throw Error("Invalid charge")
    charge = client.send("GET", "charges/" + object.id)
    if (!charge || charge.id !== object.id) throw Error("Invalid charge response")
    kind = charge.refunded === true ? "refunded" : (Number(charge.amount_refunded) > 0 ? "partial_refund" : null)
  } else if (type === "charge.dispute.created" || type === "charge.dispute.updated") {
    if (!object || !/^(dp|du)_[A-Za-z0-9_]+$/.test(object.id || "")) throw Error("Invalid dispute")
    const dispute = client.send("GET", "disputes/" + object.id)
    if (!dispute || dispute.id !== object.id) throw Error("Invalid dispute response")
    charge = { payment_intent: dispute.payment_intent, livemode: dispute.livemode }
    // Inquiries (warning_*) withdraw no funds and may never escalate: flag them only.
    // A formal chargeback (or an inquiry escalated to one) revokes. A won or closed
    // dispute first seen late does not revoke; restoring access stays an operator choice.
    const status = String(dispute.status || "")
    kind = ["needs_response", "under_review", "lost"].indexOf(status) >= 0 ? "disputed"
      : (["warning_needs_response", "warning_under_review"].indexOf(status) >= 0 ? "dispute_inquiry" : null)
  } else throw Error("Unsupported reversal")
  if (!kind) return { result: "ignored" }
  const paymentIntent = typeof charge.payment_intent === "string" ? charge.payment_intent : (charge.payment_intent && charge.payment_intent.id)
  if (!PAYMENT_INTENT.test(paymentIntent || "")) return { result: "ignored" }
  const details = { payment_intent: paymentIntent, refunded_minor: charge.amount_refunded, reference: object.id }
  const order = orderForPaymentIntent(app, client, paymentIntent)
  if (order && order.get("billing_mode") !== "subscription") {
    if (order.get("livemode") !== charge.livemode) throw Error("Mode mismatch")
    return applyReversal(app, order.id, kind, details)
  }
  const row = subscriptionForPaymentIntent(app, client, paymentIntent, charge.livemode)
  return row ? applySubscriptionReversal(app, row.id, kind, details) : { result: "ignored" }
}
// Superuser revocation by license ID, code or order, with the same entitlement cascade.
// Subscription orders (or a subscription ID) get the same access hold as a dispute.
function revokeLicense(app, ref) {
  const shared = lib()
  if (ref.subscription || (ref.order && isSubscriptionOrder(app, ref.order))) {
    const row = subscriptionRow(app, ref)
    if (!row) throw { code: "not_found" }
    const outcome = applySubscriptionReversal(app, row.id, "operator", { reference: "operator", reason: ref.reason })
    return { subscription: outcome.subscription, already_held: outcome.result === "unchanged", hold: outcome.hold,
      entitlement: outcome.entitlement || shared.effectiveEntitlement(app, row.get("user")) }
  }
  let result
  app.runInTransaction(tx => {
    let license = null, order = null
    try {
      if (ref.order) { order = tx.findRecordById("checkout_orders", ref.order); license = orderLicense(tx, order) }
      else if (ref.license) license = tx.findRecordById("licenses", ref.license)
      else if (ref.code) license = tx.findFirstRecordByFilter("licenses", "code = {:c}", { c: shared.normalizeCode(ref.code) })
    } catch (_) { license = null }
    if (!license) throw { code: "not_found" }
    const already = license.get("status") === "revoked"
    if (!already) { license.set("status", "revoked"); tx.save(license) }
    if (!order && String(license.get("source")) === "stripe" && license.get("order_ref")) {
      try { order = tx.findFirstRecordByFilter("checkout_orders", "session_id = {:s}", { s: license.get("order_ref") }) } catch (_) {}
    }
    if (order && REVERSED.indexOf(order.get("state")) < 0 && order.get("attention") !== "operator_revoked") {
      order.set("attention", "operator_revoked"); order.set("reversed_at", new Date().toISOString()); tx.save(order)
    }
    const owner = String(license.get("redeemed_by") || "")
    const entitlement = owner ? recomputeEntitlement(tx, owner) : null
    if (!already) shared.logEvent(tx, "license_revoked", owner, { license: license.id, reason: ref.reason || "" })
    result = { license: license.id, already_revoked: already, entitlement }
  })
  return result
}
// Superuser recovery for orders whose terminal webhook never arrived or that block new
// purchases as checkout_attention. Applies Stripe's authoritative session state through
// the normal fulfillment/expiry paths; it never infers payment or failure on its own.
function reconcileOrder(app, ref) {
  let order
  try { order = app.findRecordById("checkout_orders", ref.order) } catch (_) { throw { code: "not_found" } }
  const before = String(order.get("state"))
  const recurring = order.get("billing_mode") === "subscription"
  if (REVERSED.indexOf(before) >= 0 || (!recurring && before === "fulfilled")) return { order: order.id, state: before, changed: false }
  if (recurring && order.get("subscription_id")) {
    // A bound subscription resynchronizes from Stripe's subscription and latest invoice.
    // Holds survive the sync; release them explicitly.
    const billing = require(`${__hooks}/macmint_billing.js`)
    billing.sync(app, order.get("subscription_id"))
    const row = billing.known(app, order.get("subscription_id"))
    const after = String(app.findRecordById("checkout_orders", order.id).get("state"))
    if (after !== before) lib().logEvent(app, "checkout_reconciled", order.get("user"), { order: order.id, from: before, to: after })
    return { order: order.id, state: after, changed: after !== before, subscription_status: row ? String(row.get("status")) : "",
      access_held: !!(row && String(row.get("access_hold") || "")) }
  }
  const sessionId = String(order.get("session_id") || ref.session || "")
  if (!sessionId) {
    // No session was ever recorded. Only after every possible session has expired, and
    // only on explicit operator confirmation from the Stripe dashboard, close the order.
    if (ref.confirm_expired_without_session !== true) throw { code: "session_unknown" }
    const created = timestamp(order.get("created"))
    if (created === null || Date.now() - created < 25 * 3600000) throw { code: "too_recent" }
    app.runInTransaction(tx => {
      const current = tx.findRecordById("checkout_orders", order.id)
      if (current.get("session_id") || ["created", "pending"].indexOf(current.get("state")) < 0) throw { code: "conflict" }
      current.set("state", "expired"); tx.save(current)
      lib().logEvent(tx, "checkout_reconciled", current.get("user"), { order: current.id, from: before, to: "expired", confirmed_without_session: true })
    })
    return { order: order.id, state: "expired", changed: true }
  }
  if (!/^cs_[A-Za-z0-9_]+$/.test(sessionId)) throw { code: "bad_request" }
  const full = authoritativeSession(app, { id: sessionId })
  if (full.metadata.macmint_order !== order.id) throw { code: "session_mismatch" }
  if (full.mode === "subscription") {
    if (full.subscription) require(`${__hooks}/macmint_billing.js`).fulfill(app, full)
    else if (full.status === "expired") applyTerminal(app, full, "expired")
  } else if (full.payment_status === "paid") fulfillSession(app, full)
  else if (full.status === "expired") applyTerminal(app, full, "expired")
  // complete + unpaid is an asynchronous payment still settling, or a failure whose
  // event was lost. Resend that event from Stripe instead of guessing here.
  const after = String(app.findRecordById("checkout_orders", order.id).get("state"))
  if (after !== before) lib().logEvent(app, "checkout_reconciled", order.get("user"), { order: order.id, from: before, to: after })
  return { order: order.id, state: after, changed: after !== before, session_status: String(full.status || ""), payment_status: String(full.payment_status || "") }
}
// Feed downloads open in the customer's browser. Accept only first-party HTTPS hosts:
// the MacMint site and QuntmTech/mac-mint GitHub release assets (github.com redirects to
// signed, expiring githubusercontent URLs that can serve any repository, so those hosts
// are not accepted as feed URLs). No credentials, ports, queries, encodings or dot segments.
function trustedDownloadURL(value) {
  if (typeof value !== "string" || value.length > 2000) return false
  const match = /^https:\/\/([A-Za-z0-9.-]+)(\/[A-Za-z0-9._~+\/-]*)$/.exec(value)
  if (!match || match[2].split("/").some(part => part === "." || part === "..")) return false
  const host = match[1].toLowerCase()
  if (host === "macmint.co") return true
  return host === "github.com" && /^\/QuntmTech\/mac-mint\/releases\/download\/[^/]+\/[^/]+$/.test(match[2])
}
function publishableRelease(record) {
  return !record.get("published") || (!!record.get("validated") && !!record.get("notarized") &&
    /^[a-f0-9]{64}$/.test(String(record.get("sha256"))) && trustedDownloadURL(String(record.get("download_url"))))
}
module.exports = { StripeClient, secret, configuration, validConfiguration, publicOffer, offerForUser, readiness, webOrigin, validRequestKey, checkoutStatus, verifySignature, orderForRequest, checkout, fulfill, recordTerminalSession, authoritativeSession, verifyOrderSession,
  reverse, applyReversal, applySubscriptionReversal, releaseSubscriptionHold, recomputeEntitlement, revokeLicense, reconcileOrder, trustedDownloadURL, publishableRelease }
