import { test, expect, type Page } from '@playwright/test'

// Every remote request is intercepted: protocol fixtures for the plan page, the Payment Link
// redirect, the /welcome claim and the /download feed. No real Stripe, GitHub or accounts.
const SESSION = 'cs_test_fixturesession123'
const DMG = 'https://github.com/QuntmTech/mac-mint/releases/download/v1.4.0/MacMint.dmg'
const tiers = () => [
  { tier: 'mac1', devices: 1, amount_minor: 3995, currency: 'usd', trial_days: 7, billing_interval: 'year', billing_interval_count: 1 },
  { tier: 'mac2', devices: 2, amount_minor: 5995, currency: 'usd', trial_days: 7, billing_interval: 'year', billing_interval_count: 1 },
  { tier: 'mac5', devices: 5, amount_minor: 9995, currency: 'usd', trial_days: 7, billing_interval: 'year', billing_interval_count: 1 },
]

async function backend(page: Page) {
  const user = { id: 'claimeduser123', email: 'new.buyer@example.invalid', name: '', verified: true, collectionId: '_pb_users_auth_', collectionName: 'users' }
  const token = [{ alg: 'HS256', typ: 'JWT' }, { exp: Math.floor(Date.now() / 1000) + 3600, id: user.id, collectionId: user.collectionId, type: 'auth' }]
    .map(value => Buffer.from(JSON.stringify(value)).toString('base64url')).join('.') + '.fixture'
  const state = {
    plans: { enabled: true, tiers: tiers() } as { enabled: boolean; tiers?: ReturnType<typeof tiers> },
    startError: '' as '' | 'sign_in_required',
    startRequests: [] as Record<string, unknown>[],
    claimStates: ['processing', 'ready'] as string[],
    claimRequests: [] as Record<string, unknown>[],
    claimResult: 'claimed' as 'claimed' | 'existing_account',
    ownerUnverified: false, attachRequests: 0,
    download: { source: 'github', version: '1.4.0', url: DMG, size_bytes: 23456789, sha256: null, min_os: '14.0', notarized: false } as Record<string, unknown>,
    stripeVisits: [] as string[], refreshes: 0, unexpected: [] as string[], origins: new Set<string>(),
  }
  await page.route('**/*', async route => {
    const url = new URL(route.request().url())
    state.origins.add(url.origin)
    if (url.origin === 'http://127.0.0.1:4173') return route.continue()
    if (url.origin === 'https://buy.stripe.com') {
      state.stripeVisits.push(url.href)
      // Stands in for the Payment Link: complete checkout, then Stripe's after-payment redirect.
      return route.fulfill({ contentType: 'text/html', body: `<h1>Payment Link fixture</h1><script>location.href='http://127.0.0.1:4173/welcome?session_id=${SESSION}'</script>` })
    }
    if (url.origin !== 'https://macmint.cloudpod.pro') { state.unexpected.push(url.origin); return route.abort() }
    const respond = (body: unknown, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) })
    const path = url.pathname
    if (path === '/api/macmint/plans') return respond(state.plans)
    if (path === '/api/macmint/trial/start') {
      const body = route.request().postDataJSON()
      state.startRequests.push(body)
      if (state.startError) return respond({ error: state.startError, message: 'Refused by fixture' }, 409)
      const tier = { mac1: 'test_one111', mac2: 'test_two222', mac5: 'test_five55' }[body.tier as string]
      return respond({ url: `https://buy.stripe.com/${tier}?prefilled_email=${encodeURIComponent(body.email)}&client_reference_id=mmt_fixture` })
    }
    if (path === '/api/macmint/purchase/status') {
      // The session ID travels in the POST body, never in a backend URL.
      expect(route.request().method()).toBe('POST')
      expect(url.search).toBe('')
      expect(route.request().postDataJSON()).toEqual({ session_id: SESSION })
      const current = state.claimStates.length > 1 ? state.claimStates.shift()! : state.claimStates[0]
      return respond({ state: current, email: 'new.buyer@example.invalid', owner_unverified: state.ownerUnverified || undefined,
        plan: { tier: 'mac2', devices: 2, amount_minor: 5995, currency: 'usd', trial_days: 7, billing_interval: 'year' } })
    }
    if (path === '/api/macmint/purchase/attach') { state.attachRequests++; return respond({ state: 'linked', sync_pending: false }) }
    if (path === '/api/macmint/purchase/claim') {
      state.claimRequests.push(route.request().postDataJSON())
      if (state.claimResult === 'existing_account') return respond({ state: 'existing_account', email: 'new.buyer@example.invalid' })
      if (state.ownerUnverified && !route.request().postDataJSON().email) return respond({ error: 'unverified_owner', message: 'An unverified MacMint account already uses this email.' }, 409)
      return respond({ token, record: user, meta: { state: 'claimed', sync_pending: true } })
    }
    if (path === '/api/macmint/billing/refresh') { state.refreshes++; return respond({ refreshed: 1 }) }
    if (path === '/api/macmint/download') return respond(state.download)
    if (path.endsWith('/auth-refresh')) return respond({ token, record: user })
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

const noHorizontalScroll = (page: Page) => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)

test('every homepage call-to-action leads to the plan page', async ({ page }) => {
  const state = await backend(page)
  await page.goto('/')
  await expect(page.getByRole('button', { name: /check availability/i })).toHaveCount(0)
  const ctas = page.locator('a[href="/start"]')
  // Navigation, hero, final call-to-action and footer.
  await expect(ctas).toHaveCount(4)
  for (const label of ['Start free trial', 'Plans & free trial']) await expect(ctas.filter({ hasText: label }).first()).toBeVisible()
  const demo = page.locator('#product-demo')
  await demo.getByRole('button', { name: 'Run Quick Scan', exact: true }).click()
  await demo.getByRole('button', { name: 'Review 6.4 GB', exact: true }).click()
  await demo.getByRole('button', { name: 'Move to demo Trash', exact: true }).click()
  await demo.getByRole('button', { name: 'Restore these files', exact: true }).click()
  await expect(demo.getByRole('link', { name: 'Start free trial' })).toHaveAttribute('href', '/start')
  await page.setViewportSize({ width: 390, height: 844 })
  await page.getByRole('button', { name: 'Open menu', exact: true }).click()
  await expect(page.locator('#mobile-nav a[href="/start"]')).toHaveCount(1)
  await page.locator('.hero-actions').getByRole('link', { name: 'Start free trial' }).click()
  await expect(page).toHaveURL('http://127.0.0.1:4173/start')
  await expect(page.getByRole('heading', { name: 'Let’s choose your plan' })).toBeVisible()
  expect(state.unexpected).toEqual([])
})

test('tier selection updates the server-configured prices and keeps the tier for a return from Stripe', async ({ page }) => {
  const state = await backend(page)
  await page.goto('/start')
  await expect(page.getByText('MacMint Pro, Annual')).toBeVisible()
  await expect(page.getByText('One-year subscription')).toBeVisible()
  await expect(page.getByTestId('pay-now')).toHaveText('$0.00')
  await expect(page.getByTestId('after-trial')).toHaveText('After 7-day trial: $39.95/year (≈ $3.33/month), billed annually')
  await expect(page.getByRole('radio', { name: /^1 Mac,/ })).toBeChecked()
  for (const text of ['Cancel anytime', 'Secure payment', 'Instant activation']) await expect(page.getByText(text, { exact: true })).toBeVisible()
  await expect(page.getByTestId('fine-print')).toContainText('renews automatically and $39.95 per year')
  await page.getByText('2 Macs', { exact: true }).click()
  await expect(page.getByTestId('after-trial')).toHaveText('After 7-day trial: $59.95/year (≈ $5.00/month), billed annually')
  await expect(page.getByText('Save 25% per Mac')).toBeVisible()
  await page.getByText('5 Macs', { exact: true }).click()
  await expect(page.getByTestId('after-trial')).toHaveText('After 7-day trial: $99.95/year (≈ $8.33/month), billed annually')
  await expect(page.getByText('Save 50% per Mac')).toBeVisible()
  await expect(page).toHaveURL(/\/start\?tier=mac5$/)
  await page.reload()
  await expect(page.getByRole('radio', { name: /^5 Macs,/ })).toBeChecked()
  // Displayed prices are the server's, never constants in the page.
  state.plans = { enabled: true, tiers: tiers().map(tier => ({ ...tier, amount_minor: tier.amount_minor + 1000 })) }
  await page.reload()
  await expect(page.getByTestId('after-trial')).toContainText('$109.95/year')
  state.plans = { enabled: false }
  await page.reload()
  await expect(page.getByText('Checkout isn’t open yet.', { exact: false })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Start free trial' })).toHaveCount(0)
  expect(state.startRequests).toEqual([]); expect(state.unexpected).toEqual([])
})

test('start → Payment Link → /welcome sets a password → /download shows the DMG', async ({ page, request }) => {
  const state = await backend(page)
  await page.goto('/start?tier=mac2')
  await page.getByLabel('Email').fill('New.Buyer@example.invalid')
  await page.getByRole('button', { name: 'Start free trial' }).click()
  await expect(page.getByRole('heading', { name: 'Finishing your purchase…' })).toBeVisible()
  expect(state.startRequests).toEqual([{ email: 'New.Buyer@example.invalid', tier: 'mac2' }])
  const link = new URL(state.stripeVisits[0])
  expect(link.origin + link.pathname).toBe('https://buy.stripe.com/test_two222')
  expect(link.searchParams.get('prefilled_email')).toBe('New.Buyer@example.invalid')
  // The session ID leaves the address bar; the webhook lands while the page waits.
  await expect(page).toHaveURL('http://127.0.0.1:4173/welcome')
  await expect(page.getByRole('heading', { name: 'Create your password' })).toBeVisible({ timeout: 8000 })
  await expect(page.getByTestId('billing-email')).toHaveText('new.buyer@example.invalid')
  await expect(page.getByText('MacMint Pro for 2 Macs · 7-day trial, then $59.95/year')).toBeVisible()
  expect(await page.evaluate(() => document.querySelector('meta[name="referrer"]')?.getAttribute('content'))).toBe('no-referrer')
  await page.getByLabel('Password', { exact: true }).fill('a-strong-password-1')
  await page.getByLabel('Confirm password').fill('a-different-password')
  await page.getByRole('button', { name: 'Create account and continue' }).click()
  await expect(page.getByRole('alert')).toContainText('don’t match')
  await page.getByLabel('Confirm password').fill('a-strong-password-1')
  await page.getByRole('button', { name: 'Create account and continue' }).click()
  await expect(page).toHaveURL('http://127.0.0.1:4173/download?welcome=1')
  expect(state.claimRequests).toEqual([{ session_id: SESSION, password: 'a-strong-password-1' }])
  expect(state.refreshes).toBe(1)
  await expect(page.getByRole('status').filter({ hasText: 'Your account is ready' })).toBeVisible()
  const download = page.getByRole('link', { name: 'Download MacMint for Mac' })
  await expect(download).toHaveAttribute('href', DMG)
  await expect(page.getByTestId('download-details')).toHaveText('Version 1.4.0 · 22.4 MB · MacMint.dmg')
  for (const text of ['Requires macOS 14 or later', 'Apple Silicon and Intel', 'Drag MacMint to Applications', 'Sign in with your email']) await expect(page.getByText(text, { exact: true })).toBeVisible()
  await expect(page.getByTestId('gatekeeper-note')).toContainText('Open Anyway')
  await expect(page.getByText('new.buyer@example.invalid', { exact: false })).toBeVisible()
  expect(await page.evaluate(() => localStorage.getItem('pocketbase_auth'))).toContain('claimeduser123')
  // Only this site, the account API and the Stripe link are ever contacted.
  expect([...state.origins].sort()).toEqual(['http://127.0.0.1:4173', 'https://buy.stripe.com', 'https://macmint.cloudpod.pro'])
  for (const path of ['/start', '/welcome', '/download']) expect((await request.get(path)).headers()['referrer-policy']).toBe('no-referrer')
  expect(state.unexpected).toEqual([])
})

test('a notarized feed release hides the Gatekeeper note and untrusted URLs are never linked', async ({ page }) => {
  const state = await backend(page)
  state.download = { source: 'feed', version: '1.5.0', url: DMG.replace('v1.4.0', 'v1.5.0'), size_bytes: 1048576, min_os: '14.0', notarized: true }
  await page.goto('/download')
  await expect(page.getByRole('link', { name: 'Download MacMint for Mac' })).toBeVisible()
  await expect(page.getByTestId('gatekeeper-note')).toHaveCount(0)
  state.download = { source: 'github', version: '9.9.9', url: 'https://objects.githubusercontent.com/evil/MacMint.dmg', notarized: false }
  await page.reload()
  await expect(page.getByText('The installer isn’t published yet.', { exact: false })).toBeVisible()
  await expect(page.getByRole('link', { name: 'Download MacMint for Mac' })).toHaveCount(0)
  expect(state.unexpected).toEqual([])
})

test('an existing account is linked, not duplicated, and the buyer is asked to sign in', async ({ page }) => {
  const state = await backend(page)
  state.claimStates = ['existing_account']
  await page.goto(`/welcome?session_id=${SESSION}`)
  await expect(page.getByRole('heading', { name: 'Your trial is on your account' })).toBeVisible()
  await expect(page.getByText('new.buyer@example.invalid', { exact: false })).toBeVisible()
  await expect(page.getByLabel('Password', { exact: true })).toHaveCount(0)
  await page.getByRole('main').getByRole('link', { name: 'Sign in', exact: true }).click()
  await expect(page).toHaveURL(/\/login\?next=%2Fdownload|\/login\?next=\/download/)
  expect(state.claimRequests).toEqual([])

  // An account that appears between the webhook and the claim is linked by the server too.
  state.claimStates = ['ready']; state.claimResult = 'existing_account'
  await page.goto(`/welcome?session_id=${SESSION}`)
  await page.getByRole('button', { name: 'Use a different sign-in email' }).click()
  await page.getByLabel('Sign-in email').fill('other@example.invalid')
  await page.getByLabel('Password', { exact: true }).fill('a-strong-password-1')
  await page.getByLabel('Confirm password').fill('a-strong-password-1')
  await page.getByRole('button', { name: 'Create account and continue' }).click()
  await expect(page.getByRole('heading', { name: 'Your trial is on your account' })).toBeVisible()
  expect(state.claimRequests).toEqual([{ session_id: SESSION, password: 'a-strong-password-1', email: 'other@example.invalid' }])
  expect(await page.evaluate(() => localStorage.getItem('pocketbase_auth'))).toBeNull()
  expect(state.unexpected).toEqual([])
})

test('a used trial or existing plan is refused before Stripe with a generic sign-in path', async ({ page }) => {
  const state = await backend(page)
  state.startError = 'sign_in_required'
  await page.goto('/start')
  await page.getByLabel('Email').fill('veteran@example.invalid')
  await page.getByRole('button', { name: 'Start free trial' }).click()
  const notice = page.getByRole('status').filter({ hasText: 'can’t start another free trial' })
  await expect(notice).toBeVisible()
  await expect(notice.getByRole('link', { name: 'Sign in' })).toHaveAttribute('href', '/login?next=/account')
  expect(state.stripeVisits).toEqual([])
  expect(state.unexpected).toEqual([])
})

test('a purchase blocked by an unverified account for the email offers another sign-in email', async ({ page }) => {
  const state = await backend(page)
  state.claimStates = ['ready']; state.ownerUnverified = true
  await page.goto(`/welcome?session_id=${SESSION}`)
  await expect(page.getByRole('status').filter({ hasText: 'An unverified MacMint account already uses new.buyer@example.invalid' })).toBeVisible()
  await expect(page.getByRole('button', { name: 'Add this purchase to my account' })).toHaveCount(0)
  await page.getByLabel('Password', { exact: true }).fill('a-strong-password-1')
  await page.getByLabel('Confirm password').fill('a-strong-password-1')
  await page.getByRole('button', { name: 'Create account and continue' }).click()
  await expect(page.getByRole('alert')).toContainText('unverified MacMint account')
  await page.getByLabel('Sign-in email').fill('real.buyer@example.invalid')
  await page.getByRole('button', { name: 'Create account and continue' }).click()
  await expect(page).toHaveURL('http://127.0.0.1:4173/download?welcome=1')
  expect(state.claimRequests.at(-1)).toEqual({ session_id: SESSION, password: 'a-strong-password-1', email: 'real.buyer@example.invalid' })
  expect(state.attachRequests).toBe(0); expect(state.unexpected).toEqual([])
})

test('the plan, welcome and download pages fit a phone viewport', async ({ page }) => {
  const state = await backend(page)
  state.claimStates = ['ready']
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/start')
  await expect(page.getByRole('button', { name: 'Start free trial' })).toBeVisible()
  await page.getByText('2 Macs', { exact: true }).click()
  await expect(page.getByTestId('after-trial')).toContainText('$59.95/year')
  expect(await noHorizontalScroll(page)).toBe(true)
  await page.goto(`/welcome?session_id=${SESSION}`)
  await expect(page.getByRole('heading', { name: 'Create your password' })).toBeVisible()
  expect(await noHorizontalScroll(page)).toBe(true)
  await page.goto('/download')
  await expect(page.getByRole('link', { name: 'Download MacMint for Mac' })).toBeVisible()
  expect(await noHorizontalScroll(page)).toBe(true)
  expect(state.unexpected).toEqual([])
})
