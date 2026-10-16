migrate((app) => {
  app.save(new Collection({ name: "checkout_orders", type: "base",
    listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null,
    fields: [
      { name: "user", type: "relation", collectionId: app.findCollectionByNameOrId("users").id, maxSelect: 1, required: true },
      ...["request_key", "session_id", "price_id", "currency", "plan"].map(name => ({ name, type: "text", max: 200 })),
      ...["amount_cents", "duration_days", "max_devices"].map(name => ({ name, type: "number", min: 0, onlyInt: true })),
      { name: "livemode", type: "bool" },
      { name: "state", type: "select", maxSelect: 1, values: ["created", "pending", "fulfilled", "failed"] },
      { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
    ], indexes: ["CREATE UNIQUE INDEX idx_checkout_user_request ON checkout_orders (user, request_key)",
      "CREATE UNIQUE INDEX idx_checkout_session ON checkout_orders (session_id) WHERE session_id != ''"] }))
  const releases = app.findCollectionByNameOrId("app_releases")
  releases.fields.add(new BoolField({ name: "validated" }))
  releases.fields.add(new BoolField({ name: "notarized" }))
  releases.listRule = "published = true && validated = true && notarized = true"
  releases.viewRule = releases.listRule
  app.save(releases)
}, (app) => { /* Keep payment and release evidence when rolling back code. */ })
