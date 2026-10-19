// Fixed categories shared conceptually with the desktop allowlist. Rebuild automatic context
// on the server as well so older clients cannot forward arbitrary names to the provider.
const APPS = { "com.apple.dt.Xcode": "Xcode", "com.apple.iphonesimulator": "Simulator",
  "com.apple.Safari": "Safari", "com.google.Chrome": "Chrome", "org.mozilla.firefox": "Firefox",
  "com.microsoft.edgemac": "Edge", "com.spotify.client": "Spotify", "com.docker.docker": "Docker",
  "com.brave.Browser": "Brave", "company.thebrowser.Browser": "Arc", "com.vivaldi.Vivaldi": "Vivaldi",
  "com.operasoftware.Opera": "Opera", "com.microsoft.VSCode": "Visual Studio Code" }
const TOOLS = ["Xcode", "Simulator", "npm", "pnpm", "Yarn", "Bun", "Homebrew", "pip", "CocoaPods", "SwiftPM", "Gradle", "Maven", "Cargo", "Go", "Ollama", "LM Studio", "Hugging Face", "Docker"]
const CATEGORIES = ["~", "/Applications", "/Library", ...["Desktop", "Documents", "Pictures", "Movies", "Music", "Downloads", "Library", "Library/Caches", "Library/Logs", "Library/Developer", "Library/Application Support", "Library/Containers", "Library/Group Containers", "Library/Developer/Xcode/DerivedData", "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", ".gradle/caches", ".cache/huggingface/hub", ".lmstudio/models", ".ollama/models"].map(p => "~/" + p)]
const RECOMMENDATIONS = { caches: "Rebuildable caches and logs", developer: "Developer build data", firmware: "Device firmware",
  "downloads-never-opened": "Downloads with no recorded opens", "downloads-stale": "Old downloads", "removed-apps": "Possible removed-app data",
  screenshots: "Old screenshots", mail: "Mail attachment copies", "review-cleanup": "Backups, reports and installers", "unused-apps": "Apps with old recorded usage",
  duplicates: "Exact duplicates", trash: "Home Trash", growth: "Storage category growth" }
const LABELS = Object.values(RECOMMENDATIONS).concat(["Storage recommendation"])
const GROUPS = ["Xcode", "Simulators", "Package caches", "Project build folders", "AI models", "Containers"]
const DOWNLOADS = ["Installers", "Archives", "Videos", "Audio", "Images", "Documents", "Folders", "Other"]
const num = v => Number.isFinite(Number(v)) ? Math.max(0, Math.min(Number(v), 1e16)) : 0
const array = v => Array.isArray(v) ? v : []
const object = v => v && typeof v === "object" && !Array.isArray(v) ? v : {}
const numericMap = (v, keys) => Object.fromEntries(Object.entries(object(v)).filter(([key]) => keys.indexOf(key) >= 0).map(([key, value]) => [key, num(value)]))
const folders = v => array(v).slice(0, 14).filter(f => f && CATEGORIES.indexOf(f.path) >= 0).map(f => ({ path: f.path, gb: num(f.gb) }))
const PLACEHOLDERS = { "developer-tool": "Unrecognized developer cache", other: "Unrecognized Library item" }
function identifier(kind, value) {
  if (kind === "developer-tool") return TOOLS.indexOf(value) >= 0 ? value : PLACEHOLDERS["developer-tool"]
  return Object.prototype.hasOwnProperty.call(APPS, value) ? value : PLACEHOLDERS.other
}
// Unrecognized names are never sent, so a provider answer could only guess. Answer locally,
// without a provider call or allowance, in the same shape as a model explanation.
const isPlaceholder = value => value === PLACEHOLDERS["developer-tool"] || value === PLACEHOLDERS.other
function localExplanation(kind) {
  const developer = kind === "developer-tool"
  return {
    summary: developer
      ? "MacMint only shares recognized developer tool names, so this cache was not sent for an AI explanation. Check which tool created it before removing it."
      : "MacMint only shares recognized app identifiers, so this item was not sent for an AI explanation. Check which app created it before removing it.",
    owner: "Unknown", category: developer ? "developer" : "unknown", verdict: "unknown",
    whatHappens: "Moving it to the Trash may remove settings or data that an app or tool uses. You can restore it from History.",
    confidence: "low",
  }
}
function recommendations(values) {
  return array(values).slice(0, 15).filter(r => r && Object.prototype.hasOwnProperty.call(RECOMMENDATIONS, r.id)).map(r => ({
    id: r.id, title: RECOMMENDATIONS[r.id], bytes: num(r.bytes), count: Math.floor(num(r.count)),
    confidence: ["safe", "likely", "review"].indexOf(r.confidence) >= 0 ? r.confidence : "review",
    evidence: "Local storage category; review the findings in MacMint before removal.",
  }))
}
function growth(values) { return array(values).slice(0, 5).filter(g => g && CATEGORIES.indexOf(g.path) >= 0).map(g => ({ folder: g.path, grewBytes: num(g.delta) })) }
function context(value) {
  const c = object(value)
  return {
    disk: numericMap(c.disk, ["totalGB", "freeGB"]), biggestFolders: folders(c.biggestFolders), recentGrowth: folders(c.recentGrowth),
    developerGB: numericMap(c.developerGB, GROUPS), downloadsGB: numericMap(c.downloadsGB, DOWNLOADS),
    startupItems: array(c.startupItems).filter(id => Object.prototype.hasOwnProperty.call(APPS, id)).slice(0, 15),
    unusedApps: array(c.unusedApps).filter(a => a && Object.values(APPS).indexOf(a.name) >= 0).slice(0, 8).map(a => ({ name: a.name, monthsSinceOpened: Math.floor(num(a.monthsSinceOpened)), gb: num(a.gb) })),
    recommendations: array(c.recommendations).filter(r => r && LABELS.indexOf(r.title) >= 0).slice(0, 12).map(r => ({ title: r.title, gb: num(r.gb), items: Math.floor(num(r.items)), confidence: ["Rebuildable", "Likely", "Review", "Likely unneeded", "Needs review"].indexOf(r.confidence) >= 0 ? r.confidence : "Review" })),
  }
}
module.exports = { identifier, isPlaceholder, localExplanation, recommendations, growth, context, CATEGORIES }
