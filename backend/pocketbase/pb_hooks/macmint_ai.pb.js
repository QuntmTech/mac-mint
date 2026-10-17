/// <reference path="../pb_data/types.d.ts" />
// MacMint AI routes (advisory only — nothing here can select, change, or remove anything).
//
// POST /api/macmint/ai/explain  (user, active plan)  { kind, identifier, location }
//   What an item is and whether moving it to the Trash is safe. Haiku 4.5. Cached for strict
//   identifiers (reverse-DNS bundle ids, launchd labels) — built from no user-specific context.
// POST /api/macmint/ai/review   (user, active plan)  { recommendations[], disk, growth[] }
//   Smart Care review: suggested order, a note per recommendation, cautions. Opus 5.5.
// POST /api/macmint/ai/ask      (user, active plan)  { question, history[], context }
//   "Ask MacMint" assistant over restricted category summaries. Opus 5.5.
// POST /api/macmint/admin/ai-cache/purge (superuser) { kind? }
//
// Kill switch: public app_config key "ai" → { "enabled": false } (optionally per feature).
// Budgets, the per-user daily USD cap and model overrides live in the private "ai_limits" record.
// Handlers run in isolated contexts, so prompts, schemas, and helpers live in macmint_ai_lib.js.

routerAdd("POST", "/api/macmint/ai/explain", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  const privacy = require(`${__hooks}/macmint_ai_context.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI features need an active MacMint plan.")

  const data = ai.body(e)
  const kind = ai.oneOf(data.kind, ai.KINDS, "")
  const identifier = privacy.identifier(kind, ai.clip(data.identifier, 200))
  const location = ai.oneOf(data.location, ai.LOCATIONS, "Other")
  if (!kind || identifier.length < 2) return ai.fail(e, 400, "bad_request", "Nothing to explain.")

  const off = ai.disabled(e.app, "explain")
  if (off) return ai.fail(e, off[0], off[1], off[2])

  const cacheable = ai.isCacheable(kind, identifier)
  const key = ai.cacheKey(kind, location, identifier)
  if (cacheable) {
    const hit = ai.cachedExplanation(e.app, key)
    if (hit) return e.json(200, { explanation: hit, cached: true, model: "cached" })
  }


  try {
    const result = ai.request(
      e.app, e.auth.id, "explain", ai.EXPLAIN_SYSTEM,
      { kind: kind, location: location, name: identifier }, ai.EXPLAIN_SCHEMA, 600)
    const o = result.output
    const explanation = {
      summary: ai.clip(o.summary, 600),
      owner: ai.clip(o.owner, 80) || "Unknown",
      category: ai.oneOf(o.category, ai.EXPLAIN_SCHEMA.properties.category.enum, "unknown"),
      verdict: ai.oneOf(o.verdict, ai.EXPLAIN_SCHEMA.properties.verdict.enum, "unknown"),
      whatHappens: ai.clip(o.whatHappens, 400),
      confidence: ai.oneOf(o.confidence, ["low", "medium", "high"], "low"),
    }
    if (cacheable) ai.storeExplanation(e.app, key, kind, explanation)
    return e.json(200, { explanation: explanation, cached: false, model: result.model })
  } catch (err) {
    return ai.handleError(e, err)
  }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/ai/review", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  const privacy = require(`${__hooks}/macmint_ai_context.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI features need an active MacMint plan.")

  const data = ai.body(e)
  const recs = privacy.recommendations(data.recommendations)
  if (recs.length === 0) return ai.fail(e, 400, "bad_request", "Run Quick Scan first.")
  const disk = data.disk || {}
  const growth = privacy.growth(data.growth)


  const schema = JSON.parse(JSON.stringify(ai.REVIEW_SCHEMA))
  schema.properties.insights.items.properties.destination.enum = ai.DESTINATIONS
  try {
    const result = ai.request(
      e.app, e.auth.id, "review", ai.REVIEW_SYSTEM,
      {
        disk: {
          totalBytes: Math.max(0, Math.floor(Number(disk.totalBytes) || 0)),
          freeBytes: Math.max(0, Math.floor(Number(disk.freeBytes) || 0)),
        },
        recentGrowth: growth,
        recommendations: recs,
      },
      schema, 1400)
    const o = result.output
    const known = recs.map(function (r) { return r.id })
    const notes = (Array.isArray(o.notes) ? o.notes : [])
      .filter(function (n) { return n && known.indexOf(n.id) >= 0 })
      .map(function (n) { return { id: n.id, order: Math.max(1, Math.floor(Number(n.order) || 99)), note: ai.clip(n.note, 300) } })
    return e.json(200, {
      headline: ai.clip(o.headline, 240),
      notes: notes,
      insights: (Array.isArray(o.insights) ? o.insights : []).slice(0, 3).map(function (i) {
        return {
          title: ai.clip(i && i.title, 100),
          detail: ai.clip(i && i.detail, 300),
          destination: ai.oneOf(i && i.destination, ai.DESTINATIONS, "dashboard"),
        }
      }),
      cautions: (Array.isArray(o.cautions) ? o.cautions : []).slice(0, 3).map(function (c) { return ai.clip(c, 240) }),
      model: result.model,
    })
  } catch (err) {
    return ai.handleError(e, err)
  }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/ai/ask", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  const privacy = require(`${__hooks}/macmint_ai_context.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI features need an active MacMint plan.")

  const data = ai.body(e)
  const question = ai.clip(data.question, 600)
  if (question.length < 2) return ai.fail(e, 400, "bad_request", "Ask a question first.")
  const history = (Array.isArray(data.history) ? data.history : []).slice(-6).map(function (t) {
    return { role: t && t.role === "assistant" ? "assistant" : "user", text: ai.clip(t && t.text, 1500) }
  })
  if (JSON.stringify(data.context || {}).length > 16000) return ai.fail(e, 413, "context_too_large", "That summary is too large to send.")
  const context = privacy.context(data.context)


  const schema = JSON.parse(JSON.stringify(ai.ASK_SCHEMA))
  schema.properties.actions.items.properties.destination.enum = ai.DESTINATIONS
  try {
    const result = ai.request(
      e.app, e.auth.id, "ask", ai.ASK_SYSTEM, { question: question, earlierTurns: history, mac: context }, schema, 1200)
    return e.json(200, {
      answer: ai.clip(result.output.answer, 4000),
      actions: ai.cleanActions(result.output.actions).slice(0, 3),
      model: result.model,
    })
  } catch (err) {
    return ai.handleError(e, err)
  }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/admin/ai-cache/purge", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  const kind = ai.oneOf(ai.body(e).kind, ai.KINDS, "")
  let removed = 0
  try {
    const rows = e.app.findRecordsByFilter("ai_explanations", kind ? "kind = {:k}" : "id != ''", "", 10000, 0, { k: kind }) || []
    for (const row of rows) {
      e.app.delete(row)
      removed += 1
    }
  } catch (err) { /* nothing cached */ }
  return e.json(200, { removed: removed })
}, $apis.requireSuperuserAuth())

// Operator reconciliation for timed-out requests. Supply verified provider usage; a release
// without charge requires explicit confirmation; uncharged attempts release allowance.
routerAdd("POST", "/api/macmint/admin/ai-reconcile", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  const data = ai.body(e)
  try {
    if (!data.request_id || (!data.usage && data.confirm_no_charge !== true)) return ai.fail(e, 400, "bad_request", "Verified usage or a no-charge confirmation is required.")
    ai.settle(e.app, String(data.request_id), data.usage, data.confirm_no_charge === true)
    return e.json(200, { ok: true })
  } catch (err) { return ai.handleError(e, err) }
}, $apis.requireSuperuserAuth())

// Separate, explicit name-sharing consent in the client; disabled until staging validation.
routerAdd("POST", "/api/macmint/ai/organize", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  const organizer = require(`${__hooks}/macmint_organization.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (_) {}
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI organization needs an active MacMint plan.")
  const off = ai.disabled(e.app, "organize")
  if (off) return ai.fail(e, off[0], off[1], off[2])
  let inventory
  try { inventory = organizer.input(ai.body(e)) }
  catch (_) { return ai.fail(e, 400, "bad_request", "That file inventory could not be used.") }
  try {
    const result = ai.request(e.app, e.auth.id, "organize", organizer.system, inventory, organizer.schema, 6000)
    let proposals
    try { proposals = organizer.output(result.output, inventory) }
    catch (_) { return ai.fail(e, 502, "invalid_ai_response", "The suggestions could not be validated. No files were changed.") }
    return e.json(200, { proposals, model: result.model })
  } catch (err) { return ai.handleError(e, err) }
}, $apis.requireAuth("users"))

// Flags (never frees) reservations left pending or uncertain for over an hour.
cronAdd("macmint_ai_stale_reservations", "17 * * * *", () => {
  try { require(`${__hooks}/macmint_ai_lib.js`).flagStaleReservations($app) }
  catch (err) { $app.logger().error("macmint: stale AI reservation check failed", "error", String(err)) }
})
