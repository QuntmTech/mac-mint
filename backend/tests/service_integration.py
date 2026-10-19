"""Authenticated routes + actual SMTP/JWT recovery on a disposable PocketBase instance.

All provider responses and mail delivery terminate on loopback. No real API key, account,
payment, email recipient or provider service is used. Requires the CI-pinned PocketBase.
"""
from contextlib import ExitStack
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import datetime, json, os, re, shutil, socket, socketserver, sqlite3, subprocess, tempfile, threading, time
import urllib.error, urllib.parse, urllib.request

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('POCKETBASE_BIN', ROOT / '.build/pocketbase-bin/pocketbase')).resolve()
assert BINARY.exists(), 'Install the pinned PocketBase runtime first'
MAIL, SENT = [], []


class MailSink(socketserver.StreamRequestHandler):
    def handle(self):
        self.wfile.write(b'220 loopback mail fixture\r\n')
        while True:
            line = self.rfile.readline()
            if not line: return
            command = line.split(b' ', 1)[0].strip().upper()
            if command in (b'EHLO', b'HELO'): self.wfile.write(b'250 localhost\r\n')
            elif command == b'DATA':
                self.wfile.write(b'354 End with a dot\r\n')
                lines = []
                while True:
                    data = self.rfile.readline()
                    if not data or data == b'.\r\n': break
                    lines.append(data[1:] if data.startswith(b'..') else data)
                MAIL.append(BytesParser(policy=policy.default).parsebytes(b''.join(lines)))
                self.wfile.write(b'250 Captured locally\r\n')
            elif command == b'QUIT':
                self.wfile.write(b'221 Bye\r\n'); return
            elif command in (b'MAIL', b'RCPT', b'RSET', b'NOOP'): self.wfile.write(b'250 OK\r\n')
            else: self.wfile.write(b'502 Unsupported\r\n')


class Provider(BaseHTTPRequestHandler):
    mode = 'ok'
    def log_message(self, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        SENT.append(request)
        mode = Provider.mode
        if mode == 'timeout': time.sleep(2)
        schema = request['output_config']['format']['schema']['properties']
        if 'answer' in schema:
            output = dict(answer='Inspect and review locally.', actions=[
                dict(label='Open Storage', destination='storage'),
                dict(label='Run malicious command', destination='shortcuts://remove-everything')])
        elif 'proposals' in schema:
            output = dict(proposals=[dict(fileID='f0', folderID='d1', name='Invoice 2026.pdf', reason='File by its existing name')])
        elif 'headline' in schema:
            output = dict(headline='Review the findings', notes=[dict(id='caches', order=1, note='Rebuildable')],
                insights=[], cautions=[])
        else:
            output = dict(summary='Rebuildable data', owner='Known tool', category='cache', verdict='review',
                whatHappens='May require rebuilding', confidence='medium')
        if mode == 'null': output = None
        if mode == 'wrong-shape': output = dict(answer=42, actions=[])
        if mode == 'empty-answer': output = dict(answer='', actions=[])
        response = dict(content=[dict(type='text', text='invalid JSON' if mode == 'malformed' else json.dumps(output))],
            usage=dict(input_tokens=100, output_tokens=20, cache_creation_input_tokens=50, cache_read_input_tokens=200))
        if mode == 'missing-usage': response.pop('usage')
        raw = json.dumps(response).encode()
        try:
            self.send_response(429 if mode == 'busy' else 200)
            self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError): pass


def serve(stack, server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    stack.callback(server.server_close); stack.callback(server.shutdown)
    return server


with ExitStack() as stack:
    smtp = serve(stack, socketserver.ThreadingTCPServer(('127.0.0.1', 0), MailSink))
    provider = serve(stack, ThreadingHTTPServer(('127.0.0.1', 0), Provider))
    folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='pb-services-', dir=ROOT / '.build')))
    shutil.copytree(ROOT / 'backend/pocketbase/pb_hooks', folder / 'hooks')
    shutil.copytree(ROOT / 'backend/pocketbase/pb_migrations', folder / 'migrations')
    # Only this copied test runtime has its provider transport redirected or timeout shortened.
    library = folder / 'hooks/macmint_ai_lib.js'
    # The test control route can point the copied client at a closed port to prove that
    # connection failures (no request sent) are released rather than held as uncertain.
    source = library.read_text()
    for marker in ['"https://api.anthropic.com/v1/messages"', 'const HTTP_TIMEOUT_SECONDS = 30', 'const LONG_HTTP_TIMEOUT_SECONDS = 90']:
        assert marker in source, marker
    library.write_text(source.replace('"https://api.anthropic.com/v1/messages"',
        f'($app.store().has("test_provider_url") ? $app.store().get("test_provider_url") : "http://127.0.0.1:{provider.server_port}/v1/messages")')
        .replace('const HTTP_TIMEOUT_SECONDS = 30', 'const HTTP_TIMEOUT_SECONDS = 1').replace('const LONG_HTTP_TIMEOUT_SECONDS = 90', 'const LONG_HTTP_TIMEOUT_SECONDS = 1'))
    (folder / 'migrations/1792109300_test_seed.js').write_text('''migrate(app=>{
      const settings=app.settings();settings.meta.appName="MacMint";settings.meta.appURL="https://macmint.co";
      settings.meta.senderAddress="support@macmint.co";settings.smtp.enabled=true;settings.smtp.host="127.0.0.1";
      settings.smtp.port=SMTP_PORT;settings.smtp.tls=false;app.save(settings)
      for(const name of ["fixture","unverified","expired"]){
        const u=new Record(app.findCollectionByNameOrId("users"));u.set("email",name+"@example.invalid");
        u.setPassword("fixture-password-123");u.set("verified",name==="fixture");app.save(u)
        if(name==="fixture"){const ent=new Record(app.findCollectionByNameOrId("plan_entitlements"));
          ent.set("user",u.id);ent.set("plan","pro");ent.set("status","active");ent.set("max_devices",1);app.save(ent)}
      }
      // Pre-split layout: budgets in the public record must move to the private ai_limits record.
      const c=new Record(app.findCollectionByNameOrId("app_config"));c.set("key","ai");c.set("value",{enabled:true,daily_usd_budget:20});c.set("public",true);app.save(c)
      const su=new Record(app.findCollectionByNameOrId("_superusers"));su.set("email","operator@example.invalid");su.setPassword("operator-password-123");app.save(su)
    },()=>{})'''.replace('SMTP_PORT', str(smtp.server_address[1])))
    # Test-only control route is never copied into production hooks or exposed off loopback.
    (folder / 'hooks/test.pb.js').write_text('''routerAdd("POST","/__test/config",e=>{
      const data=e.requestInfo().body;
      if(data.expireReset){const users=e.app.findCollectionByNameOrId("users");users.passwordResetToken.duration=10;e.app.save(users)}
      if(data.ai){const c=e.app.findFirstRecordByFilter("app_config","key='ai'");c.set("value",data.ai);e.app.save(c)}
      if(data.limits){const c=e.app.findFirstRecordByFilter("app_config","key='ai_limits'");c.set("value",data.limits);e.app.save(c)}
      if(data.providerURL!==undefined){if(data.providerURL)e.app.store().set("test_provider_url",data.providerURL);else e.app.store().remove("test_provider_url")}
      return e.json(200,{ok:true})
    })
    routerAdd("GET","/__test/rate-limits",e=>{
      const limits=e.app.settings().rateLimits
      return e.json(200,{enabled:limits.enabled,labels:limits.rules.map(r=>r.label)})
    })''')
    base = [str(BINARY), '--dir', str(folder / 'data'), '--hooksDir', str(folder / 'hooks'), '--migrationsDir', str(folder / 'migrations')]
    result = subprocess.run(base + ['migrate', 'up'], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]
    origin = f'http://127.0.0.1:{port}'
    log = stack.enter_context((folder / 'server.log').open('w'))
    process = subprocess.Popen(base + ['serve', '--http', f'127.0.0.1:{port}'], stdout=log, stderr=log,
        env={**os.environ, 'ANTHROPIC_API_KEY': 'loopback-fixture-only', 'AI_DAILY_TOKEN_BUDGET': '', 'AI_DAILY_USD_BUDGET': ''})
    def stop():
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    stack.callback(stop)

    def call(path, data=None, token=None):
        headers = {'Content-Type': 'application/json'}
        if token: headers['Authorization'] = token
        request = urllib.request.Request(origin + path, data=json.dumps(data).encode() if data is not None else None, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                raw = response.read(); return response.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    for _ in range(100):
        try:
            if call('/api/health')[0] == 200: break
        except (OSError, urllib.error.URLError): time.sleep(.05)
    status, auth = call('/api/collections/users/auth-with-password', dict(identity='fixture@example.invalid', password='fixture-password-123'))
    assert status == 200, 'Fixture sign-in failed'
    token = auth['token']
    db = sqlite3.connect(folder / 'data/data.db')
    stack.callback(db.close)
    status, public = call('/api/collections/app_config/records?perPage=50')
    published = {item['key']: item['value'] for item in public['items']}
    assert status == 200 and published.get('ai') == dict(enabled=True) and 'ai_limits' not in published, published
    assert json.loads(db.execute("SELECT value FROM app_config WHERE key='ai_limits'").fetchone()[0]) == dict(daily_usd_budget=20)
    limits = call('/__test/rate-limits')[1]
    assert limits['enabled'] is False and '/api/macmint/redeem' in limits['labels'], limits
    print('PASS: public AI config exposes only switches; limits are private; rate limits stay off without a trusted proxy')
    # This runtime has no entitlement signing key: online access works, offline evidence is omitted.
    device = 'SERVICE-FIXTURE-0001'
    status, activated = call('/api/macmint/devices/activate', dict(device_id=device, reactivate=False, name='Fixture'), token)
    assert status == 200 and activated['entitlement']['active'] and 'entitlement_assertion' not in activated, activated
    status, me = call('/api/macmint/me?device_id=' + device, token=token)
    assert status == 200 and me['devices'][0]['device_id'] == device and 'entitlement_assertion' not in me, me
    log.flush()
    assert (folder / 'server.log').read_text().count('no entitlement signing key configured') == 1
    print('PASS: without a signing key, activation and /me stay usable online, omit the offline assertion and log it once')
    question = 'Why is storage full?'
    def ask(context=None): return call('/api/macmint/ai/ask', dict(question=question, context=context or {}), token)
    assert call('/api/macmint/ai/ask', dict(question=question))[0] in (401, 403)
    assert not SENT, 'Unauthenticated request reached provider'
    status, answer = ask(dict(biggestFolders=[dict(path='~/Documents/Medical Report.pages', gb=9),dict(path='~/Downloads',gb=1)],
        unusedApps=[dict(name='Jane Doe jane@example.invalid', gb=3)],
        recommendations=[dict(title='秘密 jane@example.invalid', gb=3)]))
    assert status == 200, (status, answer)
    automatic = json.loads(SENT[-1]['messages'][0]['content'].split('\n\n', 1)[1])
    serialized = json.dumps(automatic, ensure_ascii=False)
    assert all(secret not in serialized for secret in ['Medical Report', 'Jane Doe', 'jane@example.invalid', '秘密'])
    assert '~/Downloads' in serialized
    assert all(a['destination'] in ('storage', 'dashboard') for a in answer['actions'])
    assert db.execute("SELECT actual_tokens FROM ai_requests WHERE feature='ask'").fetchone()[0] == 370
    assert db.execute("SELECT spent_micro_usd FROM ai_daily_budgets").fetchone()[0] == 1090
    print('PASS: authenticated AI route strips automatic personal names, limits navigation and accounts for cache tokens')

    inventory = dict(files=[dict(id='f0', name='Jane Invoice.pdf')], folders=[dict(id='root', name='This folder'),dict(id='d1', name='Documents')])
    count = len(SENT)
    assert call('/api/macmint/ai/organize', inventory, token)[0] == 503
    assert len(SENT) == count, 'Unenabled organization reached provider'
    call('/__test/config', dict(ai=dict(enabled=True, features=dict(organize=True))))
    status, organized = call('/api/macmint/ai/organize', inventory, token)
    assert status == 200 and organized['proposals'][0]['fileID'] == 'f0', (status, organized)
    sent_names = json.loads(SENT[-1]['messages'][0]['content'].split('\n\n', 1)[1])
    assert sent_names == inventory and 'path' not in json.dumps(sent_names)
    assert db.execute("SELECT organize FROM ai_usage").fetchone()[0] == 1
    Provider.mode = 'wrong-shape'
    assert call('/api/macmint/ai/organize', inventory, token)[0] == 502
    Provider.mode = 'ok'
    call('/__test/config', dict(ai=dict(enabled=True)))
    print('PASS: organization flag, authenticated structured proposals, name-only payload and transactional allowance')

    count = len(SENT)
    explained = db.execute("SELECT explain FROM ai_usage").fetchone()[0]
    for kind, name in [('library-item', 'Jane jane@example.invalid.pages'), ('developer-tool', 'Jane secret tool'), ('launch-agent', 'com.jane.private')]:
        status, local = call('/api/macmint/ai/explain', dict(kind=kind, identifier=name, location='Caches'), token)
        assert status == 200 and local['model'] == 'local' and local['explanation']['verdict'] == 'unknown', (status, local)
    assert len(SENT) == count, 'Placeholder explanations reached the provider'
    assert db.execute("SELECT explain FROM ai_usage").fetchone()[0] == explained
    assert db.execute("SELECT COUNT(*) FROM ai_requests WHERE feature='explain'").fetchone()[0] == 0
    status, known = call('/api/macmint/ai/explain', dict(kind='library-item', identifier='com.spotify.client', location='Caches'), token)
    assert status == 200 and known['model'] != 'local' and len(SENT) == count + 1, known
    print('PASS: unrecognized explain placeholders are answered locally with zero provider calls and no allowance')
    status, _ = call('/api/macmint/ai/review', dict(recommendations=[dict(id='caches', title='秘密', detail='jane@example.invalid', bytes=100)]), token)
    assert status == 200
    assert 'jane@example.invalid' not in json.dumps(SENT[-1])
    assert call('/__test/config', dict(limits=dict(models=dict(ask='claude-sonnet-5-5'))))[0] == 200
    assert ask()[0] == 200 and SENT[-1]['model'] == 'claude-sonnet-5-5'
    count = len(SENT)
    for public_cfg, private, expected, error in [(dict(enabled=False), {}, 503, 'ai_disabled'), (dict(enabled=True, features=dict(ask=False)), {}, 503, 'ai_disabled'),
                       (dict(enabled=True), dict(daily_usd_budget=0), 503, 'ai_capacity'), (dict(enabled=True, daily_usd_budget=0), {}, 503, 'ai_capacity'),
                       (dict(enabled=True), dict(models=dict(ask='unknown')), 503, 'ai_model_config'),
                       (dict(enabled=True), dict(user_daily_usd_cap=0.0001), 429, 'ai_user_budget')]:
        call('/__test/config', dict(ai=public_cfg, limits=private))
        status, body = ask(); assert status == expected and body['error'] == error, (public_cfg, private, status, body)
    assert len(SENT) == count, 'Kill switch, exhausted budget or user cap reached provider'
    call('/__test/config', dict(ai=dict(enabled=True), limits={}))
    for mode, error, state in [('busy','ai_busy','released'),('malformed','ai_upstream','settled'),
                               ('null','ai_upstream','settled'),('wrong-shape','ai_upstream','settled'),('empty-answer','ai_upstream','settled'),
                               ('missing-usage','ai_accounting','uncertain'),('timeout','ai_timeout','uncertain'),('refused','ai_unreachable','released')]:
        Provider.mode = mode
        if mode == 'refused':
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0)); closed = probe.getsockname()[1]
            call('/__test/config', dict(providerURL=f'http://127.0.0.1:{closed}/v1/messages'))
        before = {row[0] for row in db.execute('SELECT id FROM ai_requests')}
        asked = db.execute('SELECT ask FROM ai_usage').fetchone()[0]
        status, body = ask(); assert status in (502,503) and body['error'] == error, (mode,status,body)
        records = [(identifier,state) for identifier,state in db.execute('SELECT id,state FROM ai_requests') if identifier not in before]
        assert len(records) == 1 and records[0][1] == state, (mode, records)
        assert db.execute('SELECT ask FROM ai_usage').fetchone()[0] == asked + (state != 'released'), mode
    call('/__test/config', dict(providerURL=''))
    Provider.mode = 'ok'
    print('PASS: effective model, kill switches, zero budgets, user cap, malformed output, known refund, released connection failure and uncertain timeout')

    status, operator = call('/api/collections/_superusers/auth-with-password', dict(identity='operator@example.invalid', password='operator-password-123'))
    assert status == 200, operator
    status, crons = call('/api/crons', token=operator['token'])
    assert status == 200 and any(job['id'] == 'macmint_ai_stale_reservations' for job in crons), crons
    held = [row[0] for row in db.execute("SELECT id FROM ai_requests WHERE state='uncertain'")]
    assert len(held) == 2, held
    reserved = db.execute('SELECT reserved_micro_usd FROM ai_daily_budgets').fetchone()[0]
    stale = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)).strftime('%Y-%m-%d %H:%M:%S.000Z')
    db.execute('UPDATE ai_requests SET created=? WHERE id=?', (stale, held[0])); db.commit()
    assert call('/api/crons/macmint_ai_stale_reservations', {}, operator['token'])[0] == 204
    for _ in range(100):
        flagged = {identifier for identifier, mark in db.execute("SELECT id, flagged_at FROM ai_requests WHERE state='uncertain'") if mark}
        if flagged: break
        time.sleep(.05)
    assert flagged == {held[0]}, flagged
    assert db.execute('SELECT reserved_micro_usd FROM ai_daily_budgets').fetchone()[0] == reserved, 'Flagging must not free reservations'
    print('PASS: hourly cron flags stale uncertain reservations for reconciliation without freeing them')

    def captured(address, subject):
        for _ in range(100):
            matches = [m for m in MAIL if address in str(m['To']) and subject in str(m['Subject'])]
            if matches: return matches[-1]
            time.sleep(.02)
        raise AssertionError('No local SMTP message for ' + subject)
    def mail_token(message, route):
        html = message.get_body(preferencelist=('html',)).get_content()
        url = next(url for url in re.findall(r'href="([^"]+)"', html) if route in url)
        parts = urllib.parse.urlparse(url)
        assert parts.scheme == 'https' and parts.netloc == 'macmint.co' and parts.path == route
        return urllib.parse.parse_qs(parts.query)['token'][0]

    assert call('/api/collections/users/request-verification', dict(email='unverified@example.invalid'))[0] == 204
    verify = mail_token(captured('unverified@example.invalid', 'Verify'), '/verify-email')
    assert call('/api/collections/users/confirm-verification', dict(token=verify))[0] == 204
    assert db.execute("SELECT verified FROM users WHERE email='unverified@example.invalid'").fetchone()[0] == 1
    assert call('/api/collections/users/confirm-verification', dict(token=verify+'invalid'))[0] == 400
    assert call('/api/collections/users/request-password-reset', dict(email='fixture@example.invalid'))[0] == 204
    reset = mail_token(captured('fixture@example.invalid', 'Reset'), '/reset-password')
    assert call('/api/collections/users/confirm-password-reset', dict(token=reset,password='new-password-456',passwordConfirm='new-password-456'))[0] == 204
    assert call('/api/collections/users/confirm-password-reset', dict(token=reset,password='other-password-789',passwordConfirm='other-password-789'))[0] == 400
    assert call('/api/collections/users/auth-with-password', dict(identity='fixture@example.invalid',password='fixture-password-123'))[0] == 400
    assert call('/api/collections/users/auth-with-password', dict(identity='fixture@example.invalid',password='new-password-456'))[0] == 200
    assert call('/__test/config', dict(expireReset=True))[0] == 200
    assert call('/api/collections/users/request-password-reset', dict(email='expired@example.invalid'))[0] == 204
    expired = mail_token(captured('expired@example.invalid', 'Reset'), '/reset-password')
    time.sleep(11)
    assert call('/api/collections/users/confirm-password-reset', dict(token=expired,password='new-password-456',passwordConfirm='new-password-456'))[0] == 400
    count = len(MAIL)
    assert call('/api/collections/users/request-password-reset', dict(email='nobody@example.invalid'))[0] == 204
    time.sleep(.1); assert len(MAIL) == count
    print('PASS: real local SMTP verification and reset, correct website links, changed password, token replay/tampering/expiry, unknown-email privacy')
