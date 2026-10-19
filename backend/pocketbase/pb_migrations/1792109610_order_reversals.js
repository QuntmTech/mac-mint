// Refund/dispute evidence on checkout orders and subscriptions. The payment intent maps
// Stripe charge and dispute events back to their order; it is recorded at fulfillment.
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
  // Subscription invoices are held per subscription (1792109500 creates the collection):
  // access_hold is refunded/disputed/operator and blocks access until a superuser release.
  const subscriptions = app.findCollectionByNameOrId("billing_subscriptions")
  for (const name of ["access_hold", "attention"]) if (!subscriptions.fields.getByName(name)) subscriptions.fields.add(new TextField({ name, max: 40 }))
  for (const name of ["hold_reference", "attention_reference"]) if (!subscriptions.fields.getByName(name)) subscriptions.fields.add(new TextField({ name, max: 200 }))
  if (!subscriptions.fields.getByName("held_at")) subscriptions.fields.add(new DateField({ name: "held_at" }))
  if (!subscriptions.fields.getByName("refunded_minor")) subscriptions.fields.add(new NumberField({ name: "refunded_minor", min: 0, onlyInt: true }))
  app.save(subscriptions)
}, () => {
  // Keep refund/dispute evidence and states on rollback; restore code before schema.
})
