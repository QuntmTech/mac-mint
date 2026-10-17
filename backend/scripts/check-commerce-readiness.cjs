#!/usr/bin/env node
'use strict'

// Offline configuration preflight only. Never requests Stripe/PocketBase access,
// writes configuration, or prints the supplied configuration or credential values.
const fs = require('node:fs')
const { validConfiguration } = require('../pocketbase/pb_hooks/macmint_payments_lib.js')

const args = process.argv.slice(2)
if (args.length === 1 && args[0] === '--help') {
  console.log('Usage: node backend/scripts/check-commerce-readiness.cjs --config /path/to/commerce.json')
  console.log('Reads STRIPE_RESTRICTED_KEY and STRIPE_WEBHOOK_SECRET from the environment; values are never printed.')
  console.log('Exit 0: local prerequisites complete. Exit 2: blocked. This command never certifies launch readiness.')
  process.exit(0)
}
if (args.length !== 2 || args[0] !== '--config') {
  console.error('Supply --config followed by the path to a commerce JSON file. Use --help for details.')
  process.exit(2)
}

let config
try {
  const info = fs.statSync(args[1])
  if (!info.isFile() || info.size > 65536) throw Error('Invalid configuration file')
  config = JSON.parse(fs.readFileSync(args[1], 'utf8'))
} catch (_) {
  console.error('Could not read the commerce JSON configuration. No configuration or credential values were printed.')
  process.exit(2)
}

const valid = validConfiguration(config)
const mode = config?.livemode === true ? 'live' : config?.livemode === false ? 'test' : null
const key = process.env.STRIPE_RESTRICTED_KEY || ''
const webhook = process.env.STRIPE_WEBHOOK_SECRET || ''
const keyPrefix = mode ? `rk_${mode}_` : ''
const keyMatches = !!keyPrefix && key.startsWith(keyPrefix) && key.length > keyPrefix.length && key.trim() === key
const webhookPresent = webhook.startsWith('whsec_') && webhook.length > 6 && webhook.trim() === webhook
const checks = [
  { id: 'commerce_config', passed: valid },
  { id: 'commerce_enabled', passed: config?.enabled === true },
  { id: 'restricted_key_matches_mode', passed: keyMatches },
  { id: 'webhook_secret_present', passed: webhookPresent },
]
const localComplete = checks.every(check => check.passed)
console.log(JSON.stringify({
  status: localComplete ? 'local_prerequisites_complete' : 'blocked',
  target_mode: mode === 'test' ? 'sandbox' : mode,
  launch_ready: false,
  checks,
  required_verification: [
    'intended_stripe_account_and_sandbox',
    'stripe_price_amount_currency_and_one_time_type',
    'restricted_key_permissions',
    'registered_webhook_delivery_and_signature',
    'validated_notarized_stable_release',
    'account_email_delivery',
    'purchase_fulfillment_and_device_activation',
  ],
}, null, 2))
process.exit(localComplete ? 0 : 2)
