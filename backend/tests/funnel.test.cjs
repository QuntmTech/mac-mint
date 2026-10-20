const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
global.__hooks = path.resolve(__dirname, '../pocketbase/pb_hooks')
global.$os = { getenv: () => '' }
global.$security = { randomString: n => 'R'.repeat(n) }
global.toString = String
class Row {
  constructor(collection, values = {}) { this.collection = collection; this.values = { ...values }; this.id = values.id || '' }
  get(key) { return this.values[key] }
  set(key, value) { this.values[key] = value }
}
global.Record = Row
const payments = require('../pocketbase/pb_hooks/macmint_payments_lib.js')
const funnel = require('../pocketbase/pb_hooks/macmint_funnel.js')
const download = require('../pocketbase/pb_hooks/macmint_download.js')

const tiers = () => [
  { tier: 'mac1', devices: 1, payment_link_id: 'plink_one', url: 'https://buy.stripe.com/test_one111', price_id: 'price_one', amount_minor: 3995, currency: 'usd', trial_days: 7 },
  { tier: 'mac2', devices: 2, payment_link_id: 'plink_two', url: 'https://buy.stripe.com/test_two222', price_id: 'price_two', amount_minor: 5995, currency: 'usd', trial_days: 7 },
  { tier: 'mac5', devices: 5, payment_link_id: 'plink_five', url: 'https://buy.stripe.com/test_five55', price_id: 'price_five', amount_minor: 9995, currency: 'usd', trial_days: 7 },
]
const config = (extra = {}) => ({ enabled: true, livemode: false, web_origin: 'https://staging.macmint.test', billing_mode: 'subscription',
  price_id: 'price_one', amount_minor: 3995, currency: 'usd', plan: 'pro', duration_days: 0, billing_interval: 'year', billing_interval_count: 1,
  trial_days: 7, max_devices: 1, portal_configuration_id: 'bpc_fixture', tiers: tiers(), ...extra })

function session(extra = {}) {
  const price = { id: 'price_two', unit_amount: 5995, currency: 'usd', livemode: false, recurring: { interval: 'year', interval_count: 1, usage_type: 'licensed' } }
  return { id: 'cs_test_fixture123', payment_link: 'plink_two', mode: 'subscription', status: 'complete', livemode: false, currency: 'usd',
    amount_total: 0, subscription: 'sub_fixture', customer: 'cus_fixture', client_reference_id: 'mmt_reference',
    customer_details: { email: 'Buyer@Example.invalid' }, line_items: { has_more: false, data: [{ quantity: 1, price }] }, ...extra }
}

// A small in-memory PocketBase for eligibility and plan checks.
function app(cfg, { users = [], claims = [], subscriptions = [], entitlements = [] } = {}) {
  const rows = [...users.map(u => new Row('users', u)), ...claims.map(c => new Row('purchase_claims', c)),
    ...subscriptions.map(s => new Row('billing_subscriptions', s)), ...entitlements.map(e => new Row('plan_entitlements', e))]
  return {
    findFirstRecordByFilter(collection, filter, args = {}) {
      if (collection === 'app_config') return new Row(collection, { value: JSON.stringify(cfg) })
      if (collection === 'app_releases') return new Row(collection)
      if (collection === 'app_secrets') return new Row(collection, { value: 'fixture-only' })
      const row = rows.find(r => r.collection === collection && (!args.u || r.get('user') === args.u))
      if (!row) throw Error('missing'); return row
    },
    findRecordsByFilter(collection, filter, sort, limit, offset, args = {}) {
      return rows.filter(r => r.collection === collection &&
        (args.e === undefined || String(r.get(collection === 'users' ? 'email' : 'billing_email')).toLowerCase() === args.e) &&
        (args.u === undefined || r.get('user') === args.u) &&
        (args.s === undefined || r.get('session_id') !== args.s) &&
        (!filter.includes('trial_days > 0') || r.get('trial_days') > 0) &&
        (!filter.includes('terminal = false') || !r.get('terminal'))).slice(0, limit)
    },
    findCollectionByNameOrId: name => name,
    save(row) { if (!row.id) { row.id = 'row' + rows.length; rows.push(row) } },
    runInTransaction(fn) { return fn(this) },
  }
}

test('tier configuration requires distinct Stripe-hosted links, prices and device counts for the configured mode', () => {
  assert.equal(payments.validConfiguration(config()), true)
  assert.equal(payments.validConfiguration(config({ tiers: undefined })), true, 'Tiers are optional for the signed-in offer')
  const broken = [
    tiers => { tiers[1].devices = 1 },
    tiers => { tiers[1].payment_link_id = 'plink_one' },
    tiers => { tiers[2].price_id = 'price_one' },
    tiers => { tiers[0].url = 'https://evil.example/test_one111' },
    tiers => { tiers[0].url = 'https://buy.stripe.com/one111' },
    tiers => { tiers[0].url = 'https://buy.stripe.com/test_one111?prefilled_email=x' },
    tiers => { tiers[0].payment_link_id = 'link_one' },
    tiers => { tiers[0].trial_days = 31 },
    tiers => { tiers[0].amount_minor = 0 },
    tiers => { tiers[0].amount_minor = 39.95 },
    tiers => { tiers[0].currency = 'USD' },
    tiers => { tiers[0].billing_interval = 'week' },
    tiers => { tiers[0].tier = 'One Mac' },
    tiers => { tiers.length = 0 },
  ]
  for (const mutate of broken) {
    const value = tiers(); mutate(value)
    assert.equal(payments.validConfiguration(config({ tiers: value })), false, JSON.stringify(value))
  }
  assert.equal(payments.validConfiguration(config({ tiers: {} })), false)
  const live = tiers().map(tier => ({ ...tier, url: tier.url.replace('test_', '') }))
  assert.equal(payments.validConfiguration(config({ livemode: true, tiers: live })), true)
  assert.equal(payments.validConfiguration(config({ livemode: true })), false, 'Test links cannot be used in live mode')
  const oneTime = { enabled: true, livemode: false, price_id: 'price_one', amount_minor: 3995, currency: 'usd', plan: 'pro', duration_days: 365, max_devices: 1 }
  assert.equal(payments.validConfiguration({ ...oneTime, tiers: tiers() }), false, 'Tiers are subscription offers')
})

test('the shipped template carries the approved annual tiers but stays disabled and unbound', () => {
  const template = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../commerce.subscription.example.json'), 'utf8'))
  assert.equal(template.enabled, false)
  assert.deepEqual(template.tiers.map(t => [t.devices, t.amount_minor, t.currency, t.trial_days]), [[1, 3995, 'usd', 7], [2, 5995, 'usd', 7], [5, 9995, 'usd', 7]])
  assert.equal(payments.validConfiguration(template), false)
  const bound = { ...template, enabled: true, price_id: 'price_one', portal_configuration_id: 'bpc_fixture', tiers: template.tiers.map((t, i) => ({ ...t, ...tiers()[i] })) }
  assert.equal(payments.validConfiguration(bound), true)
})

test('public plans expose only display terms, never links or Price IDs', () => {
  const plans = funnel.publicPlans(config())
  assert.deepEqual(plans.tiers.map(t => [t.tier, t.devices, t.amount_minor, t.trial_days, t.billing_interval]),
    [['mac1', 1, 3995, 7, 'year'], ['mac2', 2, 5995, 7, 'year'], ['mac5', 5, 9995, 7, 'year']])
  assert.ok(!JSON.stringify(plans).includes('plink_') && !JSON.stringify(plans).includes('price_') && !JSON.stringify(plans).includes('buy.stripe.com'))
  assert.deepEqual(funnel.plans(app({ ...config(), enabled: false })), { enabled: false })
})

test('the trial link carries the tier link, prefilled email and an opaque reference only', () => {
  const tier = tiers()[1]
  const url = new URL(funnel.paymentLinkURL(tier, 'a+b@example.invalid', 'mmt_ref-1'))
  assert.equal(url.origin + url.pathname, 'https://buy.stripe.com/test_two222')
  assert.equal(url.searchParams.get('prefilled_email'), 'a+b@example.invalid')
  assert.equal(url.searchParams.get('client_reference_id'), 'mmt_ref-1')
  assert.deepEqual([...url.searchParams.keys()], ['prefilled_email', 'client_reference_id'])
  assert.throws(() => funnel.paymentLinkURL(tier, 'a@example.invalid', 'bad ref&x=1'))

  const started = funnel.start(app(config()), { email: ' New@Example.invalid ', tier: 'mac5' })
  const link = new URL(started.url)
  assert.equal(link.pathname, '/test_five55')
  assert.equal(link.searchParams.get('prefilled_email'), 'new@example.invalid')
  assert.match(link.searchParams.get('client_reference_id'), /^mmt_[A-Za-z0-9]{24}$/)
  for (const input of [{ email: 'not-an-email', tier: 'mac1' }, { email: 'a@example.invalid', tier: 'mac3' }, { email: 'a@example.invalid', tier: 'plink_one' }]) {
    assert.throws(() => funnel.start(app(config()), input), error => error.code === 'bad_request')
  }
  assert.throws(() => funnel.start(app({ ...config(), enabled: false }), { email: 'a@example.invalid', tier: 'mac1' }), error => error.code === 'closed')
})

test('one trial per email: earlier trials, used account trials and active plans are refused before redirect', () => {
  const user = { id: 'user1', email: 'Owner@Example.invalid' }
  const used = app(config(), { users: [user], entitlements: [{ user: 'user1', plan: 'free', status: 'active', subscription_trial_used: true }] })
  assert.throws(() => funnel.start(used, { email: 'owner@example.invalid', tier: 'mac1' }), error => error.code === 'trial_used')
  const active = app(config(), { users: [user], entitlements: [{ user: 'user1', plan: 'pro', status: 'active', max_devices: 3, expires_at: '' }] })
  assert.throws(() => funnel.start(active, { email: 'owner@example.invalid', tier: 'mac1' }), error => error.code === 'active_plan')
  const fresh = app(config(), { users: [user], entitlements: [{ user: 'user1', plan: 'free', status: 'active' }] })
  assert.ok(funnel.start(fresh, { email: 'owner@example.invalid', tier: 'mac1' }).url, 'An existing account without a trial may start one')
  const earlier = app(config(), { claims: [{ billing_email: 'guest@example.invalid', session_id: 'cs_test_earlier', trial_days: 7 }] })
  assert.throws(() => funnel.start(earlier, { email: 'GUEST@example.invalid', tier: 'mac2' }), error => error.code === 'trial_used')
  assert.equal(funnel.eligibility(earlier, 'guest@example.invalid', 'cs_test_earlier'), 'eligible', 'A session never conflicts with itself')
})

test('webhook sessions are accepted only for a configured link with exactly that tier\'s terms', () => {
  const accepted = funnel.classifySession(config(), session())
  assert.equal(accepted.result, 'accepted')
  assert.equal(accepted.tier.tier, 'mac2')
  assert.equal(accepted.email, 'buyer@example.invalid')
  assert.equal(accepted.reference, 'mmt_reference')
  assert.equal(funnel.classifySession(config(), session({ payment_link: 'plink_someone_else' })).result, 'ignored')
  assert.equal(funnel.classifySession(config(), session({ payment_link: { id: 'plink_two' } })).result, 'accepted')
  assert.equal(funnel.classifySession(config(), session({ status: 'open' })).result, 'pending')
  const price = (patch) => { const value = session(); Object.assign(value.line_items.data[0].price, patch); return value }
  const mismatches = [
    session({ livemode: true }), session({ mode: 'payment' }), session({ currency: 'eur' }), session({ amount_total: 5995 }),
    session({ subscription: null }), session({ customer: 'not-a-customer' }), session({ customer_details: {}, customer_email: null }),
    session({ line_items: { has_more: true, data: session().line_items.data } }), session({ line_items: { has_more: false, data: [] } }),
    price({ id: 'price_one' }), price({ unit_amount: 100 }), price({ currency: 'eur' }), price({ livemode: true }),
    price({ recurring: { interval: 'month', interval_count: 1, usage_type: 'licensed' } }),
    price({ recurring: { interval: 'year', interval_count: 2, usage_type: 'licensed' } }),
    price({ recurring: { interval: 'year', interval_count: 1, usage_type: 'metered' } }),
  ]
  const quantity = session(); quantity.line_items.data[0].quantity = 2; mismatches.push(quantity)
  for (const value of mismatches) assert.equal(funnel.classifySession(config(), value).result, 'mismatch', JSON.stringify(value))
  const noTrial = config({ tiers: tiers().map(t => ({ ...t, trial_days: 0 })) })
  assert.equal(funnel.classifySession(noTrial, session()).result, 'mismatch', 'A zero total needs a configured trial')
  assert.equal(funnel.classifySession(noTrial, session({ amount_total: 5995 })).result, 'accepted')
  assert.equal(funnel.classifySession(config(), session({ client_reference_id: 'has spaces' })).reference, '')
})

test('claims are single use, expire, never take over existing accounts and need a bound subscription', () => {
  const now = Date.parse('2026-10-20T00:00:00Z')
  const claim = (patch = {}) => ({ state: 'pending', order: '', subscription_id: 'sub_fixture', customer_id: 'cus_fixture',
    expires_at: new Date(now + funnel.CLAIM_MILLIS).toISOString(), ...patch })
  assert.equal(funnel.claimDecision(claim(), now), 'claimable')
  assert.equal(funnel.claimDecision(claim({ state: 'claimed', order: 'order1' }), now), 'already_claimed')
  assert.equal(funnel.claimDecision(claim({ state: 'linked', order: 'order1' }), now), 'existing_account')
  assert.equal(funnel.claimDecision(claim({ expires_at: new Date(now).toISOString() }), now), 'expired')
  assert.equal(funnel.claimDecision(claim({ expires_at: '2026-10-19 23:59:59.000Z' }), now), 'expired')
  assert.equal(funnel.claimDecision(claim({ expires_at: 'not a date' }), now), 'expired')
  assert.equal(funnel.claimDecision(claim({ subscription_id: '' }), now), 'attention', 'An unbound purchase is not claimable')
  assert.equal(funnel.claimDecision(claim({ customer_id: '' }), now), 'attention')
  assert.equal(funnel.claimDecision(claim({ order: 'order1' }), now), 'attention', 'A pending claim with an order is inconsistent')
  assert.equal(funnel.claimDecision(claim({ state: 'attention' }), now), 'attention')
  assert.equal(funnel.CLAIM_MILLIS, 72 * 3600000)
  assert.equal(funnel.validSessionId('cs_test_a1b2c3d4e5'), true)
  for (const value of ['', 'cs_short', 'pi_test_a1b2c3d4e5', 'cs_test_a1b2c3d4e5/../x', 'cs_test_a1b2c3d4e5?x=1']) assert.equal(funnel.validSessionId(value), false)
  assert.equal(funnel.normalizeEmail(' A@B.example '), 'a@b.example')
  for (const value of ['a@b', 'a b@c.example', '<a@b.example>', 'a@b.example,c@d.example', 'x'.repeat(250) + '@b.example']) assert.equal(funnel.normalizeEmail(value), '')
})

test('download source prefers a validated DMG feed and only trusts the project\'s GitHub DMG asset', () => {
  const release = (patch = {}) => ({ tag_name: 'v1.2.0', draft: false, prerelease: false, published_at: '2026-10-19T00:00:00Z',
    assets: [{ name: 'MacMint.zip', browser_download_url: 'https://github.com/QuntmTech/mac-mint/releases/download/v1.2.0/MacMint.zip', size: 9 },
      { name: 'MacMint.dmg', browser_download_url: 'https://github.com/QuntmTech/mac-mint/releases/download/v1.2.0/MacMint.dmg', size: 12345678, digest: 'sha256:' + 'c'.repeat(64) }], ...patch })
  const found = download.fromGitHub(release())
  assert.deepEqual([found.source, found.version, found.size_bytes, found.sha256, found.notarized, found.min_os],
    ['github', '1.2.0', 12345678, 'c'.repeat(64), false, '14.0'])
  assert.equal(download.fromGitHub(release({ prerelease: true })), null)
  assert.equal(download.fromGitHub(release({ draft: true })), null)
  assert.equal(download.fromGitHub(release({ assets: [{ name: 'MacMint.dmg', browser_download_url: 'https://objects.githubusercontent.com/x/MacMint.dmg' }] })), null)
  assert.equal(download.fromGitHub(release({ assets: [{ name: 'MacMint.dmg', browser_download_url: 'https://github.com/Other/mac-mint/releases/download/v1.2.0/MacMint.dmg' }] })), null)
  assert.equal(download.fromGitHub(release({ tag_name: 'v1.3.0' })), null, 'Asset must belong to the reported tag')
  assert.equal(download.fromGitHub(release({ tag_name: '../v1' })), null)
  const feed = values => download.fromFeed(new Row('app_releases', { version: '1.2.0', build: 12, min_os: '14.0', size_bytes: 100, sha256: 'd'.repeat(64), notarized: true,
    download_url: 'https://github.com/QuntmTech/mac-mint/releases/download/v1.2.0/MacMint.dmg', ...values }))
  assert.equal(feed().notarized, true)
  assert.equal(feed({ download_url: 'https://example.com/MacMint.dmg' }), null)
  assert.equal(feed({ download_url: 'https://github.com/QuntmTech/mac-mint/releases/download/v1.2.0/MacMint.zip' }), null)
  assert.equal(feed({ download_url: 'https://macmint.co/downloads/MacMint.dmg' }).url, 'https://macmint.co/downloads/MacMint.dmg')
})

test('purchases attach automatically only to a verified owner of the billing email', () => {
  assert.equal(funnel.ownerDecision(null), 'none')
  assert.equal(funnel.ownerDecision(new Row('users', { verified: true })), 'link')
  assert.equal(funnel.ownerDecision(new Row('users', { verified: false })), 'unverified_owner', 'Anyone can register an unverified account under a victim\'s address')
  assert.equal(funnel.ownerDecision(new Row('users', {})), 'unverified_owner')
})

test('unknown sessions wait for the webhook, then ask Stripe at most once per retry window', () => {
  const now = 1_000_000
  assert.equal(funnel.lookupDecision(undefined, now), 'wait', 'The first sighting only starts the late-webhook timer')
  assert.equal(funnel.lookupDecision({ first: now - 5000, next: now + 5000 }, now), 'wait')
  assert.equal(funnel.lookupDecision({ first: now - 10000, next: now }, now), 'ask')
  assert.equal(funnel.lookupDecision({ first: now - 70000, next: now + 1 }, now), 'wait', 'A cached miss is not retried early')
})
