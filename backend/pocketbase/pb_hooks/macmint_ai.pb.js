/// <reference path="../pb_data/types.d.ts" />
// MacMint AI routes (advisory only — nothing here can select, change, or remove anything).
//
// POST /api/macmint/ai/explain  (user, active plan)  { kind, identifier, location }
//   What an item is and whether moving it to the Trash is safe. Haiku 4.5. Cached for strict
//   identifiers (reverse-DNS bundle ids, launchd labels) — built from no user-specific context.
// POST /api/macmint/ai/review   (user, active plan)  { recommendations[], disk, growth[] }
//   Smart Care review: suggested order, a note per recommendation, cautions. Opus 5.5.
// POST /api/macmint/ai/ask      (user, active plan)  { question, history[], context }
//   "Ask MacMint" assistant over an anonymized summary of the Mac. Opus 5.5.
// POST /api/macmint/admin/ai-cache/purge (superuser) { kind? }
//
// Kill switch: app_config key "ai" → { "enabled": false } (optionally per feature).
// Handlers run in isolated contexts, so prompts, schemas, and helpers live in macmint_ai_lib.js.

routerAdd("POST", "/api/macmint/ai/explain", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI features need an active MacMint plan.")

  const data = ai.body(e)
  const kind = ai.oneOf(data.kind, ai.KINDS, "")
  const identifier = ai.clip(data.identifier, 200)
  const location = ai.oneOf(data.location, ai.LOCATIONS, "Other")
  if (!kind || identifier.length < 2) return ai.fail(e, 400, "bad_request", "Nothing to explain.")

  const off = ai.disabled(e.app, "explain")
  if (off) return ai.fail(e, off[0], off[1], off[2])

  const cacheable = ai.isCacheable(kind, identifier)
  const key = ai.cacheKey(kind, location, identifier)
  if (cacheable) {
    const hit = ai.cachedExplanation(e.app, key)
    if (hit) return e.json(200, { explanation: hit, cached: true, model: ai.MODELS.explain })
  }

  const blocked = ai.gate(e.app, e.auth.id, "explain")
  if (blocked) return ai.fail(e, blocked[0], blocked[1], blocked[2])

  try {
    const result = ai.claude(
      e.app, ai.MODELS.explain, ai.EXPLAIN_SYSTEM,
      { kind: kind, location: location, name: identifier }, ai.EXPLAIN_SCHEMA, 600)
    ai.recordUsage(e.app, e.auth.id, "explain", result.usage)
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
    return e.json(200, { explanation: explanation, cached: false, model: ai.MODELS.explain })
  } catch (err) {
    return ai.handleError(e, err)
  }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/ai/review", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI features need an active MacMint plan.")

  const data = ai.body(e)
  const recs = (Array.isArray(data.recommendations) ? data.recommendations : []).slice(0, 15).map(function (r) {
    return {
      id: ai.clip(r && r.id, 40),
      title: ai.clip(r && r.title, 120),
      bytes: Math.max(0, Math.floor(Number(r && r.bytes) || 0)),
      confidence: ai.oneOf(r && r.confidence, ["safe", "likely", "review"], "review"),
      count: Math.max(0, Math.floor(Number(r && r.count) || 0)),
      evidence: ai.clip(r && r.detail, 300),
    }
  }).filter(function (r) { return r.id && r.title })
  if (recs.length === 0) return ai.fail(e, 400, "bad_request", "Run Smart Care first.")
  const disk = data.disk || {}
  const growth = (Array.isArray(data.growth) ? data.growth : []).slice(0, 5).map(function (g) {
    return { folder: ai.clip(g && g.path, 200), grewBytes: Math.max(0, Math.floor(Number(g && g.delta) || 0)) }
  })

  const blocked = ai.gate(e.app, e.auth.id, "review")
  if (blocked) return ai.fail(e, blocked[0], blocked[1], blocked[2])

  const schema = JSON.parse(JSON.stringify(ai.REVIEW_SCHEMA))
  schema.properties.insights.items.properties.destination.enum = ai.DESTINATIONS
  try {
    const result = ai.claude(
      e.app, ai.MODELS.review, ai.REVIEW_SYSTEM,
      {
        disk: {
          totalBytes: Math.max(0, Math.floor(Number(disk.totalBytes) || 0)),
          freeBytes: Math.max(0, Math.floor(Number(disk.freeBytes) || 0)),
        },
        recentGrowth: growth,
        recommendations: recs,
      },
      schema, 1400)
    ai.recordUsage(e.app, e.auth.id, "review", result.usage)
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
      model: ai.MODELS.review,
    })
  } catch (err) {
    return ai.handleError(e, err)
  }
}, $apis.requireAuth("users"))

routerAdd("POST", "/api/macmint/ai/ask", (e) => {
  const ai = require(`${__hooks}/macmint_ai_lib.js`)
  try { e.response.header().set("Cache-Control", "no-store") } catch (err) { /* ignore */ }
  if (!ai.requirePlan(e)) return ai.fail(e, 402, "no_active_plan", "AI features need an active MacMint plan.")

  const data = ai.body(e)
  const question = ai.clip(data.question, 600)
  if (question.length < 2) return ai.fail(e, 400, "bad_request", "Ask a question first.")
  const history = (Array.isArray(data.history) ? data.history : []).slice(-6).map(function (t) {
    return { role: t && t.role === "assistant" ? "assistant" : "user", text: ai.clip(t && t.text, 1500) }
  })
  let context = data.context && typeof data.context === "object" ? data.context : {}
  if (JSON.stringify(context).length > 16000) {
    return ai.fail(e, 413, "context_too_large", "That summary is too large to send.")
  }

  const blocked = ai.gate(e.app, e.auth.id, "ask")
  if (blocked) return ai.fail(e, blocked[0], blocked[1], blocked[2])

  const schema = JSON.parse(JSON.stringify(ai.ASK_SCHEMA))
  schema.properties.actions.items.properties.destination.enum = ai.DESTINATIONS
  try {
    const result = ai.claude(
      e.app, ai.MODELS.ask, ai.ASK_SYSTEM, { question: question, earlierTurns: history, mac: context }, schema, 1200)
    ai.recordUsage(e.app, e.auth.id, "ask", result.usage)
    return e.json(200, {
      answer: ai.clip(result.output.answer, 4000),
      actions: ai.cleanActions(result.output.actions).slice(0, 3),
      model: ai.MODELS.ask,
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
