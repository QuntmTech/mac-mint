// The public "ai" app_config record is readable by anyone, so keep only the client switches
// there (enabled, features). Budgets, caps and model overrides move to the private
// "ai_limits" record, which the hooks read with a fallback to the old public fields.
migrate(app => {
  const requests = app.findCollectionByNameOrId("ai_requests")
  if (!requests.fields.getByName("flagged_at")) requests.fields.add(new DateField({ name: "flagged_at" }))
  app.save(requests)

  let pub
  try { pub = app.findFirstRecordByFilter("app_config", "key = 'ai'") } catch (_) { return }
  let cfg
  try { cfg = JSON.parse(toString(pub.get("value"))) } catch (_) { return }
  if (!cfg || typeof cfg !== "object" || Array.isArray(cfg)) return
  const moved = {}, kept = {}
  for (const key of Object.keys(cfg)) (key === "enabled" || key === "features" ? kept : moved)[key] = cfg[key]
  if (!Object.keys(moved).length) return
  let priv, existing = {}
  try {
    priv = app.findFirstRecordByFilter("app_config", "key = 'ai_limits'")
    existing = JSON.parse(toString(priv.get("value"))) || {}
  } catch (_) {
    priv = priv || new Record(app.findCollectionByNameOrId("app_config"))
    priv.set("key", "ai_limits")
  }
  // A private value that already exists is the operator's newer choice.
  priv.set("value", Object.assign({}, moved, existing))
  priv.set("public", false)
  app.save(priv)
  pub.set("value", kept)
  app.save(pub)
}, app => {
  // Older hooks read limits from the public record: copy them back, keep the private record.
  let pub, priv
  try { pub = app.findFirstRecordByFilter("app_config", "key = 'ai'"); priv = app.findFirstRecordByFilter("app_config", "key = 'ai_limits'") } catch (_) { return }
  let cfg = {}, limits = {}
  try { cfg = JSON.parse(toString(pub.get("value"))) || {} } catch (_) {}
  try { limits = JSON.parse(toString(priv.get("value"))) || {} } catch (_) { return }
  pub.set("value", Object.assign({}, limits, cfg))
  app.save(pub)
})
