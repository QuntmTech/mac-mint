const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawnSync } = require('node:child_process')

const script = path.resolve(__dirname, '../scripts/check-commerce-readiness.cjs')
const canaryKey = ['rk', 'test', 'PrivateCanaryDoNotPrint'].join('_')
const canaryWebhook = ['whsec', 'PrivateWebhookDoNotPrint'].join('_')
const offer = { enabled: true, livemode: false, price_id: 'price_fixture', amount_minor: 100,
  currency: 'usd', plan: 'pro', duration_days: 30, max_devices: 1 }

function run(t, config, environment = {}) {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'macmint-commerce-'))
  t.after(() => fs.rmSync(folder, { recursive: true, force: true }))
  const file = path.join(folder, 'commerce.json')
  const contents = typeof config === 'string' ? config : JSON.stringify(config)
  fs.writeFileSync(file, contents)
  const result = spawnSync(process.execPath, [script, '--config', file], {
    encoding: 'utf8', env: { ...process.env, STRIPE_RESTRICTED_KEY: '', STRIPE_WEBHOOK_SECRET: '', ...environment },
  })
  assert.equal(fs.readFileSync(file, 'utf8'), contents, 'Preflight must not enable or modify the offer')
  assert.ok(!`${result.stdout}${result.stderr}`.includes(canaryKey))
  assert.ok(!`${result.stdout}${result.stderr}`.includes(canaryWebhook))
  return result
}

test('pending-pricing template stays blocked without choosing a price', t => {
  const config = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../commerce.example.json'), 'utf8'))
  const result = run(t, config)
  assert.equal(result.status, 2)
  const report = JSON.parse(result.stdout)
  assert.equal(report.launch_ready, false)
  assert.equal(report.status, 'blocked')
  assert.equal(report.checks.find(check => check.id === 'commerce_config').passed, false)
  assert.equal(config.amount_minor, null)
  assert.equal(config.enabled, false)
})

test('complete local inputs report sandbox verification, never launch readiness or secrets', t => {
  const result = run(t, offer, { STRIPE_RESTRICTED_KEY: canaryKey, STRIPE_WEBHOOK_SECRET: canaryWebhook })
  assert.equal(result.status, 0, result.stderr)
  const report = JSON.parse(result.stdout)
  assert.equal(report.status, 'local_prerequisites_complete')
  assert.equal(report.target_mode, 'sandbox')
  assert.equal(report.launch_ready, false)
  assert.ok(report.required_verification.includes('registered_webhook_delivery_and_signature'))
  assert.ok(report.required_verification.includes('stripe_price_amount_currency_and_one_time_type'))
  assert.ok(!result.stdout.includes(offer.price_id))
})

test('mixed live and sandbox credentials or a disabled offer cannot pass', t => {
  for (const config of [{ ...offer, livemode: true }, { ...offer, enabled: false }]) {
    const result = run(t, config, { STRIPE_RESTRICTED_KEY: canaryKey, STRIPE_WEBHOOK_SECRET: canaryWebhook })
    assert.equal(result.status, 2)
    assert.equal(JSON.parse(result.stdout).status, 'blocked')
  }
})

test('unrestricted keys and malformed config are rejected without dumping their values', t => {
  const unrestricted = ['sk', 'test', 'PrivateCanaryDoNotPrint'].join('_')
  const keyResult = run(t, offer, { STRIPE_RESTRICTED_KEY: unrestricted, STRIPE_WEBHOOK_SECRET: canaryWebhook })
  assert.equal(keyResult.status, 2)
  assert.ok(!`${keyResult.stdout}${keyResult.stderr}`.includes(unrestricted))
  const badResult = run(t, `{ "credential": "${canaryKey}",`)
  assert.equal(badResult.status, 2)
  assert.ok(badResult.stderr.includes('Could not read'))
})

test('unsafe return origins fail preflight and live checkout rejects HTTP loopback', t => {
  for (const config of [
    { ...offer, web_origin: 'https://macmint.co/redirect' },
    { ...offer, web_origin: 'https://macmint.co@other.example' },
    { ...offer, web_origin: 'http://localhost:5173', livemode: true },
  ]) {
    const key = config.livemode ? ['rk', 'live', 'PrivateCanaryDoNotPrint'].join('_') : canaryKey
    const result = run(t, config, { STRIPE_RESTRICTED_KEY: key, STRIPE_WEBHOOK_SECRET: canaryWebhook })
    assert.equal(result.status, 2)
    assert.equal(JSON.parse(result.stdout).checks.find(check => check.id === 'commerce_config').passed, false)
    assert.ok(!result.stdout.includes(config.web_origin))
    assert.ok(!result.stdout.includes(key))
  }
  const local = run(t, { ...offer, web_origin: 'http://localhost:5173' },
    { STRIPE_RESTRICTED_KEY: canaryKey, STRIPE_WEBHOOK_SECRET: canaryWebhook })
  assert.equal(local.status, 0)
})

test('approved recurring template remains closed until provider bindings and acceptance are complete', t => {
  const config = JSON.parse(fs.readFileSync(path.resolve(__dirname, '../commerce.subscription.example.json'), 'utf8'))
  assert.equal(config.amount_minor, 3999)
  assert.equal(config.trial_days, 3)
  assert.equal(config.billing_interval, 'year')
  assert.equal(config.max_devices, 3)
  assert.equal(config.enabled, false)
  assert.equal(run(t, config).status, 2)
  const result = run(t, { ...config, enabled: true, price_id: 'price_fixture', portal_configuration_id: 'bpc_fixture' },
    { STRIPE_RESTRICTED_KEY: canaryKey, STRIPE_WEBHOOK_SECRET: canaryWebhook })
  assert.equal(result.status, 0)
  const report = JSON.parse(result.stdout)
  assert.equal(report.launch_ready, false)
  assert.ok(report.required_verification.includes('stripe_recurring_price_amount_currency_interval_and_trial'))
  assert.ok(report.required_verification.includes('trial_conversion_renewal_failure_and_recovery'))
})
