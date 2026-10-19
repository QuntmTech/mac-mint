migrate(app => {
  const orders = app.findCollectionByNameOrId("checkout_orders")
  for (const name of ["billing_mode", "billing_interval", "portal_configuration_id", "subscription_id", "customer_id"]) {
    orders.fields.add(new TextField({ name, max: 200 }))
  }
  orders.fields.add(new NumberField({ name: "billing_interval_count", min: 0, onlyInt: true }))
  orders.fields.add(new NumberField({ name: "trial_days", min: 0, max: 30, onlyInt: true }))
  app.save(orders)
  const entitlements = app.findCollectionByNameOrId("plan_entitlements")
  entitlements.fields.add(new BoolField({ name: "subscription_trial_used" }))
  app.save(entitlements)
  app.save(new Collection({ name: "billing_subscriptions", type: "base",
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
    fields: [
      { name: "user", type: "relation", collectionId: app.findCollectionByNameOrId("users").id, maxSelect: 1, required: true },
      { name: "order", type: "relation", collectionId: orders.id, maxSelect: 1, required: true },
      ...["subscription_id", "customer_id", "status", "last_invoice"].map(name => ({ name, type: "text", max: 200 })),
      ...["paid_through", "trial_through", "current_period_end", "cancel_at"].map(name => ({ name, type: "date" })),
      { name: "cancel_at_period_end", type: "bool" }, { name: "terminal", type: "bool" },
      { name: "livemode", type: "bool" },
      { name: "sync_generation", type: "number", min: 0, onlyInt: true },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      { name: "updated", type: "autodate", onCreate: false, onUpdate: true },
    ], indexes: ["CREATE UNIQUE INDEX idx_billing_subscription ON billing_subscriptions (subscription_id)",
      "CREATE UNIQUE INDEX idx_billing_ongoing_user ON billing_subscriptions (user, livemode) WHERE terminal = false"] }))
}, app => { /* Keep immutable orders and subscription evidence on rollback. */ })
