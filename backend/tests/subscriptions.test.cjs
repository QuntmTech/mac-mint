const { test } = require('node:test')
const assert = require('node:assert/strict')
const path = require('node:path')
global.__hooks = path.resolve(__dirname, '../pocketbase/pb_hooks')
global.$os = { getenv: () => '' }
global.toString = String
class Row {
  constructor(collection) { this.collection = collection; this.values = {}; this.id = '' }
  get(key) { return this.values[key] }
  set(key, value) { this.values[key] = value }
}
global.Record = Row
const payments = require('../pocketbase/pb_hooks/macmint_payments_lib.js')
const billing = require('../pocketbase/pb_hooks/macmint_billing.js')
const lib = require('../pocketbase/pb_hooks/macmint_lib.js')
const copy = value => JSON.parse(JSON.stringify(value))
function fixture() {
  const now = Math.floor(Date.now() / 1000), end = now + 30 * 86400
  const config = { enabled: true, livemode: false, price_id: 'price_fixture', amount_minor: 1900, currency: 'usd',
    plan: 'pro', duration_days: 0, max_devices: 3, billing_mode: 'subscription', billing_interval: 'month',
    billing_interval_count: 1, portal_configuration_id: 'bpc_fixture', web_origin: 'https://staging.macmint.test' }
  const rows = [], order = new Row('checkout_orders'); order.id = 'order1'
  Object.entries({ ...config, user: 'user1', request_key: 'fixture-request', state: 'pending', session_id: 'cs_fixture',
    customer_email: 'buyer@example.invalid', created: new Date().toISOString() }).forEach(([key, value]) => order.set(key, value))
  rows.push(order)
  const price = { id: 'price_fixture', active: true, type: 'recurring', unit_amount: 1900, currency: 'usd', livemode: false,
    recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' } }
  const session = { id: 'cs_fixture', mode: 'subscription', status: 'complete', payment_status: 'paid',
    subscription: 'sub_fixture', customer: 'cus_fixture', client_reference_id: 'user1', metadata: { macmint_order: order.id },
    livemode: false, amount_total: 1900, currency: 'usd', line_items: { has_more: false, data: [{ quantity: 1, price }] } }
  const subscription = { id: 'sub_fixture', customer: 'cus_fixture', status: 'active', livemode: false,
    cancel_at_period_end: false, latest_invoice: 'in_fixture', items: { has_more: false,
      data: [{ quantity: 1, price, current_period_start: now, current_period_end: end }] } }
  const invoice = { id: 'in_fixture', status: 'paid', customer: 'cus_fixture', currency: 'usd', livemode: false,
    parent: { type: 'subscription_details', subscription_details: { subscription: 'sub_fixture' } },
    lines: { has_more: false, data: [{ quantity: 1, pricing: { price_details: { price: 'price_fixture' } }, period: { start: now, end } }] } }
  const portalConfig = { id: 'bpc_fixture', active: true, livemode: false, features: {
    subscription_cancel: { enabled: true, mode: 'at_period_end' }, subscription_update: { enabled: false }, payment_method_update: { enabled: true } } }
  const app = {
    findCollectionByNameOrId: name => name,
    findRecordById(collection, id) { const row = rows.find(row => row.collection === collection && row.id === id); if (!row) throw Error('Not found'); return row },
    findRecordsByFilter(collection, filter, sort, limit, offset, args = {}) {
      return rows.filter(row => row.collection === collection &&
        (!args.u || (filter.includes('user !=') ? row.get('user') !== args.u : row.get('user') === args.u)) &&
        (!args.s || row.get('subscription_id') === args.s) && (!args.c || row.get('customer_id') === args.c) &&
        (args.mode === undefined || row.get('livemode') === args.mode) &&
        (!filter.includes('terminal = false') || !row.get('terminal')) &&
        (!filter.includes("state = 'created'") || ['created', 'pending'].includes(row.get('state')))).slice(0, limit)
    },
    findFirstRecordByFilter(collection, filter, args = {}) {
      if (collection === 'app_config') { const row = new Row(collection); row.set('value', JSON.stringify(config)); return row }
      if (collection === 'app_releases') return new Row(collection)
      if (collection === 'app_secrets') { const row = new Row(collection); row.set('value', 'synthetic-fixture'); return row }
      const row = rows.find(row => row.collection === collection && (!args.u || row.get('user') === args.u) && (!args.k || row.get('request_key') === args.k) && (!args.p || row.get('payment_intent') === args.p))
      if (!row) throw Error('Not found'); return row
    },
    save(row) { if (!row.id) { row.id = 'row' + rows.length; row.set('created', new Date().toISOString()); rows.push(row) } },
    runInTransaction(fn) { return fn(this) },
  }
  const requests = []
  global.$http = { send: request => {
    requests.push(request)
    const url = new URL(request.url), resource = url.pathname.replace('/v1/', '')
    let json
    if (resource.startsWith('checkout/sessions/')) json = session
    else if (resource === 'checkout/sessions' && request.method === 'GET') json = { data: [session], has_more: false }
    else if (resource === 'checkout/sessions') json = { ...session, status: 'open', payment_status: 'unpaid', expires_at: now + 3600, url: 'https://checkout.stripe.com/c/pay/fixture' }
    else if (resource.startsWith('subscriptions/')) json = subscription
    else if (resource.startsWith('invoices/')) json = invoice
    else if (resource.startsWith('prices/')) json = price
    else if (resource.startsWith('billing_portal/configurations/')) json = portalConfig
    else if (resource === 'billing_portal/sessions') json = { customer: 'cus_fixture', url: 'https://billing.stripe.com/p/session/fixture' }
    else throw Error('Unexpected provider resource ' + resource)
    return { statusCode: 200, json: copy(json) }
  } }
  return { app, rows, order, config, session, subscription, invoice, price, portalConfig, requests, end, now }
}
test('recurring offer validation requires explicit recurring terms and a cancellation portal', () => {
  const f = fixture()
  assert.equal(payments.validConfiguration(f.config), true)
  for (const override of [{ billing_interval: 'hour' }, { billing_interval_count: 0 }, { portal_configuration_id: '' }, { duration_days: 365 }, { plan: 'lifetime' }]) {
    assert.equal(payments.validConfiguration({ ...f.config, ...override }), false)
  }
})
test('paid subscription checkout grants its absolute paid period without creating a lifetime license', () => {
  const f = fixture()
  assert.equal(payments.fulfill(f.app, { id: f.session.id }), true)
  assert.equal(f.order.get('state'), 'fulfilled')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, new Date(f.end * 1000).toISOString())
  assert.equal(f.rows.filter(row => row.collection === 'licenses').length, 0)
  for (let i = 0; i < 8; i++) payments.fulfill(f.app, { id: f.session.id })
  assert.equal(f.rows.filter(row => row.collection === 'billing_subscriptions').length, 1)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, new Date(f.end * 1000).toISOString())
})
test('renewals replace a paid-through timestamp and failed renewal never grants the unpaid next period', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  f.subscription.items.data[0].current_period_end += 30 * 86400
  f.invoice.lines.data[0].period.end += 30 * 86400
  f.invoice.status = 'open'; f.subscription.status = 'past_due'
  billing.event(f.app, 'invoice.payment_failed', { id: f.invoice.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, new Date(f.end * 1000).toISOString())
  f.invoice.status = 'paid'; f.subscription.status = 'active'
  billing.event(f.app, 'invoice.paid', { id: f.invoice.id })
  billing.event(f.app, 'invoice.paid', { id: f.invoice.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, new Date((f.end + 30 * 86400) * 1000).toISOString())
})
test('unpaid initial invoices, incomplete subscriptions and unconfigured trials cannot unlock access', () => {
  for (const status of ['incomplete', 'trialing', 'unpaid', 'paused']) {
    const f = fixture(); f.subscription.status = status; f.invoice.status = 'open'
    if (status === 'trialing') assert.throws(() => payments.fulfill(f.app, { id: f.session.id }), /Unconfigured trial/)
    else payments.fulfill(f.app, { id: f.session.id })
    assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
    assert.equal(f.order.get('state'), 'pending')
  }
})
test('canceling renewal retains the paid period; completed cancellation revokes only recurring access', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  f.subscription.cancel_at_period_end = true
  billing.event(f.app, 'customer.subscription.updated', { id: f.subscription.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, true)
  assert.equal(billing.summary(f.app, 'user1').subscription.cancel_at_period_end, true)
  f.subscription.status = 'canceled'
  billing.event(f.app, 'customer.subscription.deleted', { id: f.subscription.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  assert.equal(payments.checkoutStatus(f.app, { id: 'user1' }, 'fixture-request').can_start_new, true)
  const ent = lib.ensureEntitlement(f.app, 'user1'); ent.set('plan', 'pro'); ent.set('expires_at', ''); ent.set('status', 'active'); ent.set('max_devices', 5)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, null)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').max_devices, 5)
})
test('late stale snapshots cannot resurrect a terminal subscription', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  const original = global.$http.send; let nested = false
  global.$http.send = request => {
    const response = original(request)
    if (!nested && request.url.includes('/subscriptions/')) {
      nested = true; f.subscription.status = 'canceled'
      billing.sync(f.app, f.subscription.id)
    }
    return response
  }
  billing.sync(f.app, f.subscription.id)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  f.subscription.status = 'active' // Even a later provider snapshot cannot reverse terminal state.
  billing.sync(f.app, f.subscription.id)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
})
test('an invoice arriving before checkout notification binds through the authoritative Checkout session', () => {
  const f = fixture()
  billing.event(f.app, 'invoice.paid', { id: f.invoice.id, metadata: { macmint_order: 'attacker' } })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, true)
  assert.equal(f.order.get('subscription_id'), f.subscription.id)
})
test('invoice identity, price, customer, mode and service periods are verified before access changes', () => {
  for (const mutate of [f => { f.invoice.customer = 'cus_foreign' }, f => { f.invoice.livemode = true },
    f => { f.invoice.currency = 'eur' }, f => { f.invoice.parent.subscription_details.subscription = 'sub_foreign' },
    f => { f.invoice.lines.data[0].pricing.price_details.price = 'price_foreign' }, f => { f.invoice.lines.has_more = true },
    f => { f.invoice.lines.data[0].period.end = 0 }, f => { f.subscription.items.data[0].quantity = 2 },
    f => { f.subscription.items.data[0].price.recurring.interval = 'year' }]) {
    const f = fixture(); mutate(f)
    assert.throws(() => payments.fulfill(f.app, { id: f.session.id }))
    assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  }
})
test('another product subscription is ignored rather than fulfilled from arbitrary metadata', () => {
  const f = fixture(); delete f.session.metadata.macmint_order
  assert.equal(billing.event(f.app, 'invoice.paid', { id: f.invoice.id }), false)
  assert.equal(f.rows.filter(row => row.collection === 'billing_subscriptions').length, 0)
})
test('billing portal uses only the authenticated owner and still works when new checkout is disabled', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id }); f.config.enabled = false
  assert.equal(billing.portal(f.app, 'user1'), 'https://billing.stripe.com/p/session/fixture')
  const request = f.requests.find(request => request.method === 'POST' && request.url.endsWith('/billing_portal/sessions'))
  assert.equal(new URLSearchParams(request.body).get('customer'), 'cus_fixture')
  assert.equal(new URLSearchParams(request.body).get('return_url'), 'https://staging.macmint.test/account?billing=returned')
  assert.throws(() => billing.portal(f.app, 'other-user'))
  f.portalConfig.features.subscription_update.enabled = true
  assert.throws(() => billing.portal(f.app, 'user1'))
})
test('new subscriptions cannot be opened while another subscription requires payment recovery', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id }); f.subscription.status = 'unpaid'
  billing.sync(f.app, f.subscription.id)
  assert.throws(() => payments.orderForRequest(f.app, { id: 'user1', get: () => 'buyer@example.invalid' }, 'another-request', f.config), error => error.code === 'plan_exists')
})
test('delayed-payment failure arriving before checkout completion cannot open a second subscription', () => {
  const f = fixture(); f.session.payment_status = 'unpaid'; f.subscription.status = 'incomplete'; f.invoice.status = 'open'
  payments.recordTerminalSession(f.app, { id: f.session.id }, 'failed')
  assert.equal(f.order.get('state'), 'pending')
  assert.equal(billing.hasOngoing(f.app, 'user1'), true)
  assert.equal(payments.checkoutStatus(f.app, { id: 'user1' }, 'fixture-request').can_start_new, false)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  f.subscription.status = 'incomplete_expired'
  billing.event(f.app, 'customer.subscription.updated', { id: f.subscription.id })
  assert.equal(f.order.get('state'), 'failed')
  assert.equal(payments.checkoutStatus(f.app, { id: 'user1' }, 'fixture-request').can_start_new, true)
  const uncertain = fixture(); uncertain.session.subscription = null; uncertain.session.payment_status = 'unpaid'
  assert.throws(() => payments.recordTerminalSession(uncertain.app, { id: uncertain.session.id }, 'failed'), /termination is not yet verified/)
  assert.equal(uncertain.order.get('state'), 'pending')
})
test('malformed license expiry cannot turn into unlimited account access', () => {
  const f = fixture(), ent = lib.ensureEntitlement(f.app, 'user1')
  ent.set('plan', 'pro'); ent.set('status', 'active'); ent.set('expires_at', 'malformed')
  assert.equal(lib.entitlementPayload(ent).active, false)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
})
test('revoked and suspended accounts cannot open or resume a payable subscription', () => {
  for (const status of ['revoked', 'suspended']) {
    const f = fixture(), ent = lib.ensureEntitlement(f.app, 'user1')
    ent.set('plan', 'pro'); ent.set('status', status)
    assert.throws(() => payments.checkout(f.app, { id: 'user1', get: () => 'buyer@example.invalid' }, 'fixture-request'),
      error => error.code === 'account_restricted')
    assert.equal(f.requests.length, 0)
  }
})

function trialFixture() {
  const f = fixture()
  Object.assign(f.config, { trial_days: 3, billing_interval: 'year', amount_minor: 3999 })
  for (const key of ['trial_days', 'billing_interval', 'amount_minor']) f.order.set(key, f.config[key])
  Object.assign(f.price, { unit_amount: 3999, recurring: { interval: 'year', interval_count: 1, usage_type: 'licensed' } })
  f.session.amount_total = 0; f.session.payment_status = 'no_payment_required'
  Object.assign(f.subscription, { status: 'trialing', trial_start: f.now, trial_end: f.now + 3 * 86400 })
  f.subscription.items.data[0].current_period_end = f.subscription.trial_end
  f.invoice.lines.data[0].period.end = f.subscription.trial_end
  return f
}
test('approved annual offer grants only three trial days, then requires a verified paid invoice', () => {
  const f = trialFixture()
  assert.equal(payments.validConfiguration(f.config), true)
  payments.fulfill(f.app, { id: f.session.id })
  const row = f.rows.find(row => row.collection === 'billing_subscriptions')
  assert.equal(row.get('paid_through'), undefined)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').source, 'subscription_trial')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, new Date(f.subscription.trial_end * 1000).toISOString())
  assert.equal(payments.offerForUser(f.app, f.config, 'user1').trial_days, 0)
  assert.equal(payments.offerForUser(f.app, f.config, 'new-user').trial_days, 3)
  row.set('trial_through', '2020-01-01T00:00:00Z')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  f.subscription.status = 'past_due'; f.invoice.status = 'open'
  f.subscription.items.data[0].current_period_end = f.now + 365 * 86400
  f.invoice.lines.data[0].period.end = f.now + 365 * 86400
  billing.event(f.app, 'invoice.payment_failed', { id: f.invoice.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  f.subscription.status = 'active'; f.invoice.status = 'paid'
  billing.event(f.app, 'invoice.paid', { id: f.invoice.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').source, 'subscription')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').expires_at, new Date((f.now + 365 * 86400) * 1000).toISOString())
  assert.equal(f.rows.filter(row => row.collection === 'licenses').length, 0)
})
test('trial cancellation cannot reset eligibility and provider trials cannot exceed approved duration', () => {
  const f = trialFixture(); payments.fulfill(f.app, { id: f.session.id })
  f.subscription.status = 'canceled'
  billing.event(f.app, 'customer.subscription.deleted', { id: f.subscription.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  assert.equal(payments.offerForUser(f.app, f.config, 'user1').trial_days, 0)
  const another = trialFixture(); another.subscription.trial_end += 86400
  assert.throws(() => payments.fulfill(another.app, { id: another.session.id }), /Unconfigured trial/)
  assert.equal(lib.effectiveEntitlement(another.app, 'user1').active, false)
  for (const trial_days of [-1, 1.5, 31]) assert.equal(payments.validConfiguration({ ...another.config, trial_days }), false)
})

// Charges and disputes on subscription invoices map through Stripe's InvoicePayment.
function reversalRoutes(f, objects) {
  const base = global.$http.send
  global.$http = { send: request => {
    const url = new URL(request.url), resource = url.pathname.replace('/v1/', '')
    if (resource.startsWith('charges/')) return { statusCode: 200, json: copy(objects.charge) }
    if (resource.startsWith('disputes/')) return { statusCode: 200, json: copy(objects.dispute) }
    if (resource === 'invoice_payments') {
      const intent = url.searchParams.get('payment[payment_intent]')
      assert.equal(url.searchParams.get('payment[type]'), 'payment_intent')
      return { statusCode: 200, json: { data: intent === 'pi_invoice' ? [{ id: 'inpay_fixture', invoice: f.invoice.id, payment: { type: 'payment_intent', payment_intent: intent } }] : [] } }
    }
    if (resource === 'checkout/sessions' && url.searchParams.get('payment_intent')) return { statusCode: 200, json: { data: [] } }
    return base(request)
  } }
}
const refund = (amount, refunded) => ({ id: 'ch_invoice', payment_intent: 'pi_invoice', amount: 1900, amount_refunded: amount, refunded, livemode: false })
const row = f => f.rows.find(r => r.collection === 'billing_subscriptions')

test('a full refund of a subscription invoice holds its access; replays and renewals cannot restore it', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, true)
  reversalRoutes(f, { charge: refund(1900, true) })
  assert.equal(payments.reverse(f.app, 'charge.refunded', { id: 'ch_invoice' }).result, 'held')
  assert.deepEqual([row(f).get('access_hold'), row(f).get('hold_reference'), row(f).get('refunded_minor')], ['refunded', 'ch_invoice', 1900])
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  assert.equal(billing.summary(f.app, 'user1').subscription.access_held, true)
  assert.equal(payments.reverse(f.app, 'charge.refunded', { id: 'ch_invoice' }).result, 'unchanged')
  f.subscription.items.data[0].current_period_end += 30 * 86400; f.invoice.lines.data[0].period.end += 30 * 86400
  billing.event(f.app, 'invoice.paid', { id: f.invoice.id })
  payments.fulfill(f.app, { id: f.session.id })
  assert.equal(row(f).get('access_hold'), 'refunded')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false, 'a renewal must not silently restore access')
  assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 0)
  const released = payments.releaseSubscriptionHold(f.app, { subscription: 'sub_fixture', reason: 'fixture' })
  assert.deepEqual([released.released, released.previous_hold, released.entitlement.active], [true, 'refunded', true])
  assert.equal(payments.releaseSubscriptionHold(f.app, { order: f.order.id }).released, false)
})

test('partial subscription refunds and dispute inquiries are review-only; a chargeback holds access', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  reversalRoutes(f, { charge: refund(500, false) })
  assert.equal(payments.reverse(f.app, 'charge.refunded', { id: 'ch_invoice' }).result, 'review')
  assert.equal(payments.reverse(f.app, 'charge.refunded', { id: 'ch_invoice' }).result, 'unchanged')
  assert.deepEqual([row(f).get('attention'), row(f).get('refunded_minor'), row(f).get('access_hold')], ['partial_refund', 500, undefined])
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, true)
  const dispute = { id: 'dp_invoice', charge: 'ch_invoice', payment_intent: 'pi_invoice', livemode: false, status: 'warning_needs_response' }
  reversalRoutes(f, { dispute })
  assert.equal(payments.reverse(f.app, 'charge.dispute.created', { id: 'dp_invoice' }).result, 'review')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, true)
  dispute.status = 'needs_response'
  assert.equal(payments.reverse(f.app, 'charge.dispute.updated', { id: 'dp_invoice' }).result, 'held')
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  dispute.status = 'won'
  assert.equal(payments.reverse(f.app, 'charge.dispute.updated', { id: 'dp_invoice' }).result, 'ignored')
  assert.equal(row(f).get('access_hold'), 'disputed', 'a won dispute is released by an operator, not automatically')
})

test('reversals of other products are ignored and mismatched invoice ownership fails for retry', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  reversalRoutes(f, { charge: { ...refund(1900, true), payment_intent: 'pi_other' } })
  assert.equal(payments.reverse(f.app, 'charge.refunded', { id: 'ch_invoice' }).result, 'ignored')
  f.invoice.customer = 'cus_attacker'
  reversalRoutes(f, { charge: refund(1900, true) })
  assert.throws(() => payments.reverse(f.app, 'charge.refunded', { id: 'ch_invoice' }), /Subscription invoice mismatch/)
  assert.equal(row(f).get('access_hold'), undefined)
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, true)
})

test('superuser revoke and reconcile handle subscription orders without minting or freeing access', () => {
  const f = fixture(); payments.fulfill(f.app, { id: f.session.id })
  const held = payments.revokeLicense(f.app, { order: f.order.id, reason: 'fixture' })
  assert.deepEqual([held.subscription, held.already_held, held.hold, held.entitlement.active], ['sub_fixture', false, 'operator', false])
  assert.equal(payments.revokeLicense(f.app, { subscription: 'sub_fixture' }).already_held, true)
  const reconciled = payments.reconcileOrder(f.app, { order: f.order.id })
  assert.deepEqual([reconciled.state, reconciled.subscription_status, reconciled.access_held], ['fulfilled', 'active', true])
  assert.equal(lib.effectiveEntitlement(f.app, 'user1').active, false)
  assert.throws(() => payments.revokeLicense(f.app, { subscription: 'sub_unknown' }), e => e.code === 'not_found')
  assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 0)
})

test('refund recompute leaves revoked or suspended account restrictions in place', () => {
  const f = fixture()
  const ent = lib.ensureEntitlement(f.app, 'user1'); ent.set('status', 'revoked'); f.app.save(ent)
  assert.equal(payments.recomputeEntitlement(f.app, 'user1').status, 'revoked')
  assert.ok(f.rows.some(r => r.collection === 'audit_log' && r.get('event') === 'entitlement_review'))
})
