const { test, beforeEach } = require('node:test')
const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
global.__hooks = path.resolve(__dirname, '../pocketbase/pb_hooks')
global.toString = value => String(value)
let env = {}
global.$os = { getenv: name => env[name] || '' }
const signer = require('../pocketbase/pb_hooks/macmint_entitlement.js')
const nacl = (() => {
  global.self = { crypto: { getRandomValues: () => { throw new Error('no PRNG') } } }
  try { return require('../pocketbase/pb_hooks/macmint_nacl.js') } finally { delete global.self }
})()

// Disposable test keys only. The production seed never enters the repository.
const seed = Buffer.from('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'hex')
const testKey = 'mm-test-1:' + seed.toString('base64')
const activeDevice = 'ABCDEF0123456789'
const pro = { plan: 'pro', status: 'active', active: true, expires_at: null, max_devices: 3, source: 'license' }

function nodePublicKey(raw) {
  return crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(raw)]), format: 'der', type: 'spki' })
}
function split(compact) {
  const [payload, signature] = compact.split('.')
  return { message: Buffer.from(payload, 'base64url'), signature: Buffer.from(signature, 'base64url') }
}
function fakeApp({ secret, client } = {}) {
  const shared = new Map()
  const lookups = []
  return {
    lookups,
    store: () => ({ has: k => shared.has(k), get: k => shared.get(k), set: (k, v) => shared.set(k, v) }),
    findFirstRecordByFilter(collection, filter) {
      lookups.push(collection)
      if (collection === 'app_secrets' && secret !== undefined) return { get: () => secret }
      if (collection === 'app_config' && client !== undefined) return { get: () => JSON.stringify(client) }
      throw new Error('not found')
    },
  }
}
beforeEach(() => { env = {} })

test('the vendored tweetnacl body is byte-for-byte the verified npm 1.0.3 nacl-fast.js', () => {
  const text = fs.readFileSync(path.join(__hooks, 'macmint_nacl.js'), 'utf8')
  const marker = '// ----- BEGIN UPSTREAM tweetnacl 1.0.3 nacl-fast.js -----\n'
  const body = text.slice(text.indexOf(marker) + marker.length)
  assert.ok(text.includes(marker))
  assert.equal(crypto.createHash('sha256').update(body).digest('hex'), '6bcd37a3b20dce913f82d4b23e4e2b661058b4b953df8a3f8c45d56ac4f72447')
})

test('tweetnacl reproduces RFC 8032 test vector 1 without a PRNG', () => {
  const pair = nacl.sign.keyPair.fromSeed(Buffer.from('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', 'hex'))
  assert.equal(Buffer.from(pair.publicKey).toString('hex'), 'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a')
  assert.equal(Buffer.from(nacl.sign.detached(new Uint8Array(0), pair.secretKey)).toString('hex'),
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b')
  assert.throws(() => nacl.randomBytes(1), /no PRNG/)
})

test('canonical JSON sorts keys at every level, has no whitespace and rejects ambiguous values', () => {
  assert.equal(signer.canonicalJSON({ b: 1, a: { d: null, c: [true, 'x'] } }), '{"a":{"c":[true,"x"],"d":null},"b":1}')
  assert.equal(signer.canonicalJSON({ z: 'é"\\' }), JSON.stringify({ z: 'é"\\' }))
  const one = signer.assertionPayload('k', 'u', activeDevice, pro, 1800000000, 14)
  const reordered = Object.fromEntries(Object.entries(one).reverse())
  assert.equal(signer.canonicalJSON(one), signer.canonicalJSON(reordered))
  for (const bad of [1.5, NaN, Infinity, undefined, 2 ** 60, () => 1]) assert.throws(() => signer.canonicalJSON({ bad }))
})

test('base64url and UTF-8 helpers match Node', () => {
  for (const size of [0, 1, 2, 3, 31, 32, 64, 200]) {
    const bytes = crypto.randomBytes(size)
    assert.equal(signer.base64url(bytes), bytes.toString('base64url'))
    assert.deepEqual(Buffer.from(signer.decodeBase64(bytes.toString('base64'))), bytes)
    assert.deepEqual(Buffer.from(signer.decodeBase64(bytes.toString('base64url'))), bytes)
  }
  assert.equal(signer.decodeBase64('a'), null)
  assert.equal(signer.decodeBase64('not base64!'), null)
  for (const text of ['ascii', 'é', '€', '𝄞 surrogate']) assert.deepEqual(Buffer.from(signer.utf8(text)), Buffer.from(text, 'utf8'))
})

test('assertions verify with tweetnacl and with Node crypto, and tampering breaks them', () => {
  const pair = nacl.sign.keyPair.fromSeed(seed)
  const payload = signer.assertionPayload('mm-test-1', 'user1', activeDevice, pro, 1800000000, 14)
  const compact = signer.sign(payload, seed)
  const { message, signature } = split(compact)
  assert.equal(message.toString('utf8'), signer.canonicalJSON(payload))
  assert.deepEqual(JSON.parse(message), { v: 1, kid: 'mm-test-1', user_id: 'user1', device_id: activeDevice, plan: 'pro', active: true,
    expires_at: null, issued_at: 1800000000, offline_until: 1800000000 + 14 * 86400 })
  assert.ok(nacl.sign.detached.verify(message, signature, pair.publicKey))
  assert.ok(crypto.verify(null, message, nodePublicKey(pair.publicKey), signature))
  const forged = Buffer.from(message.toString().replace('"active":true', '"active":false'))
  assert.equal(crypto.verify(null, forged, nodePublicKey(pair.publicKey), signature), false)
  const other = nacl.sign.keyPair.fromSeed(crypto.randomBytes(32))
  assert.equal(crypto.verify(null, message, nodePublicKey(other.publicKey), signature), false)
})

test('the offline window is capped by expiry and the configured grace is clamped', () => {
  const expiring = { ...pro, expires_at: new Date(1800000000 * 1000 + 3 * 86400000).toISOString() }
  const capped = signer.assertionPayload('k', 'u', activeDevice, expiring, 1800000000, 14)
  assert.equal(capped.expires_at, 1800000000 + 3 * 86400)
  assert.equal(capped.offline_until, capped.expires_at)
  assert.equal(signer.offlineGraceDays(fakeApp()), 14)
  assert.equal(signer.offlineGraceDays(fakeApp({ client: { min_version: '0.1.0', offline_grace_days: 7 } })), 7)
  assert.equal(signer.offlineGraceDays(fakeApp({ client: { offline_grace_days: 9000 } })), 60)
  assert.equal(signer.offlineGraceDays(fakeApp({ client: { offline_grace_days: -3 } })), 0)
  assert.equal(signer.offlineGraceDays(fakeApp({ client: { offline_grace_days: '30' } })), 14)
})

test('issue fails closed without a usable key and only for an active device on an active plan', () => {
  const devices = [{ device_id: activeDevice }]
  assert.equal(signer.issue(fakeApp(), 'user1', activeDevice, pro, devices), null)
  assert.equal(signer.issue(fakeApp({ secret: 'no-kid-separator' }), 'user1', activeDevice, pro, devices), null)
  assert.equal(signer.issue(fakeApp({ secret: 'k:' + Buffer.alloc(16).toString('base64') }), 'user1', activeDevice, pro, devices), null)
  const app = fakeApp({ secret: testKey })
  assert.equal(signer.issue(app, 'user1', 'FEDCBA9876543210', pro, devices), null, 'removed or unknown device')
  assert.equal(signer.issue(app, 'user1', 'short', pro, [{ device_id: 'short' }]), null)
  assert.equal(signer.issue(app, 'user1', activeDevice, { ...pro, active: false, status: 'expired' }, devices), null)
  assert.equal(signer.issue(app, '', activeDevice, pro, devices), null)
  const compact = signer.issue(app, 'user1', activeDevice, pro, devices)
  const claims = JSON.parse(split(compact).message)
  assert.equal(claims.kid, 'mm-test-1')
  assert.ok(Math.abs(claims.issued_at - Date.now() / 1000) < 5)
})

test('the environment key wins over app_secrets and the secret is never part of the assertion', () => {
  const envSeed = crypto.randomBytes(32)
  env.MACMINT_ENTITLEMENT_SIGNING_KEY = 'mm-env:' + envSeed.toString('base64url')
  const app = fakeApp({ secret: testKey })
  const compact = signer.issue(app, 'user1', activeDevice, pro, [{ device_id: activeDevice }])
  const { message, signature } = split(compact)
  assert.equal(JSON.parse(message).kid, 'mm-env')
  assert.ok(crypto.verify(null, message, nodePublicKey(nacl.sign.keyPair.fromSeed(envSeed).publicKey), signature))
  assert.ok(!app.lookups.includes('app_secrets'))
  assert.ok(!compact.includes(envSeed.toString('base64url')) && !message.toString().includes(envSeed.toString('base64')))
})

test('an identical binding reuses its assertion and any entitlement change re-signs', () => {
  const app = fakeApp({ secret: testKey }), devices = [{ device_id: activeDevice }]
  const first = signer.issue(app, 'user1', activeDevice, pro, devices)
  assert.equal(signer.issue(app, 'user1', activeDevice, pro, devices), first)
  const later = { ...pro, expires_at: '2099-01-01T00:00:00.000Z' }
  const changed = signer.issue(app, 'user1', activeDevice, later, devices)
  assert.notEqual(changed, first)
  assert.equal(JSON.parse(split(changed).message).expires_at, Date.parse(later.expires_at) / 1000)
  const otherDevice = '0123456789ABCDEF'
  assert.notEqual(signer.issue(app, 'user1', otherDevice, pro, [{ device_id: otherDevice }]), first)
})

test('attach adds the assertion field only when one is issued', () => {
  const payload = () => ({ user: { id: 'user1' }, entitlement: pro, devices: [{ device_id: activeDevice }] })
  assert.ok(!('entitlement_assertion' in signer.attach(fakeApp(), payload(), activeDevice)))
  assert.ok(!('entitlement_assertion' in signer.attach(fakeApp({ secret: testKey }), payload(), '')))
  assert.match(signer.attach(fakeApp({ secret: testKey }), payload(), activeDevice).entitlement_assertion, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{86}$/)
})
