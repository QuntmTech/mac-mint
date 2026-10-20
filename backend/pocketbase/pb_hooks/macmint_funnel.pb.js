// Plan page → Stripe Payment Link → /welcome account claim → /download.
//
// GET  /api/macmint/plans                        public tiers from server configuration
// POST /api/macmint/trial/start                  { email, tier } -> { url } or 409 trial_used/active_plan
// GET  /api/macmint/purchase/claim?session_id=   claim state for /welcome (polls while the webhook lands)
// POST /api/macmint/purchase/claim               { session_id, password, email? } -> signed-in account
// POST /api/macmint/billing/refresh              (user) re-sync ongoing subscriptions from Stripe
// GET  /api/macmint/download                     validated installer for /download
// POST /api/macmint/admin/purchase/link          (superuser) { session, user } recovery link

routerAdd("GET", "/api/macmint/plans", e => {
  require(`${__hooks}/macmint_lib.js`).noStore(e)
  try { return e.json(200, require(`${__hooks}/macmint_funnel.js`).plans(e.app)) }
  catch (_) { return e.json(200, { enabled: false }) }
})

routerAdd("POST", "/api/macmint/trial/start", e => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const data = lib.body(e)
  try { return e.json(200, require(`${__hooks}/macmint_funnel.js`).start(e.app, { email: data.email, tier: data.tier })) }
  catch (error) {
    if (error.code === "bad_request") return e.json(400, { error: "bad_request", message: "Enter a valid email address and choose how many Macs." })
    if (error.code === "trial_used") return e.json(409, { error: "trial_used", message: "This email has already used its free trial. Sign in to buy MacMint Pro without a trial." })
    if (error.code === "active_plan") return e.json(409, { error: "active_plan", message: "This email already has an active MacMint plan. Sign in to manage it." })
    if (error.code === "closed") return e.json(503, { error: "checkout_closed", message: "Checkout is not open yet. Local scanning and recovery do not require a paid plan." })
    return e.json(503, { error: "checkout_unavailable", message: "Checkout could not be opened. Please try again later." })
  }
})

routerAdd("GET", "/api/macmint/purchase/claim", e => {
  require(`${__hooks}/macmint_lib.js`).noStore(e)
  e.response.header().set("Referrer-Policy", "no-referrer")
  const sessionId = String(e.request.url.query().get("session_id") || "")
  try { return e.json(200, require(`${__hooks}/macmint_funnel.js`).status(e.app, sessionId)) }
  catch (error) {
    if (error.code === "bad_request") return e.json(400, { error: "bad_request", message: "This setup link is incomplete." })
    return e.json(503, { error: "claim_unavailable", message: "Your purchase could not be checked. Please retry." })
  }
})

routerAdd("POST", "/api/macmint/purchase/claim", e => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  e.response.header().set("Referrer-Policy", "no-referrer")
  const data = lib.body(e)
  let result
  try { result = require(`${__hooks}/macmint_funnel.js`).claim(e.app, { session_id: data.session_id, password: data.password, email: data.email }) }
  catch (error) {
    const known = {
      bad_request: [400, "This setup link is incomplete."],
      weak_password: [400, "Use a password of 8 to 71 characters."],
      bad_email: [400, "Enter a valid sign-in email address."],
      processing: [202, "Your purchase is still being confirmed. Wait a moment and try again."],
      not_found: [404, "No MacMint purchase matches this link."],
      expired: [410, "This setup link has expired. Contact support@macmint.co with your Stripe receipt."],
      already_claimed: [409, "This purchase already has an account. Sign in with the email you chose."],
      existing_account: [409, "This purchase was added to your existing MacMint account. Sign in to continue."],
      email_taken: [409, "That email already belongs to a MacMint account. Choose another email, or keep your billing email."],
      attention: [409, "This purchase needs a quick review before it can be set up. Contact support@macmint.co; do not pay again."],
    }[error.code]
    if (known) return e.json(known[0], { error: error.code, message: known[1] })
    return e.json(503, { error: "claim_unavailable", message: "Your account could not be created. Nothing was changed; please retry." })
  }
  if (result.outcome === "existing_account") return e.json(200, { state: "existing_account", email: result.email })
  if (result.outcome !== "claimed") return e.json(409, { error: "attention", message: "This purchase needs a quick review before it can be set up. Contact support@macmint.co; do not pay again." })
  return $apis.recordAuthResponse(e, e.app.findRecordById("users", result.userId), "password", { state: "claimed", sync_pending: result.syncPending, plan: result.plan })
})

routerAdd("POST", "/api/macmint/billing/refresh", e => {
  require(`${__hooks}/macmint_lib.js`).noStore(e)
  try { return e.json(200, { refreshed: require(`${__hooks}/macmint_funnel.js`).refresh(e.app, e.auth.id) }) }
  catch (_) { return e.json(503, { error: "billing_sync_pending", message: "Your subscription is still being confirmed. Retry in a moment." }) }
}, $apis.requireAuth("users"))

routerAdd("GET", "/api/macmint/download", e => {
  e.response.header().set("Cache-Control", "no-store")
  try { return e.json(200, require(`${__hooks}/macmint_download.js`).latest(e.app)) }
  catch (_) { return e.json(200, { source: "none" }) }
})

routerAdd("POST", "/api/macmint/admin/purchase/link", e => {
  const lib = require(`${__hooks}/macmint_lib.js`)
  lib.noStore(e)
  const data = lib.body(e)
  const session = lib.clean(data.session, 220), user = lib.clean(data.user, 40)
  if (!session || !user) return e.json(400, { error: "bad_request", message: "Provide a session and a user." })
  try { return e.json(200, require(`${__hooks}/macmint_funnel.js`).adminLink(e.app, session, user)) }
  catch (error) {
    if (error.code === "not_found") return e.json(404, { error: "not_found", message: "No recorded purchase for that session." })
    return e.json(503, { error: "link_failed", message: "The purchase could not be linked. Nothing was changed." })
  }
}, $apis.requireSuperuserAuth())
