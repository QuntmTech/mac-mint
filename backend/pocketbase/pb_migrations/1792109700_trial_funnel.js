// Plan-page Payment Link purchases. A private purchase_claims row is recorded from each
// verified checkout.session.completed and becomes an account (or is linked to an existing
// one) once, within 72 hours. checkout_orders created from a claim carry its payment link.
const RULES = [
  // Each call can redirect to Stripe and reveals trial eligibility for an email address.
  { label: "/api/macmint/trial/start", maxRequests: 10, duration: 600 },
  // GET polls while the webhook lands (may ask Stripe); POST creates the account.
  { label: "/api/macmint/purchase/claim", maxRequests: 60, duration: 600 },
  { label: "/api/macmint/billing/refresh", maxRequests: 10, duration: 600 },
]

migrate(app => {
  const orders = app.findCollectionByNameOrId("checkout_orders")
  if (!orders.fields.getByName("payment_link_id")) orders.fields.add(new TextField({ name: "payment_link_id", max: 200 }))
  app.save(orders)

  let claims = null
  try { claims = app.findCollectionByNameOrId("purchase_claims") } catch (_) {}
  if (!claims) {
    app.save(new Collection({ name: "purchase_claims", type: "base",
      listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
      fields: [
        ...["session_id", "payment_link_id", "price_id", "request_key", "customer_id", "subscription_id"].map(name => ({ name, type: "text", max: 200 })),
        ...["tier", "currency", "billing_interval", "attention"].map(name => ({ name, type: "text", max: 40 })),
        { name: "billing_email", type: "email", hidden: true },
        ...["devices", "amount_minor", "trial_days"].map(name => ({ name, type: "number", min: 0, onlyInt: true })),
        { name: "livemode", type: "bool" },
        { name: "state", type: "select", maxSelect: 1, values: ["pending", "linked", "claimed", "attention"] },
        ...["expires_at", "linked_at", "claimed_at"].map(name => ({ name, type: "date" })),
        { name: "user", type: "relation", collectionId: app.findCollectionByNameOrId("users").id, maxSelect: 1 },
        { name: "order", type: "relation", collectionId: orders.id, maxSelect: 1 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: ["CREATE UNIQUE INDEX idx_purchase_claim_session ON purchase_claims (session_id)",
        "CREATE INDEX idx_purchase_claim_email ON purchase_claims (billing_email)"] }))
  }

  // Same policy as 1792109600: install next to the existing rules, replace same-label rules,
  // and leave enabling to the operator's trusted-proxy step.
  const settings = app.settings()
  const ours = RULES.map(rule => rule.label)
  const kept = []
  for (const rule of settings.rateLimits.rules || []) {
    if (ours.indexOf(rule.label) < 0) kept.push({ label: rule.label, audience: rule.audience, maxRequests: rule.maxRequests, duration: rule.duration })
  }
  settings.rateLimits.rules = RULES.map(rule => Object.assign({ audience: "" }, rule)).concat(kept)
  app.save(settings)
}, () => {
  // Keep purchase claims and orders on rollback: they are payment evidence.
})
