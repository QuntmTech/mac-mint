"""Authenticated routes + actual SMTP/JWT recovery on a disposable PocketBase instance.

All provider responses and mail delivery terminate on loopback. No real API key, account,
payment, email recipient or provider service is used. Requires the CI-pinned PocketBase.
"""
from contextlib import ExitStack
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json, os, re, shutil, socket, socketserver, sqlite3, subprocess, tempfile, threading, time
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
        elif 'headline' in schema:
            output = dict(headline='Review the findings', notes=[dict(id='caches', order=1, note='Rebuildable')],
                insights=[], cautions=[])
        else:
            output = dict(summary='Rebuildable data', owner='Known tool', category='cache', verdict='review',
                whatHappens='May require rebuilding', confidence='medium')
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
    library.write_text(library.read_text().replace('https://api.anthropic.com/v1/messages',
        f'http://127.0.0.1:{provider.server_port}/v1/messages').replace('const HTTP_TIMEOUT_SECONDS = 30', 'const HTTP_TIMEOUT_SECONDS = 1'))
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
      const c=new Record(app.findCollectionByNameOrId("app_config"));c.set("key","ai");c.set("value",{enabled:true});app.save(c)
    },()=>{})'''.replace('SMTP_PORT', str(smtp.server_address[1])))
    # Test-only control route is never copied into production hooks or exposed off loopback.
    (folder / 'hooks/test.pb.js').write_text('''routerAdd("POST","/__test/config",e=>{
      const data=e.requestInfo().body;
      if(data.expireReset){const users=e.app.findCollectionByNameOrId("users");users.passwordResetToken.duration=10;e.app.save(users)}
      if(data.ai){const c=e.app.findFirstRecordByFilter("app_config","key='ai'");c.set("value",data.ai);e.app.save(c)}
      return e.json(200,{ok:true})
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

    status, _ = call('/api/macmint/ai/explain', dict(kind='library-item', identifier='Jane jane@example.invalid.pages', location='Caches'), token)
    assert status == 200
    assert 'jane@example.invalid' not in json.dumps(SENT[-1])
    status, _ = call('/api/macmint/ai/review', dict(recommendations=[dict(id='caches', title='秘密', detail='jane@example.invalid', bytes=100)]), token)
    assert status == 200
    assert 'jane@example.invalid' not in json.dumps(SENT[-1])
    assert call('/__test/config', dict(ai=dict(enabled=True, models=dict(ask='claude-sonnet-5-5'))))[0] == 200
    assert ask()[0] == 200 and SENT[-1]['model'] == 'claude-sonnet-5-5'
    count = len(SENT)
    for cfg, error in [(dict(enabled=False),'ai_disabled'),(dict(enabled=True, features=dict(ask=False)),'ai_disabled'),
                       (dict(enabled=True, daily_usd_budget=0),'ai_capacity'),(dict(enabled=True, models=dict(ask='unknown')),'ai_model_config')]:
        call('/__test/config', dict(ai=cfg))
        status, body = ask(); assert status == 503 and body['error'] == error, body
    assert len(SENT) == count, 'Kill switch or exhausted budget reached provider'
    call('/__test/config', dict(ai=dict(enabled=True)))
    for mode, error, state in [('busy','ai_busy','released'),('malformed','ai_upstream','settled'),
                               ('missing-usage','ai_accounting','uncertain'),('timeout','ai_timeout','uncertain')]:
        Provider.mode = mode
        before = {row[0] for row in db.execute('SELECT id FROM ai_requests')}
        status, body = ask(); assert status in (502,503) and body['error'] == error, (mode,status,body)
        records = [(identifier,state) for identifier,state in db.execute('SELECT id,state FROM ai_requests') if identifier not in before]
        assert len(records) == 1 and records[0][1] == state, (mode, records)
    print('PASS: effective model, kill switches, zero currency budget, malformed output, known refund and uncertain timeout settlement')

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
