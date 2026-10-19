#!/usr/bin/env node
// Writes and verifies MacMint's Sparkle appcasts (docs/UPDATES.md). Built-in modules only.
//
//   generate  --channel developer|stable --version N --short-version X.Y.Z --url URL
//             --archive MacMint.zip --signature BASE64 [--changes-file FILE] [--since 'build N']
//             [--existing appcast.xml] [--keep 10] [--pub-date RFC822] --output appcast.xml
//   verify    --appcast appcast.xml --archive MacMint.zip --public-key BASE64
//             --version N [--url URL]
//
// Items carried over from --existing are re-validated and re-rendered, never copied verbatim.
import { createPublicKey, verify as verifySignature } from 'node:crypto';
import { readFileSync, statSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const MINIMUM_SYSTEM_VERSION = '14.0';
const SPARKLE_NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
const ARCHIVE_URL = /^https:\/\/github\.com\/QuntmTech\/mac-mint\/releases\/download\/[A-Za-z0-9._-]{1,100}\/MacMint\.zip$/;
const PUB_DATE = /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}$/;
const MAX_CHANGES = 40;
const CHANNELS = {
  developer: { title: 'MacMint developer builds', description: 'Every successful build of main. Not notarized; may be unstable.' },
  stable: { title: 'MacMint', description: 'Developer ID-signed and notarized MacMint releases.' },
};

export function escapeXml(text) {
  return String(text)
    .replace(/[^\t\n\r\u{20}-\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/gu, '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function unescapeXml(text) {
  return text.replace(/&(lt|gt|quot|apos|amp);/g, (_, name) => ({ lt: '<', gt: '>', quot: '"', apos: "'", amp: '&' })[name]);
}

export function rfc822(date) {
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const pad = (value) => String(value).padStart(2, '0');
  return `${days[date.getUTCDay()]}, ${pad(date.getUTCDate())} ${months[date.getUTCMonth()]} ${date.getUTCFullYear()} `
    + `${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}:${pad(date.getUTCSeconds())} +0000`;
}

/** Plain-text release notes: one bullet per commit subject, control characters removed. */
export function releaseNotes(subjects, since) {
  const lines = subjects.map((line) => line.replace(/[\u0000-\u001f\u007f]/g, ' ').trim()).filter(Boolean)
    .map((line) => (line.length > 200 ? `${line.slice(0, 199)}…` : line));
  const label = String(since ?? '').replace(/[^A-Za-z0-9 ._-]/g, '').trim();
  const heading = label ? `Changes since ${label}:` : 'Changes:';
  if (lines.length === 0) return `${heading}\n• Maintenance build.`;
  const shown = lines.slice(0, MAX_CHANGES).map((line) => `• ${line}`);
  if (lines.length > MAX_CHANGES) shown.push(`• …and ${lines.length - MAX_CHANGES} more.`);
  return [heading, ...shown].join('\n');
}

/** Throws unless every field is what MacMint publishes. Returns a normalised copy. */
export function validateItem(item) {
  const version = String(item.version ?? '');
  if (!/^[1-9]\d{0,8}$/.test(version)) throw new Error(`Invalid sparkle:version ${JSON.stringify(item.version)}`);
  const shortVersion = String(item.shortVersion ?? '');
  if (!/^\d+\.\d+(\.\d+)?$/.test(shortVersion)) throw new Error(`Invalid shortVersionString for build ${version}`);
  if (!ARCHIVE_URL.test(item.url ?? '')) throw new Error(`Untrusted archive URL for build ${version}`);
  const length = String(item.length ?? '');
  if (!/^[1-9]\d{0,11}$/.test(length)) throw new Error(`Invalid length for build ${version}`);
  const signature = String(item.signature ?? '');
  if (!/^[A-Za-z0-9+/]{86}==$/.test(signature) || Buffer.from(signature, 'base64').length !== 64) {
    throw new Error(`Invalid edSignature for build ${version}`);
  }
  if (!PUB_DATE.test(item.pubDate ?? '')) throw new Error(`Invalid pubDate for build ${version}`);
  if ((item.minimumSystemVersion ?? MINIMUM_SYSTEM_VERSION) !== MINIMUM_SYSTEM_VERSION) {
    throw new Error(`Unexpected minimumSystemVersion for build ${version}`);
  }
  return {
    version, shortVersion, url: item.url, length, signature, pubDate: item.pubDate,
    minimumSystemVersion: MINIMUM_SYSTEM_VERSION,
    title: String(item.title || `MacMint ${shortVersion} (build ${version})`),
    notes: String(item.notes ?? ''),
  };
}

function element(block, name) {
  const match = block.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`));
  return match ? unescapeXml(match[1].trim()) : undefined;
}

function attribute(tag, name) {
  const match = tag.match(new RegExp(`\\s${name}="([^"]*)"`));
  return match ? unescapeXml(match[1]) : undefined;
}

/** Items of an appcast this script wrote. Invalid items are reported through `onInvalid` and dropped. */
export function parseItems(xml, onInvalid = () => {}) {
  const items = [];
  for (const [, block] of String(xml).matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const enclosure = block.match(/<enclosure\s[^>]*\/>/)?.[0] ?? '';
    const candidate = {
      title: element(block, 'title'),
      pubDate: element(block, 'pubDate'),
      version: element(block, 'sparkle:version'),
      shortVersion: element(block, 'sparkle:shortVersionString'),
      minimumSystemVersion: element(block, 'sparkle:minimumSystemVersion'),
      notes: element(block, 'description'),
      url: attribute(enclosure, 'url'),
      length: attribute(enclosure, 'length'),
      signature: attribute(enclosure, 'sparkle:edSignature'),
    };
    try {
      items.push(validateItem(candidate));
    } catch (error) {
      onInvalid(error);
    }
  }
  return items;
}

/** Newest first by build number; `item` replaces an existing entry with the same build. */
export function mergeItems(existing, item, keep = 10) {
  const byVersion = new Map(existing.map((entry) => [entry.version, entry]));
  byVersion.set(item.version, item);
  return [...byVersion.values()].sort((a, b) => Number(b.version) - Number(a.version)).slice(0, keep);
}

export function renderAppcast(channel, items) {
  const info = CHANNELS[channel];
  if (!info) throw new Error(`Unknown channel ${channel}`);
  const rendered = items.map(validateItem).map((item) => `    <item>
      <title>${escapeXml(item.title)}</title>
      <pubDate>${item.pubDate}</pubDate>
      <sparkle:version>${item.version}</sparkle:version>
      <sparkle:shortVersionString>${item.shortVersion}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${item.minimumSystemVersion}</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text">${escapeXml(item.notes)}</description>
      <enclosure url="${escapeXml(item.url)}" length="${item.length}" type="application/octet-stream" sparkle:edSignature="${item.signature}"/>
    </item>
`).join('');
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="${SPARKLE_NS}">
  <channel>
    <title>${escapeXml(info.title)}</title>
    <link>https://github.com/QuntmTech/mac-mint</link>
    <description>${escapeXml(info.description)}</description>
    <language>en</language>
${rendered}  </channel>
</rss>
`;
}

export function publicKeyFromBase64(base64) {
  const raw = Buffer.from(String(base64), 'base64');
  if (raw.length !== 32 || raw.toString('base64') !== String(base64)) throw new Error('SUPublicEDKey must be base64 of 32 bytes');
  return createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: raw.toString('base64url') }, format: 'jwk' });
}

/**
 * Checks the newest item against the archive the app will download: same build number as the
 * bundle's CFBundleVersion, same byte length, and an Ed25519 signature that SUPublicEDKey accepts.
 */
export function verifyAppcast({ xml, archive, publicKey, version, url }) {
  const problems = [];
  const items = parseItems(xml, (error) => problems.push(error.message));
  if (problems.length) throw new Error(`Appcast has invalid items: ${problems.join('; ')}`);
  if (items.length === 0) throw new Error('Appcast has no items');
  const newest = items.reduce((best, item) => (Number(item.version) > Number(best.version) ? item : best));
  if (newest.version !== String(version)) {
    throw new Error(`Newest sparkle:version ${newest.version} does not match CFBundleVersion ${version}`);
  }
  if (url !== undefined && newest.url !== url) throw new Error(`Newest item URL ${newest.url} is not ${url}`);
  if (Number(newest.length) !== archive.length) {
    throw new Error(`Enclosure length ${newest.length} does not match the archive (${archive.length} bytes)`);
  }
  const signature = Buffer.from(newest.signature, 'base64');
  if (!verifySignature(null, archive, publicKeyFromBase64(publicKey), signature)) {
    throw new Error(`edSignature for build ${newest.version} does not verify with SUPublicEDKey`);
  }
  return newest;
}

function parseArgs(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    if (!name?.startsWith('--') || argv[index + 1] === undefined) throw new Error(`Unexpected argument ${name}`);
    options[name.slice(2)] = argv[index + 1];
  }
  return options;
}

function required(options, ...names) {
  for (const name of names) if (!options[name]) throw new Error(`--${name} is required`);
}

function main([command, ...rest]) {
  const options = parseArgs(rest);
  if (command === 'generate') {
    required(options, 'channel', 'version', 'short-version', 'url', 'archive', 'signature', 'output');
    const subjects = options['changes-file'] ? readFileSync(options['changes-file'], 'utf8').split('\n') : [];
    const item = validateItem({
      version: options.version, shortVersion: options['short-version'], url: options.url,
      length: statSync(options.archive).size, signature: options.signature,
      pubDate: options['pub-date'] ?? rfc822(new Date()),
      notes: releaseNotes(subjects, options.since),
    });
    const existing = options.existing
      ? parseItems(readFileSync(options.existing, 'utf8'), (error) => console.warn(`Dropping existing item: ${error.message}`))
      : [];
    const keep = Number(options.keep ?? 10);
    if (!Number.isInteger(keep) || keep < 1 || keep > 50) throw new Error('--keep must be 1–50');
    const items = mergeItems(existing, item, keep);
    writeFileSync(options.output, renderAppcast(options.channel, items));
    console.log(`Wrote ${options.output}: ${items.length} item(s), newest build ${items[0].version}`);
  } else if (command === 'verify') {
    required(options, 'appcast', 'archive', 'public-key', 'version');
    const archive = readFileSync(options.archive);
    const newest = verifyAppcast({
      xml: readFileSync(options.appcast, 'utf8'), archive, publicKey: options['public-key'],
      version: options.version, url: options.url,
    });
    console.log(`✓ Build ${newest.version}: ${newest.length} bytes, EdDSA signature verified with SUPublicEDKey`);
  } else {
    throw new Error('Usage: sparkle_appcast.mjs generate|verify --option value …');
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`✗ ${error.message}`);
    process.exit(1);
  }
}
