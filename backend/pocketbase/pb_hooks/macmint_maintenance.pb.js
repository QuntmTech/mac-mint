/// <reference path="../pb_data/types.d.ts" />
// Daily retention for unbounded, low-value rows. Orders, licenses, entitlements, devices
// and AI accounting evidence are never pruned here.
//   site_events (anonymous funnel events, open create rule): 180 days
//   audit_log "redeem_failed" rows (one per failed code attempt): 90 days

cronAdd("macmint_retention", "41 3 * * *", () => {
  // Bounded batches keep a large first run from holding the SQLite write lock for long;
  // anything left over is removed on the following days. (Handlers are isolated, so the
  // constants live here rather than at file scope.)
  const BATCH = 5000, MAX_BATCHES = 40
  const prune = (table, condition, days) => {
    const cutoff = new Date(Date.now() - days * 86400000).toISOString().replace("T", " ")
    const sql = `DELETE FROM ${table} WHERE id IN (SELECT id FROM ${table} WHERE ${condition} AND created < {:cutoff} LIMIT ${BATCH})`
    let total = 0
    for (let i = 0; i < MAX_BATCHES; i++) {
      const removed = $app.db().newQuery(sql).bind({ cutoff }).execute().rowsAffected()
      total += removed
      if (removed < BATCH) break
    }
    return total
  }
  try {
    const events = prune("site_events", "1 = 1", 180)
    const failures = prune("audit_log", "event = 'redeem_failed'", 90)
    if (events || failures) $app.logger().info("macmint: retention pruned rows", "site_events", events, "redeem_failed", failures)
  } catch (err) {
    $app.logger().error("macmint: retention pruning failed", "error", String(err))
  }
})
