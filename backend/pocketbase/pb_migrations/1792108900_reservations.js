migrate((app) => {
  const locked = { listRule: null, viewRule: null, createRule: null, updateRule: null, deleteRule: null }
  const text = (name, max = 100) => ({ name, type: "text", max })
  const number = (name) => ({ name, type: "number", min: 0, onlyInt: true })
  const dates = [
    { name: "created", type: "autodate", onCreate: true, onUpdate: false },
    { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
  ]
  app.save(new Collection({ name: "ai_daily_budgets", type: "base", ...locked,
    fields: [text("day", 10), ...["reserved_tokens", "used_tokens", "reserved_micro_usd", "spent_micro_usd"].map(number), ...dates],
    indexes: ["CREATE UNIQUE INDEX idx_ai_budget_day ON ai_daily_budgets (day)"] }))
  app.save(new Collection({ name: "ai_requests", type: "base", ...locked,
    fields: [text("user", 15), text("day", 10), text("feature", 12), text("model"),
      { name: "state", type: "select", maxSelect: 1, values: ["pending", "settled", "uncertain", "released"] },
      ...["reserved_tokens", "reserved_micro_usd", "actual_tokens", "actual_micro_usd"].map(number), ...dates],
    indexes: ["CREATE INDEX idx_ai_request_day_state ON ai_requests (day, state)"] }))
  const usage = app.findCollectionByNameOrId("ai_usage")
  for (const field of ["cache_creation_input_tokens", "cache_read_input_tokens", "spent_micro_usd"]) {
    usage.fields.add(new NumberField(number(field)))
  }
  app.save(usage)
  const devices = app.findCollectionByNameOrId("devices")
  devices.fields.add(new BoolField({ name: "deactivated" }))
  devices.deleteRule = null
  app.save(devices)
}, (app) => {
  // Reservations and monetary evidence must survive a rollback. Restore code before schema.
})
