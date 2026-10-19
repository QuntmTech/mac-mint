// node --test tests/sparkle_appcast.test.mjs — appcast generation and EdDSA verification.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  escapeXml, mergeItems, parseItems, releaseNotes, renderAppcast, rfc822, validateItem, verifyAppcast,
} from '../scripts/sparkle_appcast.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SCRIPT = join(ROOT, 'scripts/sparkle_appcast.mjs');

function keyPair() {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const raw = Buffer.from(publicKey.export({ format: 'jwk' }).x, 'base64url').toString('base64');
  return { privateKey, publicKey: raw };
}

function item(version, archive, privateKey, overrides = {}) {
  return validateItem({
    version: String(version), shortVersion: '0.9.0',
    url: `https://github.com/QuntmTech/mac-mint/releases/download/dev-build-${version}/MacMint.zip`,
    length: archive.length, signature: sign(null, archive, privateKey).toString('base64'),
    pubDate: rfc822(new Date(Date.UTC(2026, 9, 19, 12, 0, version % 60))), notes: `Build ${version}`, ...overrides,
  });
}

test('a generated appcast verifies against the public key and bundle version', () => {
  const { privateKey, publicKey } = keyPair();
  const archive = Buffer.from('MacMint.zip bytes');
  const xml = renderAppcast('developer', [item(312, archive, privateKey)]);
  assert.match(xml, /<sparkle:version>312<\/sparkle:version>/);
  assert.match(xml, /<sparkle:minimumSystemVersion>14\.0<\/sparkle:minimumSystemVersion>/);
  assert.match(xml, /sparkle:edSignature="[A-Za-z0-9+/]{86}=="/);
  assert.match(xml, /length="17"/);
  const newest = verifyAppcast({ xml, archive, publicKey, version: '312',
    url: 'https://github.com/QuntmTech/mac-mint/releases/download/dev-build-312/MacMint.zip' });
  assert.equal(newest.version, '312');
});

test('verification rejects tampering, other keys and version drift', () => {
  const { privateKey, publicKey } = keyPair();
  const archive = Buffer.from('MacMint.zip bytes');
  const xml = renderAppcast('developer', [item(312, archive, privateKey)]);
  const tampered = Buffer.from('MacMint.zip bytez');
  assert.throws(() => verifyAppcast({ xml, archive: tampered, publicKey, version: '312' }), /does not verify/);
  assert.throws(() => verifyAppcast({ xml, archive, publicKey: keyPair().publicKey, version: '312' }), /does not verify/);
  assert.throws(() => verifyAppcast({ xml, archive, publicKey, version: '313' }), /does not match CFBundleVersion 313/);
  assert.throws(() => verifyAppcast({ xml, archive: Buffer.concat([archive, Buffer.from('x')]), publicKey, version: '312' }),
    /length/);
  assert.throws(() => verifyAppcast({ xml, archive, publicKey, version: '312', url: 'https://github.com/x' }), /URL/);
  assert.throws(() => verifyAppcast({ xml, archive, publicKey: 'not-a-key', version: '312' }), /32 bytes/);
  assert.throws(() => verifyAppcast({ xml: renderAppcast('developer', []), archive, publicKey, version: '312' }), /no items/);
});

test('builds compare numerically, newest first, deduplicated and capped', () => {
  const { privateKey } = keyPair();
  const archive = Buffer.from('zip');
  const existing = [9, 100, 99, 10, 101].map((version) => item(version, archive, privateKey));
  const merged = mergeItems(existing, item(100, archive, privateKey, { notes: 'rebuilt' }), 3);
  assert.deepEqual(merged.map((entry) => entry.version), ['101', '100', '99']);
  assert.equal(merged[1].notes, 'rebuilt', 'A republished build replaces its old entry');
  const all = mergeItems([], item(7, archive, privateKey));
  assert.equal(all.length, 1);
});

test('existing items round-trip and invalid ones are dropped, never copied', () => {
  const { privateKey } = keyPair();
  const archive = Buffer.from('zip');
  const items = [item(205, archive, privateKey, { notes: 'Changes:\n• fix: <b>&</b> "quotes" ]]>' }), item(204, archive, privateKey)];
  const xml = renderAppcast('developer', items);
  assert.deepEqual(parseItems(xml), items);
  const hostile = xml
    .replace('dev-build-204/MacMint.zip', 'dev-build-204/Evil.zip')
    .replace('</channel>', '<item><title>x</title><sparkle:version>999</sparkle:version></item></channel>');
  const dropped = [];
  const parsed = parseItems(hostile, (error) => dropped.push(error.message));
  assert.deepEqual(parsed.map((entry) => entry.version), ['205']);
  assert.equal(dropped.length, 2);
  assert.throws(() => verifyAppcast({ xml: hostile, archive, publicKey: keyPair().publicKey, version: '205' }), /invalid items/);
});

test('release notes and text are escaped as plain text', () => {
  const notes = releaseNotes(['feat: <script>alert(1)</script>', '', 'fix: a & b\u0007', 'x'.repeat(250)], 'build 300');
  assert.equal(notes.split('\n')[0], 'Changes since build 300:');
  assert.ok(notes.includes('• fix: a & b'));
  assert.ok(notes.split('\n')[3].length <= 202);
  const xml = renderAppcast('developer', [item(301, Buffer.from('z'), keyPair().privateKey, { notes })]);
  assert.ok(!xml.includes('<script>'));
  assert.match(xml, /<description sparkle:format="plain-text">Changes since build 300:\n• feat: &lt;script&gt;/);
  assert.equal(releaseNotes([], undefined), 'Changes:\n• Maintenance build.');
  const many = releaseNotes(Array.from({ length: 45 }, (_, index) => `change ${index}`), 'v0.9.0');
  assert.ok(many.startsWith('Changes since v0.9.0:\n'));
  assert.equal(releaseNotes(['x'], '<b>'), 'Changes since b:\n• x');
  assert.ok(many.endsWith('• …and 5 more.'));
  assert.equal(escapeXml('a\u0000b\u{1F600}'), 'ab\u{1F600}');
});

test('items outside the release-asset allowlist are refused', () => {
  const { privateKey } = keyPair();
  const archive = Buffer.from('zip');
  for (const url of [
    'http://github.com/QuntmTech/mac-mint/releases/download/dev-build-1/MacMint.zip',
    'https://github.com/evil/mac-mint/releases/download/dev-build-1/MacMint.zip',
    'https://github.com/QuntmTech/mac-mint/releases/download/dev-build-1/MacMint.zip?x=1',
    'https://objects.githubusercontent.com/MacMint.zip',
    'https://github.com/QuntmTech/mac-mint/releases/download/a"b/MacMint.zip',
  ]) {
    assert.throws(() => item(1, archive, privateKey, { url }), /Untrusted/, url);
  }
  assert.throws(() => item(0, archive, privateKey), /sparkle:version/);
  assert.throws(() => item(1, archive, privateKey, { signature: 'AAAA' }), /edSignature/);
  assert.throws(() => item(1, archive, privateKey, { shortVersion: '1' }), /shortVersionString/);
  assert.throws(() => renderAppcast('nightly', []), /Unknown channel/);
});

test('the command line generates, merges and verifies an appcast', () => {
  // The host /tmp may be noexec; use the ignored build directory.
  mkdirSync(join(ROOT, '.build'), { recursive: true });
  const folder = mkdtempSync(join(ROOT, '.build', 'appcast-test-'));
  try {
    const { privateKey, publicKey } = keyPair();
    const zip = join(folder, 'MacMint.zip');
    const changes = join(folder, 'changes.txt');
    const output = join(folder, 'appcast-dev.xml');
    writeFileSync(changes, 'feat: one\nfix: two\n');
    const run = (version, existing) => {
      const archive = Buffer.from(`archive ${version}`);
      writeFileSync(zip, archive);
      const args = ['generate', '--channel', 'developer', '--version', String(version), '--short-version', '0.9.0',
        '--url', `https://github.com/QuntmTech/mac-mint/releases/download/dev-build-${version}/MacMint.zip`,
        '--archive', zip, '--signature', sign(null, archive, privateKey).toString('base64'),
        '--changes-file', changes, '--since', `build ${version - 1}`, '--keep', '2', '--output', output];
      if (existing) args.push('--existing', existing);
      execFileSync(process.execPath, [SCRIPT, ...args], { stdio: 'pipe' });
    };
    run(10);
    const first = join(folder, 'previous.xml');
    writeFileSync(first, readFileSync(output));
    run(11, first);
    writeFileSync(first, readFileSync(output));
    run(12, first);
    const xml = readFileSync(output, 'utf8');
    assert.deepEqual(parseItems(xml).map((entry) => entry.version), ['12', '11']);
    assert.match(xml, /Changes since build 11:\n• feat: one\n• fix: two/);
    const out = execFileSync(process.execPath, [SCRIPT, 'verify', '--appcast', output, '--archive', zip,
      '--public-key', publicKey, '--version', '12'], { encoding: 'utf8' });
    assert.match(out, /Build 12: \d+ bytes, EdDSA signature verified/);
    assert.throws(() => execFileSync(process.execPath, [SCRIPT, 'verify', '--appcast', output, '--archive', zip,
      '--public-key', publicKey, '--version', '11'], { stdio: 'pipe' }));
  } finally {
    rmSync(folder, { recursive: true, force: true });
  }
});
