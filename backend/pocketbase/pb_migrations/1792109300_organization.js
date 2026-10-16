migrate((app) => {
  const usage = app.findCollectionByNameOrId("ai_usage")
  usage.fields.add(new NumberField({ name: "organize", min: 0, onlyInt: true }))
  app.save(usage)
  let record
  try { record = app.findFirstRecordByFilter("app_config", "key = 'ai'") } catch (_) { return }
  let cfg
  try { cfg = JSON.parse(toString(record.get("value"))) } catch (_) { cfg = { enabled: false } }
  cfg.features = Object.assign({}, cfg.features || {}, { organize: false })
  record.set("value", cfg); app.save(record)
}, (_) => {
  // Keep accounting and recovery evidence on rollback; disable the feature before reverting code.
})
