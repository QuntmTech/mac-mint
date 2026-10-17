const { test } = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const path = require('node:path')
global.__hooks = path.resolve(__dirname, '../pocketbase/pb_hooks')
global.$security = {
  hs256: (raw, secret) => crypto.createHmac('sha256', secret).update(raw).digest('hex'),
  equal: (a, b) => a.length === b.length && crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b)),
  randomStringWithAlphabet: n => 'A'.repeat(n),
}
global.$os = { getenv: () => '' }
global.toString = value => String(value)
class Row {
  constructor(collection) { this.collection = collection; this.values = {}; this.id = '' }
  set(k, v) { this.values[k] = v }
  get(k) { return this.values[k] }
}
global.Record = Row
const payments = require('../pocketbase/pb_hooks/macmint_payments_lib.js')
function fixture() {
  const rows = [], order = new Row('checkout_orders')
  order.id = 'order1'
  Object.entries({ user: 'user1', price_id: 'price_test', amount_minor: 1900, currency: 'usd', livemode: false,
    plan: 'pro', duration_days: 365, max_devices: 3, request_key: 'stable-request', customer_email: 'fixture@example.invalid', state: 'pending', session_id: 'cs_test_fixture', created: new Date().toISOString() }).forEach(([k, v]) => order.set(k, v))
  rows.push(order)
  const app = {
    findRecordById(collection, id) { const r = rows.find(r => r.collection === collection && r.id === id); if (!r) throw Error('missing'); return r },
    findFirstRecordByFilter(collection, filter, args = {}) {
      if (collection === 'app_config') { const r = new Row(collection); r.set('value', JSON.stringify({ enabled: true, ...order.values })); return r }
      if (collection === 'app_releases') return new Row(collection)
      if (collection === 'app_secrets') { const r = new Row(collection); r.set('value', 'fixture-only'); return r }
      const r = rows.find(r => r.collection === collection && (!args.u || r.get('user') === args.u) && (!args.k || r.get('request_key') === args.k)); if (!r) throw Error('missing'); return r
    },
    findRecordsByFilter: (collection, filter, sort, limit, offset, args) => rows.filter(r => r.collection === collection && r.get('user') === args.u && ['created', 'pending'].includes(r.get('state'))).slice(0, limit),
    findCollectionByNameOrId: name => name,
    save(r) { if (!r.id) { r.id = 'row' + rows.length; r.set('created', new Date().toISOString()); rows.push(r) } },
    runInTransaction(fn) { fn(this) },
  }
  const session = { id: 'cs_test_fixture', metadata: { macmint_order: order.id }, mode: 'payment', payment_status: 'paid',
    status: 'open', expires_at: Math.floor(Date.now() / 1000) + 3600, url: 'https://checkout.stripe.com/c/pay/fixture',
    client_reference_id: 'user1', amount_total: 1900, currency: 'usd', livemode: false,
    line_items: { has_more: false, data: [{ quantity: 1, price: { id: 'price_test' } }] } }
  global.$http = { send: () => ({ statusCode: 200, json: session }) }
  return { app, rows, order, session }
}
test('webhook signature validates raw bytes, rejects replay, tampering and malformed signatures', () => {
  const raw = '{"data":"fixture"}', timestamp = 1000, secret = 'fixture-signing-secret'
  const header = 't=1000,v1=' + $security.hs256(timestamp + '.' + raw, secret)
  assert.equal(payments.verifySignature(raw, header, secret, 1001), true)
  assert.equal(payments.verifySignature(raw + ' ', header, secret, 1001), false)
  assert.equal(payments.verifySignature(raw, header, secret, 1301), false)
  assert.equal(payments.verifySignature(raw, header, secret, 699), false)
  assert.equal(payments.verifySignature(raw, header + ',t=1000', secret, 1001), false)
  assert.equal(payments.verifySignature(raw, header, '', 1001), false)
})
test('unpaid completed sessions grant nothing; delayed success grants exactly once', () => {
  const f = fixture(); f.session.payment_status = 'unpaid'
  assert.equal(payments.fulfill(f.app, { id: f.session.id }), false)
  assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 0)
  f.session.payment_status = 'paid'
  assert.equal(payments.fulfill(f.app, { id: f.session.id }), true)
  const expiry = f.rows.find(r => r.collection === 'plan_entitlements').get('expires_at')
  payments.fulfill(f.app, { id: f.session.id })
  assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 1)
  assert.equal(f.rows.find(r => r.collection === 'plan_entitlements').get('expires_at'), expiry)
  assert.equal(f.order.get('state'), 'fulfilled')
})
test('fulfillment retrieves authoritative state and rejects amount, user, mode, currency and price mismatches', () => {
  for (const [key, value] of [['amount_total', 1], ['client_reference_id', 'attacker'], ['currency', 'eur'], ['livemode', true], ['mode', 'subscription']]) {
    const f = fixture(); f.session[key] = value
    assert.throws(() => payments.fulfill(f.app, { id: f.session.id }))
    assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 0)
  }
  const f = fixture(); f.session.line_items.data[0].price.id = 'price_other'
  assert.throws(() => payments.fulfill(f.app, { id: f.session.id }))
})

test('retries retrieve the recorded open session without creating another checkout', () => {
  const f = fixture(); f.session.payment_status = 'unpaid'; f.order.set('customer_email', '') // pre-snapshot bound order
  const requests = []
  global.$http = { send: req => { requests.push(req); return { statusCode: 200, json: f.session } } }
  const user = { id: 'user1', get: () => 'fixture@example.invalid' }
  assert.equal(payments.checkout(f.app, user, 'stable-request'), f.session.url)
  assert.equal(requests.length, 1)
  assert.equal(requests[0].method, 'GET')
  assert.ok(requests[0].url.endsWith('/checkout/sessions/cs_test_fixture'))
  f.session.status = 'expired'
  assert.throws(() => payments.checkout(f.app, user, 'stable-request'), e => e.code === 'checkout_expired')
  f.session.status = 'complete'
  assert.throws(() => payments.checkout(f.app, user, 'stable-request'), e => e.code === 'checkout_complete')
  assert.ok(requests.every(r => r.method === 'GET'))
})

test('fulfilled and old unbound orders never POST a new session after the retention window', () => {
  const f = fixture(), user = { id: 'user1', get: () => 'fixture@example.invalid' }
  let calls = 0
  global.$http = { send: () => { calls++; throw Error('Must not call provider') } }
  f.order.set('state', 'fulfilled')
  assert.throws(() => payments.checkout(f.app, user, 'stable-request'), e => e.code === 'checkout_complete')
  f.order.set('state', 'created'); f.order.set('session_id', '')
  for (const created of [new Date(Date.now() - 24 * 3600000).toISOString(), '', 'invalid timestamp']) {
    f.order.set('created', created)
    assert.throws(() => payments.checkout(f.app, user, 'stable-request'), e => e.code === 'checkout_attention')
    assert.equal(f.order.get('state'), 'created') // uncertainty is not a confirmed expiry
  }
  assert.equal(calls, 0)
})

test('inconsistent lifetime and duration configuration closes checkout', () => {
  const f = fixture(); f.order.set('plan', 'lifetime')
  assert.equal(payments.configuration(f.app), null)
  f.order.set('duration_days', 0)
  assert.equal(payments.configuration(f.app).plan, 'lifetime')
})


test('lost checkout response keeps the original email and identical idempotent parameters after account changes', () => {
  const f = fixture(), requests = []
  f.order.set('session_id', ''); f.order.set('state', 'created')
  f.session.payment_status = 'unpaid'
  f.order.set('web_origin', 'https://original.macmint.test')
  let email = 'fixture@example.invalid', first = true, configuredOrigin = 'https://original.macmint.test'
  const originalFind = f.app.findFirstRecordByFilter
  f.app.findFirstRecordByFilter = (collection, ...args) => {
    if (collection === 'app_config') { const row = new Row(collection); row.set('value', JSON.stringify({ enabled: true, ...f.order.values, web_origin: configuredOrigin })); return row }
    return originalFind(collection, ...args)
  }
  const user = { id: 'user1', get: () => email }
  global.$http = { send: req => {
    if (req.url.includes('/prices/')) return { statusCode: 200, json: { active: true, type: 'one_time', unit_amount: 1900, currency: 'usd', livemode: false } }
    requests.push(req)
    if (first) { first = false; throw Error('Response lost after provider accepted request') }
    return { statusCode: 200, json: f.session }
  } }
  assert.throws(() => payments.checkout(f.app, user, 'stable-request'))
  email = 'changed@example.invalid'; configuredOrigin = 'https://new.macmint.test'
  assert.equal(payments.checkout(f.app, user, 'stable-request'), f.session.url)
  assert.equal(requests.length, 2)
  assert.equal(requests[0].body, requests[1].body)
  assert.equal(requests[0].headers['Idempotency-Key'], requests[1].headers['Idempotency-Key'])
  assert.equal(new URLSearchParams(requests[1].body).get('customer_email'), 'fixture@example.invalid')
  assert.equal(new URLSearchParams(requests[1].body).get('success_url'), 'https://original.macmint.test/account?checkout=processing')
  assert.equal(new URLSearchParams(requests[1].body).get('cancel_url'), 'https://original.macmint.test/account?checkout=cancelled')
})

test('new orders freeze email; legacy unknown-session orders cannot invent a new request snapshot', () => {
  const f = fixture(), user = { id: 'user1', get: () => 'original@example.invalid' }
  f.order.set('state', 'fulfilled')
  const order = payments.orderForRequest(f.app, user, 'new-request', { ...payments.configuration(f.app), web_origin: 'https://STAGING.macmint.test:443' })
  assert.equal(order.get('customer_email'), 'original@example.invalid')
  assert.equal(order.get('web_origin'), 'https://staging.macmint.test')
  f.order.set('state', 'created'); f.order.set('session_id', ''); f.order.set('customer_email', '')
  let calls = 0; global.$http = { send: () => { calls++; throw Error('No provider call permitted') } }
  assert.throws(() => payments.checkout(f.app, user, 'stable-request'), error => error.code === 'checkout_attention')
  assert.equal(calls, 0)
})

test('late create responses preserve terminal order states instead of reopening checkout', () => {
  for (const terminal of ['failed', 'expired', 'fulfilled']) {
    const f = fixture(), user = { id: 'user1', get: () => 'fixture@example.invalid' }
    f.order.set('session_id', ''); f.order.set('state', 'created'); f.session.payment_status = 'unpaid'
    global.$http = { send: req => {
      if (req.url.includes('/prices/')) return { statusCode: 200, json: { active: true, type: 'one_time', unit_amount: 1900, currency: 'usd', livemode: false } }
      f.order.set('state', terminal)
      return { statusCode: 200, json: f.session }
    } }
    assert.throws(() => payments.checkout(f.app, user, 'stable-request'))
    assert.equal(f.order.get('state'), terminal)
  }
})

test('status is owner scoped, database only, and permits a replacement only after durable failure or expiry', () => {
  const f = fixture(), user = { id: 'user1' }
  global.$http = { send: () => { throw Error('Status must not call Stripe') } }
  assert.deepEqual(payments.checkoutStatus(f.app, { id: 'user2' }, 'stable-request'), { state: 'not_found', can_start_new: false })
  assert.deepEqual(payments.checkoutStatus(f.app, user, 'missing-request'), { state: 'not_found', can_start_new: false })
  for (const state of ['created', 'pending', 'fulfilled', 'failed', 'expired']) {
    f.order.set('state', state)
    assert.deepEqual(payments.checkoutStatus(f.app, user, 'stable-request'), { state, can_start_new: ['failed', 'expired'].includes(state),
      offer: { amount_minor: 1900, currency: 'usd', plan: 'pro', duration_days: 365, max_devices: 3 } })
  }
})

test('terminal events verify provider identity and preserve paid fulfillment under duplicates and reordered delivery', () => {
  const f = fixture(); f.session.payment_status = 'unpaid'; f.session.status = 'open'
  assert.equal(payments.recordTerminalSession(f.app, { id: f.session.id }, 'expired'), false)
  assert.equal(f.order.get('state'), 'pending')
  f.session.status = 'expired'
  assert.equal(payments.recordTerminalSession(f.app, { id: f.session.id }, 'expired'), true)
  assert.equal(f.order.get('state'), 'expired')
  assert.equal(payments.recordTerminalSession(f.app, { id: f.session.id }, 'expired'), true)
  f.session.status = 'complete'
  assert.equal(payments.recordTerminalSession(f.app, { id: f.session.id }, 'failed'), true)
  assert.equal(f.order.get('state'), 'failed')
  f.session.payment_status = 'paid'
  assert.equal(payments.recordTerminalSession(f.app, { id: f.session.id }, 'failed'), true)
  payments.recordTerminalSession(f.app, { id: f.session.id }, 'expired')
  assert.equal(f.order.get('state'), 'fulfilled')
  assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 1)
  f.session.payment_status = 'unpaid'; f.session.status = 'expired'
  payments.recordTerminalSession(f.app, { id: f.session.id }, 'expired')
  assert.equal(f.order.get('state'), 'fulfilled')
})

test('terminal updates and fulfillment reject mismatched retrieved session IDs and order details', () => {
  for (const mutation of [f => { f.session.id = 'cs_other' }, f => { f.session.client_reference_id = 'user2' },
    f => { f.session.line_items.data[0].price.id = 'price_other' }]) {
    const f = fixture(); f.session.payment_status = 'unpaid'; f.session.status = 'expired'
    const originalId = f.session.id; mutation(f)
    assert.throws(() => payments.recordTerminalSession(f.app, { id: originalId }, 'expired'))
    assert.equal(f.order.get('state'), 'pending')
    assert.equal(f.rows.filter(r => r.collection === 'licenses').length, 0)
  }
})

test('configuration rejects malformed and unsafe values while readiness reports names without leaking data', () => {
  const f = fixture(), cfg = JSON.parse(f.app.findFirstRecordByFilter('app_config').get('value'))
  assert.equal(payments.validConfiguration(cfg), true)
  for (const value of [null, [], true, 'config', { ...cfg, amount_minor: Number.MAX_SAFE_INTEGER + 1 },
    { ...cfg, amount_minor: 100000000 }, { ...cfg, amount_minor: 1.5 },
    { ...cfg, duration_days: Number.MAX_SAFE_INTEGER }, { ...cfg, max_devices: 101 },
    { ...cfg, currency: ['usd'] }, { ...cfg, enabled: 'true' }, { ...cfg, plan: 'subscription' }]) {
    assert.equal(payments.validConfiguration(value), false)
  }
  const original = f.app.findFirstRecordByFilter
  f.app.findFirstRecordByFilter = (collection, ...args) => {
    if (collection === 'app_config') { const row = new Row(collection); row.set('value', JSON.stringify({ ...cfg, amount_minor: 2900, duration_days: 730 })); return row }
    return original(collection, ...args)
  }
  const saved = payments.checkoutStatus(f.app, { id: 'user1' }, 'stable-request')
  assert.equal(saved.offer.amount_minor, 1900)
  assert.equal(saved.offer.duration_days, 365)
  assert.deepEqual(Object.keys(saved.offer).sort(), ['amount_minor', 'currency', 'duration_days', 'max_devices', 'plan'])
  f.app.findFirstRecordByFilter = (collection, ...args) => {
    if (collection === 'app_secrets' || collection === 'app_releases') throw Error('Missing fixture')
    if (collection === 'app_config') { const row = new Row(collection); row.set('value', JSON.stringify({ ...cfg, enabled: false })); return row }
    return original(collection, ...args)
  }
  const result = payments.readiness(f.app)
  assert.equal(result.ready, false)
  assert.deepEqual(result.reasons, ['commerce_disabled', 'stripe_key_missing', 'webhook_secret_missing', 'validated_release_missing'])
  assert.equal(payments.configuration(f.app), null)
})


test('new request identities resume a single owner checkout and fail closed for ambiguous legacy attempts', () => {
  const f = fixture(), key = '11111111-1111-4111-8111-111111111111'
  f.order.set('request_key', key)
  assert.throws(() => payments.orderForRequest(f.app, { id: 'user1' }, 'other-key', payments.configuration(f.app)),
    error => error.code === 'checkout_in_progress' && error.request_key === key)
  const second = new Row('checkout_orders'); second.id = 'other-order'; second.set('user', 'user1'); second.set('state', 'created')
  second.set('request_key', '22222222-2222-4222-8222-222222222222'); f.rows.push(second)
  assert.throws(() => payments.orderForRequest(f.app, { id: 'user1' }, 'other-key', payments.configuration(f.app)),
    error => error.code === 'checkout_attention' && !error.request_key)
  const ownedByOther = payments.orderForRequest(f.app, { id: 'user2', get: () => 'other@example.invalid' }, key, payments.configuration(f.app))
  assert.equal(ownedByOther.get('user'), 'user2')
  assert.equal(ownedByOther.get('customer_email'), 'other@example.invalid')
})


test('server web origin is strict, sandbox loopback only, and independent from browser-supplied URLs', () => {
  assert.equal(payments.webOrigin(undefined, true), 'https://macmint.co')
  assert.equal(payments.webOrigin('https://STAGE.macmint.test:443', false), 'https://stage.macmint.test')
  assert.equal(payments.webOrigin('http://localhost:5173', false), 'http://localhost:5173')
  assert.equal(payments.webOrigin('http://127.0.0.1:5173', false), 'http://127.0.0.1:5173')
  for (const value of [null, '', 'https://good.test/', 'https://good.test/path', 'https://user@good.test',
    'https://good.test?return=bad', 'https://good.test#hash', 'https://good.test:65536', 'https://good.test:0',
    'https://good..test', 'https://-good.test', ' https://good.test', 'https://good.test\\@bad.test', 'javascript:alert(1)',
    'http://example.test', 'http://localhost.evil.test', 'http://127.0.0.2']) {
    assert.equal(payments.webOrigin(value, false), null, String(value))
  }
  for (const value of ['http://localhost:5173', 'http://127.0.0.1:5173']) {
    assert.equal(payments.webOrigin(value, true), null)
    assert.equal(payments.webOrigin(value), null)
  }
  const cfg = JSON.parse(fixture().app.findFirstRecordByFilter('app_config').get('value'))
  assert.equal(payments.validConfiguration({ ...cfg, web_origin: 'http://localhost:5173' }), true)
  assert.equal(payments.validConfiguration({ ...cfg, livemode: true, web_origin: 'http://localhost:5173' }), false)
  assert.equal(payments.validConfiguration({ ...cfg, web_origin: 'https://good.test/path' }), false)
})
