// The /download page's installer. The validated app_releases feed wins; otherwise the
// latest published (non-prerelease) GitHub release of QuntmTech/mac-mint with a MacMint.dmg
// asset. Every URL must pass the feed's trusted-download rule; nothing else is linked.
const GITHUB_LATEST = "https://api.github.com/repos/QuntmTech/mac-mint/releases/latest"
const CACHE_KEY = "macmint_download_github"
const HIT_MILLIS = 10 * 60000, MISS_MILLIS = 2 * 60000

function payments() { return require(`${__hooks}/macmint_payments_lib.js`) }
function version(value) {
  const text = String(value || "").replace(/^v/, "")
  return /^[0-9A-Za-z.+-]{1,40}$/.test(text) ? text : ""
}
function fromFeed(record) {
  const url = String(record.get("download_url") || "")
  if (!payments().trustedDownloadURL(url) || !/\.dmg$/i.test(url) || !version(record.get("version"))) return null
  const size = Number(record.get("size_bytes") || 0), sha = String(record.get("sha256") || "")
  return { source: "feed", version: version(record.get("version")), build: Number(record.get("build") || 0) || null,
    url, size_bytes: Number.isSafeInteger(size) && size > 0 ? size : null, sha256: /^[a-f0-9]{64}$/.test(sha) ? sha : null,
    min_os: /^\d{2}(\.\d+)?$/.test(String(record.get("min_os") || "")) ? String(record.get("min_os")) : "14.0",
    notarized: record.get("notarized") === true, published_at: String(record.get("published_at") || "") || null }
}
// Pure: GitHub's latest-release JSON → a download, or null when it has no trusted DMG.
function fromGitHub(release) {
  if (!release || release.draft || release.prerelease || typeof release.tag_name !== "string" || !/^[A-Za-z0-9._-]{1,60}$/.test(release.tag_name)) return null
  const asset = (Array.isArray(release.assets) ? release.assets : []).find(item => item && item.name === "MacMint.dmg")
  const expected = "https://github.com/QuntmTech/mac-mint/releases/download/" + release.tag_name + "/MacMint.dmg"
  if (!asset || asset.browser_download_url !== expected || !payments().trustedDownloadURL(expected) || !version(release.tag_name)) return null
  const digest = /^sha256:([a-f0-9]{64})$/.exec(String(asset.digest || ""))
  return { source: "github", version: version(release.tag_name), build: null, url: expected,
    size_bytes: Number.isSafeInteger(asset.size) && asset.size > 0 ? asset.size : null, sha256: digest ? digest[1] : null,
    // GitHub carries no notarization attestation; only the validated feed does.
    min_os: "14.0", notarized: false, published_at: typeof release.published_at === "string" ? release.published_at : null }
}
function github(app) {
  const now = Date.now()
  const cached = app.store().get(CACHE_KEY)
  if (cached && cached.until > now) return cached.value
  let value = null
  try {
    const response = $http.send({ method: "GET", url: GITHUB_LATEST, timeout: 10,
      headers: { Accept: "application/vnd.github+json", "User-Agent": "macmint-download", "X-GitHub-Api-Version": "2022-11-28" } })
    if (response.statusCode === 200) value = fromGitHub(response.json)
  } catch (_) { value = null }
  app.store().set(CACHE_KEY, { until: now + (value ? HIT_MILLIS : MISS_MILLIS), value })
  return value
}
function latest(app) {
  const rows = app.findRecordsByFilter("app_releases", "published = true && validated = true && notarized = true && channel = 'stable'", "-published_at,-build", 5, 0) || []
  for (const row of rows) {
    const feed = fromFeed(row)
    if (feed) return feed
  }
  return github(app) || { source: "none" }
}
module.exports = { latest, fromGitHub, fromFeed, GITHUB_LATEST }
