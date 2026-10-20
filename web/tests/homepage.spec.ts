import { test, expect } from '@playwright/test'

test('the main homepage has the full design and working account navigation', async ({ page }) => {
  // Several document navigations; individual UI assertions retain the default 5s limit.
  test.setTimeout(60_000)
  const errors: string[] = []
  const failedAssets: string[] = []
  page.on('pageerror', error => errors.push(error.message))
  page.on('response', response => {
    if (response.url().includes('/_next/') && response.status() >= 400) failedAssets.push(response.url())
  })
  await page.goto('/')
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/Put your Mac back.*mint condition/)
  await expect(page.getByText('A cleaner Mac, without the guesswork.')).toHaveCount(0)
  for (const id of ['features', 'how-it-works', 'safety', 'privacy', 'developers', 'faq']) {
    await expect(page.locator('#' + id)).toHaveCount(1)
  }
  await expect(page.locator('link[rel="canonical"]')).toHaveAttribute('href', 'https://macmint.co')
  await expect(page.getByRole('button', { name: 'Check availability', exact: true })).toHaveCount(0)
  await expect(page.locator('.hero-actions').getByRole('link', { name: 'Start free trial' })).toHaveAttribute('href', '/start')
  await page.getByRole('button', { name: 'Privacy notes' }).click()
  await expect(page.getByRole('dialog')).toBeVisible()
  await page.getByRole('button', { name: 'Close dialog' }).click()
  await page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Sign in', exact: true }).click()
  await expect(page).toHaveURL(/\/login$/)
  await expect(page.getByRole('heading', { name: 'Sign in', exact: true })).toBeVisible()
  await page.getByRole('navigation').getByRole('link', { name: 'MacMint home', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/Put your Mac back.*mint condition/)
  await page.goto('/login')
  await page.getByRole('main').getByRole('link', { name: 'MacMint home', exact: true }).click()
  await expect(page.getByRole('heading', { level: 1 })).toHaveText(/Put your Mac back.*mint condition/)
  expect(failedAssets).toEqual([])
  expect(errors).toEqual([])
})

test('the old home2 address redirects while preserving campaign parameters and anchors', async ({ page, request }) => {
  for (const path of ['/home2', '/home2/']) {
    const response = await request.get(path + '?utm_source=existing-link', { maxRedirects: 0 })
    expect(response.status()).toBe(301)
    expect(response.headers().location).toBe('/?utm_source=existing-link')
  }
  await page.goto('/home2?utm_source=existing-link#faq')
  await expect(page).toHaveURL('http://127.0.0.1:4173/?utm_source=existing-link#faq')
  await expect(page.locator('#faq')).toBeVisible()
})

test('the promoted homepage hydrates and fits a phone viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.goto('/')
  const menu = page.getByRole('button', { name: 'Open menu', exact: true })
  await menu.click()
  await expect(page.getByRole('button', { name: 'Close menu', exact: true })).toHaveAttribute('aria-expanded', 'true')
  await page.locator('#mobile-nav').getByRole('link', { name: 'Features' }).click()
  await expect(page.locator('#mobile-nav')).toHaveCount(0)
  await page.getByRole('combobox', { name: 'Choose a product demo' }).selectOption('apps')
  await expect(page.locator('#product-demo')).toContainText('Applications')
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
})

test('search metadata and missing-page status are served as static documents', async ({ request }) => {
  const robots = await request.get('/robots.txt')
  expect(robots.status()).toBe(200)
  expect(await robots.text()).toContain('Sitemap: https://macmint.co/sitemap.xml')
  const sitemap = await request.get('/sitemap.xml')
  expect(sitemap.status()).toBe(200)
  expect(await sitemap.text()).toContain('<loc>https://macmint.co/</loc>')
  const missing = await request.get('/this-page-does-not-exist')
  expect(missing.status()).toBe(404)
  expect(await missing.text()).not.toContain('id="root"')
})

test('the main homepage remains readable without JavaScript', async ({ browser }) => {
  const context = await browser.newContext({ javaScriptEnabled: false })
  try {
    const page = await context.newPage()
    await page.goto('http://127.0.0.1:4173/')
    await expect(page.getByRole('heading', { level: 1 })).toHaveText(/Put your Mac back.*mint condition/)
    await expect(page.locator('#features')).toBeVisible()
    await expect(page.getByRole('navigation', { name: 'Main navigation' }).getByRole('link', { name: 'Sign in', exact: true })).toHaveAttribute('href', '/login')
  } finally {
    await context.close()
  }
})

for (const viewport of [{ width: 1440, height: 1000 }, { width: 390, height: 844 }]) {
  test(`the guided demo completes scan, edited review and recovery at ${viewport.width}px`, async ({ page }) => {
    // Budget the full user journey separately from each state assertion.
    test.setTimeout(60_000)
    await page.setViewportSize(viewport)
    const errors: string[] = []
    const writes: string[] = []
    page.on('pageerror', error => errors.push(error.message))
    page.on('request', request => {
      if (!['GET', 'HEAD', 'OPTIONS'].includes(request.method())) writes.push(request.url())
    })
    await page.goto('/')
    const demo = page.locator('#product-demo')
    await expect(demo.getByText('Demo scan complete.', { exact: false })).toHaveCount(0)
    await demo.getByRole('button', { name: 'Run Quick Scan', exact: true }).click()
    await expect(demo.getByRole('progressbar')).toBeVisible()
    await expect(demo.getByRole('button', { name: 'Review 6.4 GB', exact: true })).toBeVisible()
    const browserCaches = demo.getByRole('checkbox', { name: 'Browser caches, 1.6 GB', exact: true })
    const backup = demo.getByRole('checkbox', { name: 'Device backups, 1.2 GB', exact: true })
    await expect(backup).not.toBeChecked()
    await demo.getByRole('button', { name: 'Review 6.4 GB', exact: true }).click()
    const review = demo.getByRole('region', { name: 'Your cleanup. Your final say.' })
    await expect(review).toBeFocused()
    await browserCaches.uncheck()
    await expect(review).toContainText('4.8 GB selected')
    await review.getByRole('button', { name: 'Move to demo Trash', exact: true }).click()
    const outcome = demo.getByRole('region', { name: 'Room to change your mind.' })
    await expect(outcome).toContainText('4.8 GB')
    await expect(outcome).toContainText('Free space hasn’t changed yet.')
    await outcome.getByRole('button', { name: 'Restore these files', exact: true }).click()
    const restored = demo.getByRole('region', { name: 'Back where they started.' })
    await expect(restored).toBeFocused()
    await expect(restored.getByRole('link', { name: 'Start free trial', exact: true })).toHaveAttribute('href', '/start')
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    expect(errors).toEqual([])
    expect(writes).toEqual([])
  })
}

test('rescanning preserves Trash receipts and cancelled scans preserve choices', async ({ page }) => {
  test.setTimeout(60_000)
  await page.goto('/')
  const demo = page.locator('#product-demo')
  await demo.getByRole('button', { name: 'Run Quick Scan', exact: true }).click()
  await demo.getByRole('button', { name: 'Review 6.4 GB', exact: true }).click()
  await demo.getByRole('button', { name: 'Move to demo Trash', exact: true }).click()
  await demo.getByRole('button', { name: 'Back to results', exact: true }).click()
  await demo.getByRole('button', { name: 'Scan again', exact: true }).click()
  await expect(demo.getByRole('progressbar')).toHaveCount(0)
  await expect(demo.getByRole('checkbox')).toHaveCount(1)
  await expect(demo.getByRole('checkbox', { name: 'Device backups, 1.2 GB', exact: true })).not.toBeChecked()
  await demo.getByRole('checkbox', { name: 'Device backups, 1.2 GB', exact: true }).check()
  await demo.getByRole('button', { name: 'Scan again', exact: true }).click()
  await demo.getByRole('button', { name: 'Cancel', exact: true }).click()
  await expect(demo.getByRole('checkbox', { name: 'Device backups, 1.2 GB', exact: true })).toBeChecked()
  await demo.getByRole('navigation', { name: 'Product demo modules' }).getByRole('button', { name: 'History', exact: true }).click()
  await demo.getByRole('button', { name: 'Restore files', exact: true }).click()
  await expect(demo.getByRole('button', { name: 'Files restored', exact: true })).toBeFocused()
  await expect(demo).toContainText('6.4 GB moved to demo Trash')
  await demo.getByText('4 categories · View receipt', { exact: true }).click()
  await expect(demo.locator('.demo-history-entry li')).toHaveCount(4)
  await demo.getByRole('navigation', { name: 'Product demo modules' }).getByRole('button', { name: 'Cleaner', exact: true }).click()
  await expect(demo.getByRole('checkbox')).toHaveCount(5)
})

test('phone transitions reveal the next screen and Back preserves edited review choices', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await page.goto('/')
  const demo = page.locator('#product-demo')
  await page.getByRole('combobox', { name: 'Choose a product demo' }).selectOption('cleaner')
  await demo.getByRole('checkbox', { name: 'Device backups, 1.2 GB', exact: true }).check()
  await demo.getByRole('button', { name: 'Review 7.6 GB', exact: true }).click()
  await expect(demo.locator('#demo-review-heading')).toBeInViewport({ ratio: 1 })
  await expect(demo.getByRole('region')).toContainText('including 1.2 GB of review items')
  await demo.getByRole('checkbox', { name: 'Browser caches, 1.6 GB', exact: true }).uncheck()
  await demo.getByRole('button', { name: 'Back to results', exact: true }).click()
  const trigger = demo.getByRole('button', { name: 'Review 6.0 GB', exact: true })
  await expect(trigger).toBeFocused()
  await expect(trigger).toBeInViewport({ ratio: 1 })
  await trigger.click()
  await demo.getByRole('button', { name: 'Move to demo Trash', exact: true }).click()
  await expect(demo.locator('#demo-outcome-heading')).toBeInViewport({ ratio: 1 })
  await demo.getByRole('button', { name: 'Restore these files', exact: true }).click()
  await expect(demo.locator('#demo-outcome-heading')).toHaveText('Back where they started.')
  await expect(demo.locator('#demo-outcome-heading')).toBeInViewport({ ratio: 1 })
})
