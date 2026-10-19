// Recurring access is separate from redeemed/one-time licenses. Renewals replace an
// absolute paid-through date; duplicate invoices never append another period.
const STATES = ["active", "past_due", "unpaid", "incomplete", "incomplete_expired", "canceled", "paused", "trialing"]
const TERMINAL = ["canceled", "incomplete_expired"]
function payments() { return require(`${__hooks}/macmint_payments_lib.js`) }
function id(value) { return value && typeof value === "object" ? value.id : value }
function millis(value) { return Date.parse(String(value || "").replace(" ", "T")) }
function trialUsed(app, userId) { return require(`${__hooks}/macmint_lib.js`).ensureEntitlement(app, userId).get("subscription_trial_used") === true }
function rows(app, userId, extra = "", params = {}, limit = 100) {
  return app.findRecordsByFilter("billing_subscriptions", "user = {:u}" + extra, "-created", limit, 0, { u: userId, ...params }) || []
}
function hasOngoing(app, userId) { return rows(app, userId, " && terminal = false", {}, 1).length > 0 }
function canRepurchase(app, userId, order) {
  if (order.get("billing_mode") !== "subscription" || !order.get("subscription_id")) return false
  const row = known(app, order.get("subscription_id"))
  return !!(row && row.get("user") === userId && row.get("terminal") && !hasOngoing(app, userId))
}
function customer(app, userId, livemode) {
  const previous = rows(app, userId, " && livemode = {:mode}", { mode: livemode }, 1)[0]
  return previous ? String(previous.get("customer_id") || "") : ""
}
function access(app, userId) {
  const now = Date.now()
  let result = null
  for (const row of rows(app, userId, " && terminal = false")) {
    const trial = row.get("status") === "trialing"
    if (!trial && ["active", "past_due"].indexOf(row.get("status")) < 0) continue
    const end = millis(row.get(trial ? "trial_through" : "paid_through"))
    if (!Number.isFinite(end) || end <= now) continue
    const order = app.findRecordById("checkout_orders", row.get("order"))
    if (order.get("user") !== userId || order.get("billing_mode") !== "subscription") throw Error("Invalid billing ownership")
    const devices = Number(order.get("max_devices"))
    if (!Number.isSafeInteger(devices) || devices < 1 || devices > 100) throw Error("Invalid billing allowance")
    result = { plan: "pro", status: "active", active: true,
      expires_at: new Date(Math.max(end, result ? Date.parse(result.expires_at) : 0)).toISOString(),
      max_devices: Math.max(devices, result ? result.max_devices : 0), source: trial ? "subscription_trial" : "subscription" }
  }
  return result
}
function known(app, subscriptionId) {
  return (app.findRecordsByFilter("billing_subscriptions", "subscription_id = {:s}", "", 1, 0, { s: subscriptionId }) || [])[0] || null
}
function verifyBinding(order, full, subscriptionId) {
  payments().verifyOrderSession(order, full)
  if (!full.metadata || full.metadata.macmint_order !== order.id || full.mode !== "subscription" || full.status !== "complete" || id(full.subscription) !== subscriptionId ||
      !/^cus_[A-Za-z0-9_]+$/.test(id(full.customer) || "") ||
      (order.get("customer_id") && order.get("customer_id") !== id(full.customer)) ||
      (order.get("subscription_id") && order.get("subscription_id") !== subscriptionId)) throw Error("Subscription checkout mismatch")
}
function bind(app, full, subscriptionId) {
  let row
  app.runInTransaction(tx => {
    const order = tx.findRecordById("checkout_orders", full.metadata.macmint_order)
    verifyBinding(order, full, subscriptionId)
    row = known(tx, subscriptionId)
    if (row) {
      if (row.get("user") !== order.get("user") || row.get("order") !== order.id || row.get("customer_id") !== id(full.customer)) throw Error("Subscription ownership mismatch")
      return
    }
    const foreign = tx.findRecordsByFilter("billing_subscriptions", "customer_id = {:c} && user != {:u}", "", 1, 0,
      { c: id(full.customer), u: order.get("user") }) || []
    if (foreign.length) throw Error("Customer ownership mismatch")
    row = new Record(tx.findCollectionByNameOrId("billing_subscriptions"))
    for (const [key, value] of Object.entries({ user: order.get("user"), order: order.id,
      subscription_id: subscriptionId, customer_id: id(full.customer), livemode: order.get("livemode"), status: "incomplete", terminal: false, sync_generation: 0 })) row.set(key, value)
    tx.save(row)
    if (order.get("trial_days") > 0) {
      const entitlement = require(`${__hooks}/macmint_lib.js`).ensureEntitlement(tx, order.get("user"))
      entitlement.set("subscription_trial_used", true); tx.save(entitlement)
    }
    order.set("subscription_id", subscriptionId); order.set("customer_id", id(full.customer)); order.set("session_id", full.id); tx.save(order)
  })
  return row
}
function resolve(app, subscriptionId, suppliedSession) {
  let row = known(app, subscriptionId)
  if (row) {
    if (suppliedSession) verifyBinding(app.findRecordById("checkout_orders", row.get("order")), suppliedSession, subscriptionId)
    return row
  }
  let full = suppliedSession
  if (!full) {
    // Resolve through Stripe's object graph. Invoice metadata is not an ownership boundary.
    const list = new (payments().StripeClient)(app).send("GET", "checkout/sessions?subscription=" + encodeURIComponent(subscriptionId) + "&limit=2")
    if (!list || !Array.isArray(list.data) || list.has_more || list.data.length > 1) throw Error("Ambiguous subscription checkout")
    if (!list.data.length) return null
    if (!list.data[0].metadata || !list.data[0].metadata.macmint_order) return null
    full = payments().authoritativeSession(app, list.data[0])
  }
  return bind(app, full, subscriptionId)
}
function seconds(value) { return Number.isSafeInteger(value) && value > 0 && value * 1000 <= 8640000000000000 }
function invoiceSubscription(invoice) {
  return invoice && invoice.parent && invoice.parent.type === "subscription_details" ? id(invoice.parent.subscription_details && invoice.parent.subscription_details.subscription) : null
}
function paidPeriod(invoice, subscription, order) {
  if (!invoice || invoice.status !== "paid") return null
  const lines = invoice.lines && invoice.lines.data
  if (invoiceSubscription(invoice) !== subscription.id || id(invoice.customer) !== id(subscription.customer) ||
      invoice.livemode !== order.get("livemode") || invoice.currency !== order.get("currency") ||
      !lines || lines.length !== 1 || invoice.lines.has_more) throw Error("Invoice ownership or line mismatch")
  const line = lines[0], price = line.pricing && line.pricing.price_details && id(line.pricing.price_details.price)
  if (price !== order.get("price_id") || line.quantity !== 1 || !line.period ||
      !seconds(line.period.start) || !seconds(line.period.end) || line.period.end <= line.period.start) throw Error("Invoice service period mismatch")
  return new Date(line.period.end * 1000).toISOString()
}
function sync(app, subscriptionId, suppliedSession) {
  if (!/^sub_[A-Za-z0-9_]+$/.test(subscriptionId || "")) throw Error("Invalid subscription")
  const row = resolve(app, subscriptionId, suppliedSession)
  if (!row) return false // Another product's subscription in the same Stripe account.
  let generation
  app.runInTransaction(tx => {
    const current = tx.findRecordById("billing_subscriptions", row.id)
    generation = Number(current.get("sync_generation") || 0) + 1
    current.set("sync_generation", generation); tx.save(current)
  })
  const client = new (payments().StripeClient)(app)
  const subscription = client.send("GET", "subscriptions/" + encodeURIComponent(subscriptionId))
  const order = app.findRecordById("checkout_orders", row.get("order"))
  if (order.get("user") !== row.get("user")) throw Error("Billing ownership mismatch")
  const items = subscription && subscription.items && subscription.items.data
  if (!subscription || subscription.id !== subscriptionId || id(subscription.customer) !== row.get("customer_id") ||
      subscription.livemode !== order.get("livemode") || STATES.indexOf(subscription.status) < 0 ||
      !items || items.length !== 1 || subscription.items.has_more) throw Error("Subscription mismatch")
  const item = items[0], price = item.price
  if (!price || price.id !== order.get("price_id") || price.currency !== order.get("currency") ||
      price.unit_amount !== order.get("amount_minor") || !price.recurring || price.recurring.usage_type !== "licensed" ||
      price.recurring.interval !== order.get("billing_interval") || price.recurring.interval_count !== order.get("billing_interval_count") ||
      item.quantity !== 1 || !seconds(item.current_period_end)) throw Error("Subscription terms mismatch")
  let invoice = null
  const invoiceId = id(subscription.latest_invoice)
  if (invoiceId) {
    if (!/^in_[A-Za-z0-9_]+$/.test(invoiceId)) throw Error("Invalid invoice")
    invoice = client.send("GET", "invoices/" + encodeURIComponent(invoiceId))
    if (invoice.id !== invoiceId) throw Error("Invoice mismatch")
  }
  const paidReceipt = subscription.status === "trialing" ? null : paidPeriod(invoice, subscription, order)
  const paidThrough = subscription.status === "active" ? paidReceipt : null
  let trialThrough = null
  if (subscription.status === "trialing") {
    if (!(order.get("trial_days") > 0) || !seconds(subscription.trial_start) || !seconds(subscription.trial_end) ||
        subscription.trial_end <= subscription.trial_start || subscription.trial_end - subscription.trial_start > order.get("trial_days") * 86400) throw Error("Unconfigured trial")
    trialThrough = new Date(subscription.trial_end * 1000).toISOString()
  }
  let committed = false
  app.runInTransaction(tx => {
    const current = tx.findRecordById("billing_subscriptions", row.id)
    if (current.get("sync_generation") !== generation) return // A newer sync owns the result.
    if (current.get("terminal") && TERMINAL.indexOf(subscription.status) < 0) return // Terminal Stripe subscriptions never reactivate.
    current.set("status", subscription.status); current.set("terminal", TERMINAL.indexOf(subscription.status) >= 0)
    current.set("current_period_end", new Date(item.current_period_end * 1000).toISOString())
    current.set("cancel_at_period_end", subscription.cancel_at_period_end === true)
    current.set("cancel_at", seconds(subscription.cancel_at) ? new Date(subscription.cancel_at * 1000).toISOString() : "")
    current.set("trial_through", trialThrough || "")
    if (paidThrough) {
      const previous = millis(current.get("paid_through")) || 0
      current.set("paid_through", new Date(Math.max(previous, Date.parse(paidThrough))).toISOString())
      current.set("last_invoice", invoice.id)
    }
    tx.save(current)
    const currentOrder = tx.findRecordById("checkout_orders", order.id)
    if (paidReceipt || trialThrough) currentOrder.set("state", "fulfilled")
    else if (current.get("terminal") && currentOrder.get("state") !== "fulfilled") currentOrder.set("state", "failed")
    tx.save(currentOrder)
    committed = true
  })
  return committed
}
function fulfill(app, full) {
  const subscriptionId = id(full.subscription)
  if (!subscriptionId) return false
  return sync(app, subscriptionId, full)
}
function event(app, type, object) {
  if (type.startsWith("customer.subscription.")) return sync(app, object && object.id)
  if (!object || !/^in_[A-Za-z0-9_]+$/.test(object.id || "")) throw Error("Invalid invoice event")
  const invoice = new (payments().StripeClient)(app).send("GET", "invoices/" + encodeURIComponent(object.id))
  if (invoice.id !== object.id) throw Error("Invoice event mismatch")
  const subscriptionId = invoiceSubscription(invoice)
  return subscriptionId ? sync(app, subscriptionId) : false
}
function summary(app, userId) {
  const row = rows(app, userId, "", {}, 1)[0]
  if (!row) return { subscription: null }
  const order = app.findRecordById("checkout_orders", row.get("order"))
  if (order.get("user") !== userId) throw Error("Billing ownership mismatch")
  return { subscription: { status: row.get("status"), paid_through: row.get("paid_through") || null,
    trial_through: row.get("trial_through") || null,
    current_period_end: row.get("current_period_end") || null, cancel_at_period_end: row.get("cancel_at_period_end") === true,
    cancel_at: row.get("cancel_at") || null, ...payments().publicOffer({ billing_mode: "subscription",
      billing_interval: order.get("billing_interval"), billing_interval_count: order.get("billing_interval_count"),
      trial_days: order.get("trial_days") || 0,
      amount_minor: order.get("amount_minor"), currency: order.get("currency"), plan: "pro", duration_days: 0, max_devices: order.get("max_devices") }) } }
}
function portal(app, userId) {
  const row = rows(app, userId, "", {}, 1)[0]
  if (!row) throw Error("No subscription account")
  const order = app.findRecordById("checkout_orders", row.get("order"))
  if (order.get("user") !== userId) throw Error("Billing ownership mismatch")
  const client = new (payments().StripeClient)(app), configuration = order.get("portal_configuration_id")
  verifyPortalConfiguration(client, configuration, row.get("livemode"))
  const origin = order.get("web_origin") || "https://macmint.co"
  if (payments().webOrigin(origin, row.get("livemode")) !== origin) throw Error("Invalid return origin")
  const session = client.send("POST", "billing_portal/sessions", { customer: row.get("customer_id"), configuration, return_url: origin + "/account?billing=returned" })
  if (id(session.customer) !== row.get("customer_id") || !/^https:\/\/billing\.stripe\.com\//.test(session.url || "")) throw Error("Invalid billing portal")
  return session.url
}
function verifyPortalConfiguration(client, configuration, livemode) {
  if (!/^bpc_[A-Za-z0-9]+$/.test(configuration || "")) throw Error("Billing portal is not configured")
  const cfg = client.send("GET", "billing_portal/configurations/" + encodeURIComponent(configuration))
  if (!cfg.active || cfg.id !== configuration || cfg.livemode !== livemode || !cfg.features ||
      !cfg.features.subscription_cancel || !cfg.features.subscription_cancel.enabled || cfg.features.subscription_cancel.mode !== "at_period_end" ||
      !cfg.features.payment_method_update || !cfg.features.payment_method_update.enabled ||
      (cfg.features.subscription_update && cfg.features.subscription_update.enabled)) throw Error("Billing portal configuration needs attention")
}
module.exports = { trialUsed, hasOngoing, canRepurchase, customer, access, sync, fulfill, event, summary, portal, paidPeriod, verifyPortalConfiguration }
