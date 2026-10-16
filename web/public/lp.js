/* MacMint landing-page split test + funnel beacon. Loaded synchronously in <head> so a
 * redirect to the assigned variant happens before anything renders.
 *
 * - Visitors get a sticky variant ("home" = /, "home2" = /home2). ?variant=home2 forces one (QA).
 * - When SPLIT_ENABLED, first-time visitors to / are split 50/50; visiting a variant URL directly
 *   assigns that variant.
 * - Events go to PocketBase `site_events`; failures are ignored so the page never breaks.
 * - No PII: a random visitor id in localStorage, the path, referrer, and UTM tags.
 * - ?mm_qa=1 marks this browser as internal (never tracked); ?mm_qa=0 clears it.
 */
(function () {
  'use strict'
  var SPLIT_ENABLED = false
  var TRACKING_ENABLED = true
  var PB_URL = 'https://macmint.cloudpod.pro'
  var VARIANTS = { home: '/', home2: '/home2' }
  var KEY_VARIANT = 'mm_lp_variant'
  var KEY_VISITOR = 'mm_visitor'
  var KEY_UTM = 'mm_utm'

  var store = {
    get: function (k) { try { return window.localStorage.getItem(k) } catch (e) { return null } },
    set: function (k, v) { try { window.localStorage.setItem(k, v) } catch (e) { /* private mode */ } }
  }

  var randomId = function () {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID()
    return 'v' + Date.now().toString(36) + Math.random().toString(36).slice(2, 12)
  }

  var visitor = store.get(KEY_VISITOR)
  if (!visitor) { visitor = randomId(); store.set(KEY_VISITOR, visitor) }

  var params = new URLSearchParams(window.location.search)
  if (params.get('mm_qa') === '1') store.set('mm_qa', '1')
  if (params.get('mm_qa') === '0') store.set('mm_qa', '')
  var isQA = store.get('mm_qa') === '1'
  var path = window.location.pathname.replace(/\/+$/, '') || '/'
  var pageVariant = null
  Object.keys(VARIANTS).forEach(function (name) { if (VARIANTS[name] === path) pageVariant = name })

  // First-touch UTM tags are kept so a later sign-up is attributed to the original campaign.
  if (!store.get(KEY_UTM) && (params.get('utm_source') || params.get('utm_campaign'))) {
    store.set(KEY_UTM, JSON.stringify({
      utm_source: (params.get('utm_source') || '').slice(0, 100),
      utm_medium: (params.get('utm_medium') || '').slice(0, 100),
      utm_campaign: (params.get('utm_campaign') || '').slice(0, 100)
    }))
  }

  var forced = params.get('variant')
  var variant = store.get(KEY_VARIANT)
  if (forced && VARIANTS[forced]) {
    variant = forced
  } else if (!variant && pageVariant) {
    var splitHere = SPLIT_ENABLED && pageVariant === 'home'
    variant = splitHere ? (Math.random() < 0.5 ? 'home' : 'home2') : pageVariant
  }
  if (variant) store.set(KEY_VARIANT, variant)

  // Send landing visitors to their assigned page (keeping query string for UTM/ads).
  if (SPLIT_ENABLED && pageVariant && variant && variant !== pageVariant && !forced) {
    window.location.replace(VARIANTS[variant] + window.location.search + window.location.hash)
    return
  }

  var track = function (event, extra) {
    if (!TRACKING_ENABLED || isQA) return
    var utm = {}
    try { utm = JSON.parse(store.get(KEY_UTM) || '{}') } catch (e) { utm = {} }
    var body = {
      event: event,
      variant: store.get(KEY_VARIANT) || 'none',
      visitor: visitor,
      path: path.slice(0, 200),
      referrer: (document.referrer || '').slice(0, 300),
      target: ((extra && extra.target) || '').slice(0, 200),
      utm_source: utm.utm_source || '',
      utm_medium: utm.utm_medium || '',
      utm_campaign: utm.utm_campaign || ''
    }
    try {
      fetch(PB_URL + '/api/collections/site_events/records', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        keepalive: true
      }).catch(function () { /* ignore */ })
    } catch (e) { /* ignore */ }
  }

  window.MacMintLP = { track: track, variant: function () { return store.get(KEY_VARIANT) }, visitor: visitor }

  if (pageVariant) {
    track('view')
    // CTA clicks: anything heading to sign-up, sign-in, pricing, account, or download.
    document.addEventListener('click', function (e) {
      var el = e.target && e.target.closest ? e.target.closest('a,button') : null
      if (!el) return
      var href = el.getAttribute('href') || ''
      var label = (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 80)
      if (/\/(signup|login|account)|#pricing|download|checkout|buy/i.test(href + ' ' + label)) {
        track('cta', { target: (href || label).slice(0, 200) })
      }
    }, true)
  }
})()
