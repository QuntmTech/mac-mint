import { test, expect, type Page } from '@playwright/test'
import type { Offer, Subscription } from '../src/lib/offers.js'

// Every remote request is intercepted. These are browser protocol fixtures, not real accounts.
async function backend(page: Page, signedIn = false, verified = true) {
  const user = { id: 'fixtureuser1234', email: 'fixture@example.invalid', name: 'Fixture', verified,
    collectionId: '_pb_users_auth_', collectionName: 'users' }
  const token = [{ alg: 'HS256', typ: 'JWT' }, { exp: Math.floor(Date.now() / 1000) + 3600,
    id: user.id, collectionId: user.collectionId, type: 'auth' }]
    .map(value => Buffer.from(JSON.stringify(value)).toString('base64url')).join('.') + '.fixture'
  const state = { user, currentUser: user, token, redeemWait: Promise.resolve(), redeemRequests: 0, verificationAttempts: 0, verificationFails: false,
    checkoutError: '' as '' | 'checkout_complete' | 'checkout_expired' | 'checkout_unavailable' | 'checkout_in_progress' | 'checkout_attention',
    canonicalKey: '84bfa09d-9db2-4f79-a680-b3a461d7af08', checkoutURLOverride: null as string | null,
    statusOffer: undefined as Omit<Offer, 'enabled'> | undefined,
    offer: { enabled: true, amount_minor: 7900, currency: 'usd', duration_days: 365, max_devices: 3 } as Offer,
    subscription: null as Subscription | null, portalURL: 'https://billing.stripe.com/p/session/fixture', portalRequests: 0,
    configFails: false, configWait: Promise.resolve(), checkoutWait: Promise.resolve(),
    status: 'pending' as 'created' | 'pending' | 'fulfilled' | 'failed' | 'expired' | 'not_found',
    statusCanStartNew: false, statusFails: false, statusRequests: [] as string[],
    releases: [] as Record<string, unknown>[],
    active: false, accountRequests: 0,
    checkoutRequests: [] as { request_key: string }[], analytics: 0, unexpected: [] as string[] }
  if (signedIn) await page.addInitScript(auth => {
    if (location.origin === 'http://127.0.0.1:4173') localStorage.setItem('pocketbase_auth', JSON.stringify(auth))
  }, { token, record: user })
  await page.route('**/*', async route => {
    const url = new URL(route.request().url())
    if (url.origin === 'http://127.0.0.1:4173') return route.continue()
    if (url.origin === 'https://checkout.stripe.com') return route.fulfill({ contentType: 'text/html', body: '<h1>Local checkout fixture</h1>' })
    if (url.origin === 'https://billing.stripe.com') return route.fulfill({ contentType: 'text/html', body: '<h1>Local billing fixture</h1>' })
    if (url.origin !== 'https://macmint.cloudpod.pro') {
      state.unexpected.push(url.origin); return route.abort()
    }
    const path = url.pathname
    const respond = (body: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
    if (path.endsWith('/auth-refresh')) return respond({ token, record: state.currentUser })
    if (path === '/api/macmint/me') {
      state.accountRequests++
      return respond({ user: state.currentUser, entitlement: { plan: state.active ? 'pro' : 'free', active: state.active,
        status: 'active', expires_at: state.subscription?.trial_through ?? state.subscription?.paid_through ?? null,
        max_devices: state.active ? 3 : 0, source: state.subscription?.status === 'trialing' ? 'subscription_trial' : state.active ? 'stripe' : 'signup' },
        billing: { subscription: state.subscription }, devices: [], server_time: new Date().toISOString() })
    }
    if (path === '/api/macmint/redeem') {
      const redeemUser = { ...state.currentUser }
      state.redeemRequests++
      await state.redeemWait
      return respond({ user: redeemUser, entitlement: { plan: 'pro', active: true, status: 'active', expires_at: null,
        max_devices: 3, source: 'manual' }, devices: [], server_time: new Date().toISOString(), redeemed: true })
    }
    if (path.includes('/app_releases/records')) return respond({ page: 1, perPage: 1, totalItems: state.releases.length, totalPages: state.releases.length ? 1 : 0, items: state.releases })
    if (path === '/api/macmint/checkout/config') {
      await state.configWait
      return state.configFails ? respond({ message: 'temporarily unavailable' }, 503) : respond(state.offer)
    }
    if (path === '/api/macmint/checkout/status') {
      state.statusRequests.push(url.searchParams.get('request_key') ?? '')
      return state.statusFails ? respond({ message: 'Status temporarily unavailable.' }, 503)
        : respond({ state: state.status, can_start_new: state.statusCanStartNew, offer: state.statusOffer })
    }
    if (path === '/api/macmint/billing/portal') {
      state.portalRequests++
      return respond({ url: state.portalURL })
    }
    if (path === '/api/macmint/checkout') {
      state.checkoutRequests.push(route.request().postDataJSON())
      await state.checkoutWait
      if (state.checkoutError) return respond({ error: state.checkoutError, request_key: state.checkoutError === 'checkout_in_progress' ? state.canonicalKey : undefined, message: state.checkoutError === 'checkout_complete'
        ? 'This checkout is already complete or processing. Refresh your account to check access; do not pay again.'
        : state.checkoutError === 'checkout_expired' ? 'This checkout attempt expired. Start a new checkout attempt to continue.' : 'Checkout could not be opened. Please try again later.' }, state.checkoutError === 'checkout_unavailable' ? 503 : 409)
      return respond({ url: state.checkoutURLOverride ?? (state.checkoutRequests.length === 1 ? 'https://attacker.invalid/checkout' : 'https://checkout.stripe.com/c/pay/cs_test_fixture') })
    }
    if (path.endsWith('/request-verification')) {
      state.verificationAttempts++
      return state.verificationFails ? respond({ message: 'Email service temporarily unavailable.' }, 503) : route.fulfill({ status: 204 })
    }
    if (path.endsWith('/request-password-reset')) return route.fulfill({ status: 204 })
    if (path.endsWith('/confirm-password-reset')) return respond({ message: 'This reset link is invalid or has expired.' }, 400)
    if (path.includes('/site_events/')) { state.analytics++; return respond({}) }
    state.unexpected.push(path); return respond({ message: 'Unexpected fixture request' }, 500)
  })
  return state
}

const errors = new WeakMap<Page, string[]>()
test.beforeEach(({ page }) => {
  const list: string[] = []; errors.set(page, list)
  page.on('pageerror', error => list.push(error.message))
})
test.afterEach(({ page }) => { expect(errors.get(page)).toEqual([]) })

test('signed-in users can return to the public homepage after an account redirect', async ({ page }) => {
  const state = await backend(page, true)
  await page.goto('/login?next=' + encodeURIComponent('/?source=account-return#features'))
  await expect(page).toHaveURL('http://127.0.0.1:4173/?source=account-return#features')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/Put your Mac back.*mint condition/)
  expect(state.unexpected).toEqual([])
})

test('signed-out routing, reset privacy and mobile layout work without analytics', async ({ page }) => {
  const state = await backend(page)
  await page.goto('/account')
  await expect(page).toHaveURL(/\/login\?next=/)
  await page.goto('/reset-password')
  await expect(page.getByRole('heading', { name: 'Reset link missing' })).toBeVisible()
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/forgot-password')
  await page.getByLabel('Email', { exact: true }).fill('unknown@example.invalid')
  await page.getByRole('button', { name: 'Send reset link' }).click()
  await expect(page.getByRole('status')).toContainText('If an account exists')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  expect(state.analytics).toBe(0); expect(state.unexpected).toEqual([])
})

test('unverified users can retry email delivery and refresh verification before checkout', async ({ page }) => {
  const state = await backend(page, true, false)
  await page.goto('/account')
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeDisabled()
  state.verificationFails = true
  await page.getByRole('button', { name: 'Send verification email' }).click()
  await expect(page.getByRole('alert')).toContainText('Email service temporarily unavailable')
  state.verificationFails = false
  await page.getByRole('button', { name: 'Send verification email' }).click()
  await expect(page.getByRole('status')).toContainText('Verification email requested')
  expect(state.verificationAttempts).toBe(2)
  state.user.verified = true
  await page.getByRole('button', { name: 'Refresh verification status' }).click()
  await expect(page.getByRole('heading', { name: 'Verify your email' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeEnabled()
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

test('checkout rejects foreign redirects, preserves retry identity and cannot grant access from a return URL', async ({ page }) => {
  const state = await backend(page, true)
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('alert')).toBeVisible()
  await expect(page).toHaveURL(/\/account$/)
  await expect(page.getByRole('button', { name: 'Start a new checkout attempt' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Resume checkout' }).click()
  await expect(page).toHaveURL('https://checkout.stripe.com/c/pay/cs_test_fixture')
  expect(state.checkoutRequests).toHaveLength(2)
  expect(state.checkoutRequests[0].request_key).toBe(state.checkoutRequests[1].request_key)
  await page.goto('/account?checkout=processing')
  await expect(page.getByText('No active plan', { exact: true })).toBeVisible()
  await expect(page.getByRole('status').filter({ hasText: 'after Stripe confirms payment' })).toBeVisible()
  expect(state.unexpected).toEqual([])
})

test('invalid reset links give a recoverable error without changing the password', async ({ page }) => {
  const state = await backend(page)
  await page.goto('/reset-password?token=expired-fixture-token')
  await page.getByLabel('New password', { exact: true }).fill('fixture-password-123')
  await page.getByLabel('Confirm new password', { exact: true }).fill('fixture-password-123')
  await page.getByRole('button', { name: 'Update password' }).click()
  await expect(page.getByRole('alert')).toContainText('invalid or has expired')
  await page.getByRole('link', { name: 'Request a new link' }).click()
  await expect(page).toHaveURL(/\/forgot-password$/)
  expect(state.unexpected).toEqual([])
})

test('completed checkout prevents another payment attempt and expired checkout can restart explicitly', async ({ page }) => {
  const state = await backend(page, true)
  state.checkoutError = 'checkout_expired'
  state.status = 'expired'; state.statusCanStartNew = true
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('alert')).toContainText('expired')
  await page.getByRole('button', { name: 'Start a new checkout attempt' }).click()
  state.checkoutError = 'checkout_complete'; state.status = 'pending'; state.statusCanStartNew = false
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('alert')).toContainText('do not pay again')
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Start a new checkout attempt' })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Refresh account' })).toBeVisible()
  expect(state.checkoutRequests).toHaveLength(2)
  expect(state.checkoutRequests[0].request_key).not.toBe(state.checkoutRequests[1].request_key)
  expect(state.unexpected).toEqual([])
})

const retainedRequestKey = '84bfa09d-9db2-4f79-a680-b3a461d7af08'
async function retainCheckout(page: Page) {
  await page.addInitScript(key => {
    if (location.origin === 'http://127.0.0.1:4173') sessionStorage.setItem('mm_checkout_fixtureuser1234', key)
  }, retainedRequestKey)
}

test('offer loading, offline retry and closed checkout are distinct without an invented price', async ({ page }) => {
  const state = await backend(page, true)
  let resolveConfig!: () => void
  state.configWait = new Promise<void>(resolve => { resolveConfig = resolve })
  await page.goto('/account')
  await expect(page.getByRole('status')).toContainText('Checking purchase availability')
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toHaveCount(0)
  state.configFails = true; resolveConfig()
  await expect(page.getByText('Purchase availability could not be checked.')).toBeVisible()
  await expect(page.getByText('Checkout is not open yet.', { exact: false })).toHaveCount(0)
  state.configFails = false; state.offer.enabled = false
  await page.getByRole('button', { name: 'Check purchase availability again' }).click()
  await expect(page.getByText('Checkout is not open yet.', { exact: false })).toBeVisible()
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

for (const [currency, amount, display] of [['usd', 7900, '$79.00'], ['jpy', 7900, '¥7,900'], ['kwd', 12345, 'KWD 12.345'], ['isk', 1200, 'ISK 12'], ['ugx', 1200, 'UGX 12']] as const) {
  test(`configured ${currency} price uses Stripe minor units`, async ({ page }) => {
    const state = await backend(page, true)
    state.offer.currency = currency; state.offer.amount_minor = amount
    await page.goto('/account')
    // Normalize the narrow/no-break spaces Intl inserts for some currencies.
    await expect(page.locator('p.text-lg.font-semibold')).toBeVisible()
    const text = await page.locator('p.text-lg.font-semibold').innerText()
    expect(text.replace(/\s/g, ' ')).toContain(display)
    await expect(page.getByText('365 days of access · Up to 3 Macs')).toBeVisible()
    expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
  })
}

test('cancel return and ambiguous errors preserve the original checkout identity', async ({ page }) => {
  const state = await backend(page, true)
  await retainCheckout(page)
  state.checkoutError = 'checkout_unavailable'
  await page.goto('/account?checkout=cancelled')
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toBeEnabled()
  await page.getByRole('button', { name: 'Resume checkout' }).click()
  await expect(page.getByRole('alert')).toContainText('could not be opened')
  await expect(page.getByRole('button', { name: 'Start a new checkout attempt' })).toHaveCount(0)
  await page.getByRole('button', { name: 'Resume checkout' }).click()
  expect(state.checkoutRequests.map(value => value.request_key)).toEqual([retainedRequestKey, retainedRequestKey])
  expect(await page.evaluate(() => sessionStorage.getItem('mm_checkout_fixtureuser1234'))).toBe(retainedRequestKey)
  expect(state.unexpected).toEqual([])
})

test('processing checkout polls briefly, blocks another payment and refreshes access from the server', async ({ page }) => {
  const state = await backend(page, true)
  await retainCheckout(page)
  await page.clock.install()
  await page.goto('/account?checkout=processing')
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toBeDisabled()
  await expect.poll(() => state.statusRequests.length).toBe(1)
  for (let index = 2; index <= 6; index++) {
    await page.clock.runFor(3000)
    await expect.poll(() => state.statusRequests.length).toBe(index)
  }
  await expect(page.getByRole('status')).toContainText('Automatic checks have paused')
  await page.clock.runFor(30000)
  expect(state.statusRequests).toHaveLength(6)
  state.status = 'fulfilled'; state.active = true
  await page.getByRole('button', { name: 'Refresh account' }).click()
  await expect(page.getByRole('status')).toContainText('Your plan is active')
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toHaveCount(0)
  expect(state.checkoutRequests).toHaveLength(0)
  expect(state.statusRequests.every(key => key === retainedRequestKey)).toBe(true)
  expect(state.unexpected).toEqual([])
})

test('a return URL without a saved checkout cannot assert payment or open a second checkout', async ({ page }) => {
  const state = await backend(page, true)
  await page.goto('/account?checkout=processing')
  await expect(page.getByRole('status').filter({ hasText: 'cannot identify the original checkout' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeDisabled()
  await page.getByRole('button', { name: 'Refresh account' }).click()
  await expect(page.getByText('No active plan', { exact: true })).toBeVisible()
  expect(state.statusRequests).toHaveLength(0); expect(state.checkoutRequests).toHaveLength(0)
  expect(state.unexpected).toEqual([])
})

test('an expiry message or unrecognized checkout cannot authorize replacing a pending payment', async ({ page }) => {
  const state = await backend(page, true)
  state.checkoutError = 'checkout_expired'; state.status = 'not_found'
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('alert')).toContainText('expired')
  await expect(page.getByRole('button', { name: 'Start a new checkout attempt' })).toHaveCount(0)
  state.status = 'failed'; state.statusCanStartNew = true
  await page.getByRole('button', { name: 'Refresh account' }).click()
  await page.getByRole('button', { name: 'Start a new checkout attempt' }).click()
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeEnabled()
  expect(await page.evaluate(() => sessionStorage.getItem('mm_checkout_fixtureuser1234'))).toBeNull()
  expect(state.unexpected).toEqual([])
})

for (const terminal of ['expired', 'failed'] as const) {
  test(`a processing return can start anew after server-confirmed ${terminal}`, async ({ page }) => {
    const state = await backend(page, true)
    await retainCheckout(page)
    state.status = terminal; state.statusCanStartNew = true
    await page.goto('/account?checkout=processing&keep=example')
    await page.getByRole('button', { name: 'Start a new checkout attempt' }).click()
    await expect(page).toHaveURL('/account?keep=example')
    await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeEnabled()
    await expect(page.locator('p.text-lg.font-semibold')).toContainText('$79.00')
    await page.getByRole('button', { name: 'Continue to checkout' }).click()
    await expect(page.getByRole('alert')).toContainText('Checkout could not be opened')
    expect(state.checkoutRequests).toHaveLength(1)
    expect(state.checkoutRequests[0].request_key).not.toBe(retainedRequestKey)
    expect(state.unexpected).toEqual([])
  })
}

test('resuming a saved order does not substitute the current offer terms', async ({ page }) => {
  const state = await backend(page, true)
  await retainCheckout(page)
  state.offer.amount_minor = 9900; state.offer.duration_days = 30; state.offer.max_devices = 1
  await page.goto('/account?checkout=cancelled')
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toBeEnabled()
  await expect(page.getByText('Review its saved price and payment details', { exact: false })).toBeVisible()
  await expect(page.locator('p.text-lg.font-semibold')).toHaveCount(0)
  await expect(page.getByText('30 days of access · Up to 1 Mac')).toHaveCount(0)
  expect(state.unexpected).toEqual([])
})


test('a different browser attempt adopts the owner-scoped existing checkout only on explicit resume', async ({ page }) => {
  const state = await backend(page, true)
  state.checkoutError = 'checkout_in_progress'
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toBeEnabled()
  expect(state.checkoutRequests).toHaveLength(1)
  expect(await page.evaluate(() => sessionStorage.getItem('mm_checkout_fixtureuser1234'))).toBe(state.canonicalKey)
  state.checkoutError = ''
  await page.getByRole('button', { name: 'Resume checkout' }).click()
  await expect(page).toHaveURL('https://checkout.stripe.com/c/pay/cs_test_fixture')
  expect(state.checkoutRequests[1].request_key).toBe(state.canonicalKey)
  expect(state.unexpected).toEqual([])
})

test('ambiguous legacy checkouts cannot open another payment or silently replace their key', async ({ page }) => {
  const state = await backend(page, true)
  state.checkoutError = 'checkout_attention'
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('button', { name: 'Resume checkout' })).toBeDisabled()
  await expect(page.getByRole('button', { name: 'Start a new checkout attempt' })).toHaveCount(0)
  expect(state.checkoutRequests).toHaveLength(1); expect(state.unexpected).toEqual([])
})

test('saved checkout displays its immutable offer and can verify payment while fresh sales are disabled', async ({ page }) => {
  const state = await backend(page, true)
  await retainCheckout(page)
  state.statusOffer = { amount_minor: 2400, currency: 'usd', plan: 'pro', duration_days: 90, max_devices: 2 }
  state.offer.amount_minor = 9900; state.offer.duration_days = 30; state.offer.max_devices = 1
  await page.goto('/account?checkout=cancelled')
  await expect(page.locator('p.text-lg.font-semibold')).toContainText('$24.00')
  await expect(page.getByText('90 days of access · Up to 2 Macs')).toBeVisible()
  await expect(page.getByText('30 days of access · Up to 1 Mac')).toHaveCount(0)
  state.offer.enabled = false
  await page.goto('/account?checkout=processing')
  await expect(page.getByText('Checkout is not open yet.', { exact: false })).toBeVisible()
  state.status = 'fulfilled'; state.active = true
  await page.getByRole('button', { name: 'Refresh account' }).click()
  await expect(page.getByRole('status')).toContainText('Your plan is active')
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})


test('signing out during checkout prevents a late redirect into the previous account payment', async ({ page }) => {
  const state = await backend(page, true)
  let release!: () => void
  state.checkoutWait = new Promise<void>(resolve => { release = resolve })
  state.checkoutURLOverride = 'https://checkout.stripe.com/c/pay/cs_test_fixture'
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect.poll(() => state.checkoutRequests.length).toBe(1)
  await page.getByRole('button', { name: 'Sign out', exact: true }).click()
  await expect(page).toHaveURL(/\/login\?next=/)
  const checkoutResponse = page.waitForResponse(response => response.url().endsWith('/api/macmint/checkout'))
  release()
  await (await checkoutResponse).finished()
  await page.getByRole('heading', { name: 'Sign in' }).waitFor()
  await expect(page).toHaveURL(/\/login\?next=/)
  expect(state.unexpected).toEqual([])
})

test('unavailable session storage blocks payment creation with a recoverable explanation', async ({ page }) => {
  const state = await backend(page, true)
  await page.addInitScript(() => {
    const setItem = Storage.prototype.setItem
    Storage.prototype.setItem = function(key, value) {
      if (this === sessionStorage) throw new DOMException('Storage blocked', 'SecurityError')
      return setItem.call(this, key, value)
    }
  })
  await page.goto('/account')
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('alert')).toContainText('needs browser session storage')
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeDisabled()
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

for (const currency of ['isk', 'ugx']) {
  test(`fractional ${currency} special-case amounts cannot display a misleading offer`, async ({ page }) => {
    const state = await backend(page, true)
    state.offer.currency = currency; state.offer.amount_minor = 1250
    await page.goto('/account')
    await expect(page.getByText('Purchase availability could not be checked.')).toBeVisible()
    await expect(page.getByRole('button', { name: 'Continue to checkout' })).toHaveCount(0)
    expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
  })
}


test('a delayed redemption for the previous user cannot replace the newly signed-in account', async ({ page }) => {
  const state = await backend(page, true)
  let release!: () => void
  state.redeemWait = new Promise<void>(resolve => { release = resolve })
  await page.goto('/account')
  await page.getByLabel('Redemption code').fill('MINT-AAAA-BBBB-CCCC-DDDD')
  await page.getByRole('button', { name: 'Redeem', exact: true }).click()
  await expect.poll(() => state.redeemRequests).toBe(1)
  state.currentUser = { ...state.user, id: 'seconduser12345', email: 'second@example.invalid' }
  await page.evaluate(auth => {
    const serialized = JSON.stringify(auth)
    localStorage.setItem('pocketbase_auth', serialized)
    window.dispatchEvent(new StorageEvent('storage', { key: 'pocketbase_auth', newValue: serialized }))
  }, { token: state.token, record: state.currentUser })
  await expect(page.getByText('second@example.invalid', { exact: true })).toBeVisible()
  await expect(page.getByText('No active plan', { exact: true })).toBeVisible()
  const redemptionResponse = page.waitForResponse(response => response.url().endsWith('/api/macmint/redeem'))
  release()
  await (await redemptionResponse).finished()
  // An interaction also proves the account view remains responsive after the old reply.
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page.getByRole('alert')).toContainText('Checkout could not be opened')
  await expect(page.getByText('second@example.invalid', { exact: true })).toBeVisible()
  await expect(page.getByText('No active plan', { exact: true })).toBeVisible()
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0)
  expect(state.unexpected).toEqual([])
})

test('payment polling pauses while hidden and resumes with its original finite request budget', async ({ page }) => {
  const state = await backend(page, true)
  await retainCheckout(page)
  await page.clock.install()
  await page.goto('/account?checkout=processing')
  await expect.poll(() => state.statusRequests.length).toBe(1)
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'hidden' })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await page.clock.runFor(15000)
  expect(state.statusRequests).toHaveLength(1)
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  await expect.poll(() => state.statusRequests.length).toBe(2)
  for (let index = 3; index <= 6; index++) {
    await page.clock.runFor(3000)
    await expect.poll(() => state.statusRequests.length).toBe(index)
  }
  await expect(page.getByRole('status')).toContainText('Automatic checks have paused')
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')))
  await page.clock.runFor(30000)
  expect(state.statusRequests).toHaveLength(6)
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

for (const format of ['dmg', 'zip']) {
  test(`a purchased account gets ${format} installation and same-account activation instructions`, async ({ page }) => {
    const state = await backend(page, true)
    state.active = true
    const url = `https://github.com/QuntmTech/mac-mint/releases/download/v0.9.0/MacMint.${format}?download=1`
    state.releases = [{ id: 'releasefixture', version: '0.9.0', build: 9, min_os: '14.0', download_url: url,
      sha256: 'a'.repeat(64), size_bytes: 1024, notes: 'Validated fixture', published_at: new Date().toISOString() }]
    await page.setViewportSize({ width: 390, height: 844 })
    await page.goto('/account')
    await expect(page.getByRole('link', { name: 'Download for Mac', exact: true })).toHaveAttribute('href', url)
    const guide = page.getByRole('region', { name: 'Install MacMint', exact: true })
    await expect(guide.getByRole('listitem')).toHaveCount(3)
    await expect(guide).toContainText(format === 'dmg' ? 'Open MacMint.dmg' : 'Expand MacMint.zip')
    await expect(guide).toContainText('Drag MacMint to Applications')
    await expect(guide).toContainText('A direct website purchase does not need a redemption code.')
    expect(state.checkoutRequests).toEqual([])
    expect(state.unexpected).toEqual([])
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
  })
}

const annualOffer = { enabled: true, billing_mode: 'subscription' as const, billing_interval: 'year' as const,
  billing_interval_count: 1, trial_days: 3, amount_minor: 3999, currency: 'usd', duration_days: 0, max_devices: 3 }
const subscriptionFixture: Subscription = { ...annualOffer, status: 'trialing', cancel_at_period_end: false,
  cancel_at: null, paid_through: null, trial_through: '2027-02-04T12:00:00Z', current_period_end: '2027-02-04T12:00:00Z' }

test('annual trial shows the first charge, automatic renewal, cancellation and Mac allowance before checkout', async ({ page }) => {
  const state = await backend(page, true)
  state.offer = { ...annualOffer }
  await page.goto('/account')
  await expect(page.locator('p.text-lg.font-semibold')).toContainText('3 days free, then $39.99 / year USD')
  await expect(page.getByText('Recurring subscription · Up to 3 Macs')).toBeVisible()
  await expect(page.getByText(/A payment method is required.*Cancel before the trial ends/)).toBeVisible()
  await expect(page.getByText(/Renews automatically each year/)).toBeVisible()
  await expect(page.getByText('Lifetime access', { exact: true })).toHaveCount(0)
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

test('trial account has a bounded end date and owner billing management in light and dark modes', async ({ page }) => {
  const state = await backend(page, true)
  state.active = true; state.subscription = { ...subscriptionFixture }
  await page.emulateMedia({ colorScheme: 'dark' })
  await page.goto('/account')
  await expect(page.getByText(/^Trial ends /)).toBeVisible()
  const billing = page.getByRole('region', { name: 'Subscription billing' })
  await expect(billing).toContainText(/free trial.*ends/)
  await expect(billing).toContainText('billing starts at $39.99 per year')
  await expect(page.getByText('Lifetime access', { exact: true })).toHaveCount(0)
  await page.emulateMedia({ colorScheme: 'light' })
  await page.getByRole('button', { name: 'Manage billing or cancel' }).click()
  await expect(page).toHaveURL(state.portalURL)
  expect(state.portalRequests).toBe(1); expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

test('payment recovery rejects unsafe portal redirects and still permits retry when checkout is closed', async ({ page }) => {
  const state = await backend(page, true)
  state.offer.enabled = false
  state.subscription = { ...subscriptionFixture, status: 'past_due', trial_days: 0, trial_through: null }
  state.portalURL = 'https://billing.stripe.com.attacker.invalid/session'
  await page.goto('/account')
  await expect(page.getByRole('alert')).toContainText('Payment needs attention')
  await page.getByRole('button', { name: 'Manage billing or cancel' }).click()
  await expect(page.getByRole('alert').filter({ hasText: 'address could not be verified' })).toBeVisible()
  await expect(page).toHaveURL(/\/account$/)
  state.portalURL = 'https://billing.stripe.com/p/session/fixture'
  await page.getByRole('button', { name: 'Manage billing or cancel' }).click()
  await expect(page).toHaveURL(state.portalURL)
  expect(state.portalRequests).toBe(2); expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

test('ended subscription can restart only with server authorization and refreshes used trial terms', async ({ page }) => {
  const state = await backend(page, true)
  state.offer = { ...annualOffer, trial_days: 0 }; state.statusOffer = { ...annualOffer }
  state.status = 'fulfilled'; state.statusCanStartNew = true
  state.subscription = { ...subscriptionFixture, status: 'canceled' }
  await retainCheckout(page)
  await page.goto('/account?checkout=processing')
  await expect(page.getByText('Your previous subscription has ended. You can start a new subscription.')).toBeVisible()
  await page.getByRole('button', { name: 'Start a new checkout attempt' }).click()
  await expect(page.locator('p.text-lg.font-semibold')).toContainText('$39.99 / year USD')
  await expect(page.locator('p.text-lg.font-semibold')).not.toContainText('days free')
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toBeEnabled()
  expect(await page.evaluate(() => sessionStorage.getItem('mm_checkout_fixtureuser1234'))).toBe(null)
  await expect(page.getByRole('button', { name: 'View billing history' })).toBeVisible()
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})

test('canceling renewal explains the access end without offering a second purchase', async ({ page }) => {
  const state = await backend(page, true)
  state.active = true; state.subscription = { ...subscriptionFixture, status: 'active', trial_through: null,
    paid_through: '2027-02-04T12:00:00Z', cancel_at_period_end: true }
  await page.goto('/account')
  await expect(page.getByRole('region', { name: 'Subscription billing' })).toContainText(/Renewal is canceled.*Access ends/)
  await expect(page.getByRole('button', { name: 'Continue to checkout' })).toHaveCount(0)
  expect(state.checkoutRequests).toHaveLength(0); expect(state.unexpected).toEqual([])
})
