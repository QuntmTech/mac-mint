import { test, expect, type Page } from '@playwright/test'

// Every remote request is intercepted. These are browser protocol fixtures, not real accounts.
async function backend(page: Page, signedIn = false, verified = true) {
  const user = { id: 'fixtureuser1234', email: 'fixture@example.invalid', name: 'Fixture', verified,
    collectionId: '_pb_users_auth_', collectionName: 'users' }
  const token = [{ alg: 'HS256', typ: 'JWT' }, { exp: Math.floor(Date.now() / 1000) + 3600,
    id: user.id, collectionId: user.collectionId, type: 'auth' }]
    .map(value => Buffer.from(JSON.stringify(value)).toString('base64url')).join('.') + '.fixture'
  const state = { user, token, verificationAttempts: 0, verificationFails: false,
    checkoutRequests: [] as { request_key: string }[], analytics: 0, unexpected: [] as string[] }
  if (signedIn) await page.addInitScript(auth => {
    if (location.origin === 'http://127.0.0.1:4173') localStorage.setItem('pocketbase_auth', JSON.stringify(auth))
  }, { token, record: user })
  await page.route('**/*', async route => {
    const url = new URL(route.request().url())
    if (url.origin === 'http://127.0.0.1:4173') return route.continue()
    if (url.origin === 'https://checkout.stripe.com') return route.fulfill({ contentType: 'text/html', body: '<h1>Local checkout fixture</h1>' })
    if (url.origin !== 'https://macmint.cloudpod.pro') {
      state.unexpected.push(url.origin); return route.abort()
    }
    const path = url.pathname
    const respond = (body: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
    if (path.endsWith('/auth-refresh')) return respond({ token, record: user })
    if (path === '/api/macmint/me') return respond({ user, entitlement: { plan: 'free', active: false,
      status: 'active', expires_at: null, max_devices: 0, source: 'signup' }, devices: [], server_time: new Date().toISOString() })
    if (path.includes('/app_releases/records')) return respond({ page: 1, perPage: 1, totalItems: 0, totalPages: 0, items: [] })
    if (path === '/api/macmint/checkout/config') return respond({ enabled: true, duration_days: 365, max_devices: 3 })
    if (path === '/api/macmint/checkout') {
      state.checkoutRequests.push(route.request().postDataJSON())
      return respond({ url: state.checkoutRequests.length === 1 ? 'https://attacker.invalid/checkout' : 'https://checkout.stripe.com/c/pay/cs_test_fixture' })
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
  await page.getByRole('button', { name: 'Continue to checkout' }).click()
  await expect(page).toHaveURL('https://checkout.stripe.com/c/pay/cs_test_fixture')
  expect(state.checkoutRequests).toHaveLength(2)
  expect(state.checkoutRequests[0].request_key).toBe(state.checkoutRequests[1].request_key)
  await page.goto('/account?checkout=processing')
  await expect(page.getByText('No active plan', { exact: true })).toBeVisible()
  await expect(page.getByRole('status')).toContainText('after Stripe confirms payment')
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
