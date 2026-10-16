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
    plan: 'pro', duration_days: 365, max_devices: 3, state: 'pending', session_id: 'cs_test_fixture' }).forEach(([k, v]) => order.set(k, v))
  rows.push(order)
  const app = {
    findRecordById(collection, id) { const r = rows.find(r => r.collection === collection && r.id === id); if (!r) throw Error('missing'); return r },
    findFirstRecordByFilter(collection, filter, args) {
      if (collection === 'app_secrets') { const r = new Row(collection); r.set('value', 'fixture-only'); return r }
      const r = rows.find(r => r.collection === collection && (!args.u || r.get('user') === args.u)); if (!r) throw Error('missing'); return r
    },
    findCollectionByNameOrId: name => name,
    save(r) { if (!r.id) { r.id = 'row' + rows.length; rows.push(r) } },
    runInTransaction(fn) { fn(this) },
  }
  const session = { id: 'cs_test_fixture', metadata: { macmint_order: order.id }, mode: 'payment', payment_status: 'paid',
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
