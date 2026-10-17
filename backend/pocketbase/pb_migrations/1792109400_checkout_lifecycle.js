migrate(app => {
  const orders = app.findCollectionByNameOrId("checkout_orders")
  // Do not backfill from current account email: historical in-flight requests may have
  // used a different value. Bound sessions remain reusable; unknown ones fail closed.
  orders.fields.add(new EmailField({ name: "customer_email", hidden: true }))
  orders.fields.add(new TextField({ name: "web_origin", max: 300 }))
  const state = orders.fields.getByName("state")
  state.values = ["created", "pending", "fulfilled", "failed", "expired"]
  app.save(orders)
}, app => { /* Preserve immutable request snapshots and payment evidence on rollback. */ })
