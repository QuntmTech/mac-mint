// Public plan-page funnel: /start sends the visitor to a configured Stripe Payment Link,
// the signed checkout.session.completed webhook records a purchase claim, and /welcome
// turns that claim into an account (or links it to an existing one) exactly once.
// Prices and links come only from the server's commerce configuration; a browser never
// supplies an amount, Price, link or ownership.
const CLAIM_MILLIS = 72 * 3600000
const EMAIL = /^[^\s@"<>()\[\],;:\\]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/
const SESSION = /^cs_[A-Za-z0-9_]{8,200}$/
const REFERENCE = /^[A-Za-z0-9_-]{1,200}$/
function payments() { return require(`${__hooks}/macmint_payments_lib.js`) }
function billing() { return require(`${__hooks}/macmint_billing.js`) }
function shared() { return require(`${__hooks}/macmint_lib.js`) }
function id(value) { return value && typeof value === "object" ? value.id : value }

function normalizeEmail(value) {
  const email = String(value || "").trim().toLowerCase()
  return email.length <= 254 && EMAIL.test(email) ? email : ""
}
function validSessionId(value) { return typeof value === "string" && SESSION.test(value) }
function interval(cfg, tier) { return tier.billing_interval || cfg.billing_interval }
function tierByName(cfg, name) { return (cfg.tiers || []).find(tier => tier.tier === name) || null }
function tierForLink(cfg, link) { return (cfg.tiers || []).find(tier => tier.payment_link_id === link) || null }
function publicPlans(cfg) {
  return { enabled: true, plan: "pro", tiers: cfg.tiers.map(tier => ({ tier: tier.tier, devices: tier.devices, amount_minor: tier.amount_minor,
    currency: tier.currency, trial_days: tier.trial_days, billing_interval: interval(cfg, tier), billing_interval_count: 1 })) }
}
// Stripe's documented Payment Link URL parameters. The reference is opaque and carries no
// authority: the webhook re-validates the link, Price and amount of the completed session.
function paymentLinkURL(tier, email, reference) {
  if (!REFERENCE.test(reference)) throw Error("Invalid reference")
  return tier.url + "?prefilled_email=" + encodeURIComponent(email) + "&client_reference_id=" + reference
}

// Live commerce configuration for the public page (requires the checkout kill switch on).
function openConfiguration(app) {
  const cfg = payments().configuration(app)
  return cfg && Array.isArray(cfg.tiers) ? cfg : null
}
// Webhooks and claims keep working while new checkout is switched off.
function knownConfiguration(app) {
  const cfg = payments().readiness(app).config
  return cfg && Array.isArray(cfg.tiers) ? cfg : null
}
function plans(app) {
  const cfg = openConfiguration(app)
  return cfg ? publicPlans(cfg) : { enabled: false }
}

function usersByEmail(app, email) {
  return app.findRecordsByFilter("users", "email:lower = {:e}", "created", 2, 0, { e: email }) || []
}
function claimRows(app, filter, params, limit = 20) {
  return app.findRecordsByFilter("purchase_claims", filter, "created", limit, 0, params) || []
}
function claimForSession(app, sessionId) { return claimRows(app, "session_id = {:s}", { s: sessionId }, 1)[0] || null }
// One free trial per account and per billing email. Payment Links cannot refuse a second
// trial themselves, so this is checked before redirecting and again when the purchase lands.
function eligibility(app, email, sessionId = "") {
  const user = usersByEmail(app, email)[0]
  if (user) {
    if (billing().hasOngoing(app, user.id) || shared().effectiveEntitlement(app, user.id).active) return "active_plan"
    if (billing().trialUsed(app, user.id)) return "trial_used"
  }
  const earlier = claimRows(app, "billing_email = {:e} && trial_days > 0 && session_id != {:s}", { e: email, s: sessionId }, 1)
  return earlier.length ? "trial_used" : "eligible"
}
function start(app, input) {
  const cfg = openConfiguration(app)
  if (!cfg) throw { code: "closed" }
  const email = normalizeEmail(input.email), tier = tierByName(cfg, String(input.tier || ""))
  if (!email || !tier) throw { code: "bad_request" }
  const verdict = eligibility(app, email)
  if (verdict !== "eligible" && tier.trial_days > 0) throw { code: verdict }
  return { url: paymentLinkURL(tier, email, "mmt_" + $security.randomString(24)), tier: tier.tier }
}

// Pure acceptance rule for a retrieved Checkout Session. Unknown links are ignored; a
// configured link with different terms is recorded for review and never grants access.
function classifySession(cfg, full) {
  const tier = tierForLink(cfg, payments().paymentLink(full))
  if (!tier) return { result: "ignored" }
  if (full.status !== "complete") return { result: "pending", tier }
  const lines = full.line_items && full.line_items.data
  const price = lines && lines.length === 1 && lines[0].price
  const email = normalizeEmail((full.customer_details && full.customer_details.email) || full.customer_email)
  const matches = !!price && !full.line_items.has_more && lines[0].quantity === 1 && full.mode === "subscription" &&
    full.livemode === cfg.livemode && full.currency === tier.currency && full.amount_total === (tier.trial_days > 0 ? 0 : tier.amount_minor) &&
    price.id === tier.price_id && price.unit_amount === tier.amount_minor && price.currency === tier.currency &&
    price.livemode === cfg.livemode && !!price.recurring && price.recurring.interval === interval(cfg, tier) &&
    price.recurring.interval_count === 1 && price.recurring.usage_type === "licensed" &&
    /^sub_[A-Za-z0-9_]+$/.test(id(full.subscription) || "") && /^cus_[A-Za-z0-9_]+$/.test(id(full.customer) || "") && !!email
  return { result: matches ? "accepted" : "mismatch", tier, email,
    reference: REFERENCE.test(full.client_reference_id || "") ? full.client_reference_id : "" }
}
// Pure single-use/expiry rule for a stored claim snapshot.
function claimDecision(claim, now) {
  if (claim.state === "attention") return "attention"
  if (claim.state === "linked") return "existing_account"
  if (claim.state === "claimed") return "already_claimed"
  if (claim.state !== "pending" || claim.order || !/^sub_/.test(claim.subscription_id || "") || !/^cus_/.test(claim.customer_id || "")) return "attention"
  const expires = Date.parse(String(claim.expires_at || "").replace(" ", "T"))
  if (!Number.isFinite(expires) || expires <= now) return "expired"
  return "claimable"
}
function snapshot(row) {
  const value = {}
  for (const field of ["state", "order", "subscription_id", "customer_id", "expires_at"]) value[field] = row.get(field)
  return value
}

function saveClaim(app, full, verdict) {
  let claim
  app.runInTransaction(tx => {
    claim = claimForSession(tx, full.id)
    if (claim) return
    const tier = verdict.tier, mismatch = verdict.result !== "accepted"
    claim = new Record(tx.findCollectionByNameOrId("purchase_claims"))
    for (const [key, value] of Object.entries({ session_id: full.id, payment_link_id: tier.payment_link_id, tier: tier.tier, devices: tier.devices,
      price_id: tier.price_id, amount_minor: tier.amount_minor, currency: tier.currency, trial_days: tier.trial_days,
      billing_interval: tier.billing_interval || "", livemode: full.livemode === true, request_key: verdict.reference,
      billing_email: verdict.email || "", customer_id: String(id(full.customer) || ""), subscription_id: String(id(full.subscription) || ""),
      expires_at: new Date(Date.now() + CLAIM_MILLIS).toISOString() })) claim.set(key, value)
    const duplicate = !mismatch && tier.trial_days > 0 && eligibility(tx, verdict.email, full.id) !== "eligible"
    claim.set("state", mismatch ? "attention" : "pending")
    claim.set("attention", mismatch ? "terms_mismatch" : duplicate ? "duplicate_trial" : "")
    tx.save(claim)
    shared().logEvent(tx, mismatch ? "payment_link_mismatch" : "purchase_recorded", "", { session: full.id, tier: tier.tier, attention: claim.get("attention") })
  })
  return claim
}
// Creates the owner's order from the stored, verified claim and marks the claim linked or
// claimed. An ongoing subscription cannot bind a second one, so that is flagged instead.
function linkInTransaction(tx, cfg, claim, userId, state) {
  if (claim.get("order") || claim.get("state") !== "pending") return claim.get("state")
  claim.set("user", userId)
  if (billing().hasOngoing(tx, userId)) {
    claim.set("state", "attention"); claim.set("attention", "duplicate_subscription"); tx.save(claim)
    shared().logEvent(tx, "purchase_needs_review", userId, { session: claim.get("session_id"), reason: "duplicate_subscription" })
    return "attention"
  }
  const order = new Record(tx.findCollectionByNameOrId("checkout_orders"))
  for (const [key, value] of Object.entries({ user: userId, request_key: claim.get("request_key") || claim.get("session_id"), state: "pending",
    customer_email: claim.get("billing_email"), web_origin: payments().webOrigin(cfg.web_origin, cfg.livemode),
    price_id: claim.get("price_id"), amount_minor: claim.get("amount_minor"), currency: claim.get("currency"), plan: "pro", duration_days: 0,
    max_devices: claim.get("devices"), livemode: claim.get("livemode"), billing_mode: "subscription",
    billing_interval: claim.get("billing_interval") || cfg.billing_interval, billing_interval_count: 1,
    portal_configuration_id: cfg.portal_configuration_id, trial_days: claim.get("trial_days"), session_id: claim.get("session_id"),
    customer_id: claim.get("customer_id"), payment_link_id: claim.get("payment_link_id"),
    attention: claim.get("attention") === "duplicate_trial" ? "duplicate_trial" : "" })) order.set(key, value)
  tx.save(order)
  claim.set("order", order.id); claim.set("state", state); claim.set(state === "claimed" ? "claimed_at" : "linked_at", new Date().toISOString())
  tx.save(claim)
  shared().logEvent(tx, state === "claimed" ? "purchase_claimed" : "purchase_linked", userId, { session: claim.get("session_id"), order: order.id })
  return state
}
function link(app, cfg, claimId, userId) {
  let state
  app.runInTransaction(tx => { state = linkInTransaction(tx, cfg, tx.findRecordById("purchase_claims", claimId), userId, "linked") })
  return state
}
// Signed checkout.session.completed (or a claim/status fallback): retrieve the authoritative
// session, record the claim once, link it to an existing account for that billing email,
// and synchronize the subscription through the shared billing lifecycle.
function recordSession(app, stub) {
  if (!stub || !validSessionId(stub.id)) throw Error("Invalid session")
  const cfg = knownConfiguration(app)
  if (!cfg) return { result: "ignored" }
  if (stub.payment_link !== undefined && !tierForLink(cfg, payments().paymentLink(stub))) return { result: "ignored" }
  const full = payments().authoritativeSession(app, stub)
  const verdict = classifySession(cfg, full)
  if (verdict.result === "ignored" || verdict.result === "pending") return { result: verdict.result }
  let claim = saveClaim(app, full, verdict)
  if (claim.get("state") === "pending") {
    const owner = usersByEmail(app, claim.get("billing_email"))[0]
    if (owner) link(app, cfg, claim.id, owner.id)
    claim = app.findRecordById("purchase_claims", claim.id)
  }
  if (claim.get("order")) billing().fulfill(app, full)
  return { result: String(claim.get("state")), claim }
}

function plan(claim) {
  return { tier: String(claim.get("tier")), devices: claim.get("devices"), amount_minor: claim.get("amount_minor"), currency: String(claim.get("currency")),
    trial_days: claim.get("trial_days"), billing_interval: String(claim.get("billing_interval") || "year") }
}
const PUBLIC_STATE = { claimable: "ready", existing_account: "existing_account", already_claimed: "claimed", expired: "expired", attention: "attention" }
function locate(app, sessionId) {
  let claim = claimForSession(app, sessionId)
  if (claim) return { claim }
  // The browser can arrive before the webhook. Ask Stripe directly; nothing is granted
  // unless that authoritative session is a complete, configured Payment Link purchase.
  const result = recordSession(app, { id: sessionId })
  if (result.result === "ignored") return { state: "not_found" }
  claim = claimForSession(app, sessionId)
  return claim ? { claim } : { state: "processing" }
}
function status(app, sessionId, now = Date.now()) {
  if (!validSessionId(sessionId)) throw { code: "bad_request" }
  let found
  try { found = locate(app, sessionId) } catch (_) { return { state: "processing" } }
  if (!found.claim) return { state: found.state }
  return { state: PUBLIC_STATE[claimDecision(snapshot(found.claim), now)], email: String(found.claim.get("billing_email")), plan: plan(found.claim) }
}
// Single use: the pending → claimed transition, account creation and order binding share
// one transaction. An existing account for the billing email is linked, never replaced.
function claim(app, input, now = Date.now()) {
  const sessionId = String(input.session_id || ""), password = String(input.password || "")
  if (!validSessionId(sessionId)) throw { code: "bad_request" }
  if (password.length < 8 || password.length > 71) throw { code: "weak_password" }
  const requested = input.email === undefined || input.email === null || input.email === "" ? null : normalizeEmail(input.email)
  if (requested === "") throw { code: "bad_email" }
  const found = locate(app, sessionId)
  if (!found.claim) throw { code: found.state }
  const before = claimDecision(snapshot(found.claim), now)
  // Already linked to the account that owns the billing email: report it, change nothing.
  if (before === "existing_account") return { outcome: "existing_account", email: String(found.claim.get("billing_email")), syncPending: false, plan: plan(found.claim) }
  if (before !== "claimable") throw { code: before }
  const cfg = knownConfiguration(app)
  if (!cfg) throw Error("Commerce configuration unavailable")
  const full = payments().authoritativeSession(app, { id: sessionId })
  if (classifySession(cfg, full).result !== "accepted" || full.id !== found.claim.get("session_id") ||
      String(id(full.subscription)) !== found.claim.get("subscription_id") || String(id(full.customer)) !== found.claim.get("customer_id")) throw { code: "attention" }
  const billingEmail = String(found.claim.get("billing_email")), email = requested || billingEmail
  let outcome, userId
  app.runInTransaction(tx => {
    const current = tx.findRecordById("purchase_claims", found.claim.id)
    const decision = claimDecision(snapshot(current), now)
    if (decision !== "claimable") throw { code: decision }
    const owner = usersByEmail(tx, billingEmail)[0]
    if (owner) { outcome = linkInTransaction(tx, cfg, current, owner.id, "linked") === "linked" ? "existing_account" : "attention"; return }
    if (email !== billingEmail && usersByEmail(tx, email).length) throw { code: "email_taken" }
    const user = new Record(tx.findCollectionByNameOrId("users"))
    user.set("email", email); user.setPassword(password); user.set("emailVisibility", false)
    // Keeping the Stripe email: that address completed checkout and no account owned it.
    // A different sign-in address follows the normal verification-email policy.
    user.set("verified", email === billingEmail)
    tx.save(user)
    userId = user.id
    outcome = linkInTransaction(tx, cfg, current, user.id, "claimed") === "claimed" ? "claimed" : "attention"
  })
  let syncPending = false
  if (outcome !== "attention") {
    try { billing().fulfill(app, full) } catch (_) { syncPending = true }
  }
  return { outcome, userId, email: outcome === "existing_account" ? billingEmail : email, syncPending, plan: plan(found.claim) }
}
// Superuser recovery for a claim that expired or arrived without a matching account.
function adminLink(app, sessionId, userId) {
  const claim = claimForSession(app, sessionId)
  if (!claim) throw { code: "not_found" }
  const cfg = knownConfiguration(app)
  if (!cfg) throw Error("Commerce configuration unavailable")
  app.findRecordById("users", userId)
  const state = link(app, cfg, claim.id, userId)
  if (state === "linked") billing().fulfill(app, payments().authoritativeSession(app, { id: sessionId }))
  return { state }
}
// Re-synchronizes a signed-in user's ongoing subscriptions from Stripe.
function refresh(app, userId) {
  const rows = app.findRecordsByFilter("billing_subscriptions", "user = {:u} && terminal = false", "-created", 5, 0, { u: userId }) || []
  for (const row of rows) billing().sync(app, String(row.get("subscription_id")))
  return rows.length
}
module.exports = { normalizeEmail, validSessionId, publicPlans, paymentLinkURL, tierByName, tierForLink, classifySession, claimDecision,
  plans, start, eligibility, recordSession, status, claim, adminLink, refresh, CLAIM_MILLIS }
