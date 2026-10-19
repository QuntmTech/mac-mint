// Explicit per-client rate limits for abuse-prone routes.
//
// PocketBase keys each limiter by e.realIP(). Behind a reverse proxy, without
// settings.trustedProxy.headers every request appears to come from the proxy, so a
// per-IP limit becomes a global limit that throttles every customer at once. The
// header name depends on the proxy and must be confirmed by the operator, so this
// migration never guesses it: the rules are installed, but limiting is only switched
// on when trusted proxy headers are already configured (or the operator had already
// enabled limits). Otherwise enable them in Settings → Rate limits after setting the
// trusted proxy header (docs/RELEASING.md, deploy checklist).
const RULES = [
  // Stripe redelivers signed events from a few addresses; keep webhooks out of /api/.
  { label: "/api/macmint/stripe/webhook", maxRequests: 1000, duration: 1 },
  { label: "users:authWithPassword", maxRequests: 10, duration: 60 },
  // Every auth method on every auth collection, including superuser sign-in.
  { label: "*:auth", maxRequests: 10, duration: 60 },
  { label: "users:create", maxRequests: 5, duration: 600 },
  { label: "*:requestPasswordReset", maxRequests: 5, duration: 600 },
  { label: "*:requestVerification", maxRequests: 5, duration: 600 },
  { label: "*:requestEmailChange", maxRequests: 5, duration: 600 },
  { label: "*:requestOTP", maxRequests: 5, duration: 600 },
  { label: "*:confirmPasswordReset", maxRequests: 10, duration: 600 },
  { label: "*:confirmVerification", maxRequests: 10, duration: 600 },
  { label: "site_events:create", maxRequests: 30, duration: 60 },
  { label: "*:create", maxRequests: 20, duration: 5 },
  { label: "/api/macmint/redeem", maxRequests: 10, duration: 600 },
  { label: "/api/macmint/devices/activate", maxRequests: 20, duration: 600 },
  { label: "/api/macmint/checkout", maxRequests: 10, duration: 600 },
  // Each call creates a Stripe billing portal session.
  { label: "/api/macmint/billing/portal", maxRequests: 10, duration: 600 },
  // Prefix rules match in list order: keep specific prefixes before /api/.
  { label: "/api/macmint/ai/", maxRequests: 30, duration: 60 },
  { label: "/api/batch", maxRequests: 3, duration: 1 },
  { label: "/api/", maxRequests: 600, duration: 60 },
]

migrate(app => {
  const settings = app.settings()
  const ours = RULES.map(rule => rule.label)
  // Preserve unrelated operator rules. Same-label rules (any audience) would conflict.
  const kept = []
  for (const rule of settings.rateLimits.rules || []) {
    if (ours.indexOf(rule.label) < 0) kept.push({ label: rule.label, audience: rule.audience, maxRequests: rule.maxRequests, duration: rule.duration })
  }
  settings.rateLimits.rules = RULES.map(rule => Object.assign({ audience: "" }, rule)).concat(kept)
  const proxied = ((settings.trustedProxy && settings.trustedProxy.headers) || []).length > 0
  if (!settings.rateLimits.enabled && proxied) settings.rateLimits.enabled = true
  app.save(settings)
  if (!settings.rateLimits.enabled) {
    app.logger().warn("macmint: rate limit rules installed but not enabled; configure settings.trustedProxy, then enable rate limits")
  } else if (!proxied) {
    app.logger().warn("macmint: rate limits are enabled without trusted proxy headers; behind a proxy every client shares one limit")
  }
}, () => {
  // Leave limits in place on rollback; the operator can disable them in settings.
})
