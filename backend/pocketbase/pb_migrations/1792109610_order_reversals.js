// Refund/dispute evidence on checkout orders. The payment intent maps Stripe charge and
// dispute events back to their order; it is recorded at fulfillment from now on.
migrate(app => {
  const orders = app.findCollectionByNameOrId("checkout_orders")
  if (!orders.fields.getByName("payment_intent")) orders.fields.add(new TextField({ name: "payment_intent", max: 200 }))
  if (!orders.fields.getByName("refunded_minor")) orders.fields.add(new NumberField({ name: "refunded_minor", min: 0, onlyInt: true }))
  // partial_refund or operator_revoked: needs a person to look at it.
  if (!orders.fields.getByName("attention")) orders.fields.add(new TextField({ name: "attention", max: 40 }))
  if (!orders.fields.getByName("reversed_at")) orders.fields.add(new DateField({ name: "reversed_at" }))
  const state = orders.fields.getByName("state")
  state.values = ["created", "pending", "fulfilled", "failed", "expired", "refunded", "disputed"]
  orders.addIndex("idx_checkout_payment_intent", true, "payment_intent", "payment_intent != ''")
  app.save(orders)
}, () => {
  // Keep refund/dispute evidence and states on rollback; restore code before schema.
})
