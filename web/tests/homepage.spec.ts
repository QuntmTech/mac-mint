import { test, expect } from '@playwright/test'

test('the main homepage has the full design and working account navigation', async ({ page }) => {
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
  await page.getByRole('button', { name: 'Check availability', exact: true }).first().click()
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
