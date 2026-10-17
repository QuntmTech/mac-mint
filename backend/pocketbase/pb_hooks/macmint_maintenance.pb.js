/// <reference path="../pb_data/types.d.ts" />
// Daily retention for unbounded, low-value rows. Orders, licenses, entitlements, devices
// and AI accounting evidence are never pruned here.
//   site_events (anonymous funnel events, open create rule): 180 days
//   audit_log "redeem_failed" rows (one per failed code attempt): 90 days

cronAdd("macmint_retention", "41 3 * * *", () => {
  const prune = (sql, days) => {
    const cutoff = new Date(Date.now() - days * 86400000).toISOString().replace("T", " ")
    return $app.db().newQuery(sql).bind({ cutoff }).execute().rowsAffected()
  }
  try {
    const events = prune("DELETE FROM site_events WHERE created < {:cutoff}", 180)
    const failures = prune("DELETE FROM audit_log WHERE event = 'redeem_failed' AND created < {:cutoff}", 90)
    if (events || failures) $app.logger().info("macmint: retention pruned rows", "site_events", events, "redeem_failed", failures)
  } catch (err) {
    $app.logger().error("macmint: retention pruning failed", "error", String(err))
  }
})
