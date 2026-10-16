"""Disposable PocketBase integration checks. No production account, credentials or network calls.
Set POCKETBASE_BIN to PocketBase 0.40.5. Stripe responses below are local protocol fixtures.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import concurrent.futures, hashlib, hmac, json, os, shutil, socket, sqlite3, subprocess, tempfile, threading, time, urllib.request, urllib.error, urllib.parse, uuid

root = Path(__file__).resolve().parents[2]
pocketbase = Path(os.environ.get('POCKETBASE_BIN', root / '.build/pocketbase-bin/pocketbase')).resolve()
assert pocketbase.exists(), 'Set POCKETBASE_BIN to the pinned PocketBase executable'
(root / '.build').mkdir(exist_ok=True)
sessions = {}

class StripeFixture(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, body):
        data = json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path.startswith('/v1/prices/'):
            return self.respond(dict(id='price_fixture', active=True, type='one_time', unit_amount=1900, currency='usd', livemode=False))
        session_id = self.path.split('?')[0].rsplit('/', 1)[-1]
        self.respond(sessions[session_id])
    def do_POST(self):
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        order = fields['metadata[macmint_order]'][0]
        session_id = 'cs_test_' + order
        sessions.setdefault(session_id, dict(id=session_id, metadata=dict(macmint_order=order), client_reference_id=fields['client_reference_id'][0],
            mode='payment', payment_status='unpaid', currency='usd', amount_total=1900, livemode=False,
            line_items=dict(has_more=False, data=[dict(quantity=1, price=dict(id='price_fixture'))]), url='https://checkout.stripe.com/c/pay/' + session_id))
        self.respond(sessions[session_id])

fixture = ThreadingHTTPServer(('127.0.0.1', 0), StripeFixture)
threading.Thread(target=fixture.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='pb-integration-', dir=root / '.build') as raw:
    folder = Path(raw)
    shutil.copytree(root / 'backend/pocketbase/pb_hooks', folder / 'hooks')
    shutil.copytree(root / 'backend/pocketbase/pb_migrations', folder / 'migrations')
    # Redirect ONLY the copied test client. Production code always uses Stripe's HTTPS API.
    client = folder / 'hooks/macmint_payments_lib.js'
    client.write_text(client.read_text().replace('https://api.stripe.com/v1/', f'http://127.0.0.1:{fixture.server_port}/v1/'))
    (folder / 'migrations/1792108700_existing_ids_fixture.js').write_text('''migrate(app=>{
      app.save(new Collection({id:"legacy_licenses",name:"licenses",type:"base"}))
      const users=app.findCollectionByNameOrId("users");users.verificationTemplate={subject:"Operator verification",body:"Custom verification {TOKEN}"};
      users.passwordResetToken.duration=3600;app.save(users)
    },()=>{})''')
    (folder / 'migrations/1792109100_test_seed.js').write_text('''migrate(app=>{
      const u=new Record(app.findCollectionByNameOrId("users"));u.set("email","fixture@example.invalid");u.setPassword("fixture-test-password-123");u.set("verified",true);app.save(u)
      const ent=new Record(app.findCollectionByNameOrId("plan_entitlements"));ent.set("user",u.id);ent.set("plan","pro");ent.set("status","active");ent.set("max_devices",1);app.save(ent)
      for(const [key,value] of [["ai",{enabled:true}],["commerce",{enabled:true,price_id:"price_fixture",amount_minor:1900,currency:"usd",plan:"pro",duration_days:365,max_devices:3,livemode:false}]]){
        const c=new Record(app.findCollectionByNameOrId("app_config"));c.set("key",key);c.set("value",value);app.save(c)
      }
      const release=new Record(app.findCollectionByNameOrId("app_releases"));release.set("version","0.0.1");release.set("channel","stable");release.set("sha256","a".repeat(64));release.set("download_url","https://example.invalid/fixture.zip");release.set("validated",true);release.set("notarized",true);release.set("published",true);app.save(release)
    },()=>{})''')
    (folder / 'hooks/test.pb.js').write_text('''routerAdd("POST","/__test/reserve",e=>{
      const ai=require(`${__hooks}/macmint_ai_lib.js`),user=e.app.findFirstRecordByFilter("users","email='fixture@example.invalid'")
      try{return e.json(200,{id:ai.reserve(e.app,user.id,"review","claude-opus-5-5",100,100)})}
      catch(err){return e.json(err.status||500,{error:err.code||String(err)})}
    })
    routerAdd("GET","/__test/auth-config",e=>{
      const users=e.app.findCollectionByNameOrId("users")
      return e.json(200,{subject:users.verificationTemplate.subject,resetSeconds:users.passwordResetToken.duration})
    })''')
    base = [str(pocketbase), '--dir', str(folder / 'data'), '--hooksDir', str(folder / 'hooks'), '--migrationsDir', str(folder / 'migrations')]
    for _ in range(2):
        result = subprocess.run(base + ['migrate', 'up'], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    origin = f'http://127.0.0.1:{port}'
    def call(path, data=None, token=None, headers=None):
        content = data if isinstance(data, bytes) else (json.dumps(data).encode() if data is not None else None)
        request_headers = {'Content-Type': 'application/json', **(headers or {})}
        if token: request_headers['Authorization'] = token
        request = urllib.request.Request(origin + path, data=content, headers=request_headers)
        try:
            with urllib.request.urlopen(request, timeout=20) as response: return response.status, json.load(response)
        except urllib.error.HTTPError as error: return error.code, json.load(error)
    with (folder / 'server.log').open('w') as log:
        process = subprocess.Popen(base + ['serve', '--http', f'127.0.0.1:{port}'], stdout=log, stderr=log,
            env={**os.environ, 'STRIPE_RESTRICTED_KEY': 'fixture-only', 'STRIPE_WEBHOOK_SECRET': 'fixture-signing-secret'})
        try:
            for _ in range(100):
                try:
                    if call('/api/health')[0] == 200: break
                except Exception: time.sleep(.1)
            status, auth = call('/api/collections/users/auth-with-password', dict(identity='fixture@example.invalid', password='fixture-test-password-123'))
            assert status == 200, (status, auth)
            token = auth['token']
            assert call('/__test/auth-config')[1] == dict(subject='Operator verification',resetSeconds=3600)
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                results = list(pool.map(lambda _: call('/__test/reserve', {}), range(16)))
            assert sum(status == 200 for status, _ in results) == 8, results
            assert sum(status == 429 for status, _ in results) == 8, results
            print('PASS: 16 concurrent AI reservations, exactly 8 approvals')
            device_ids = [str(uuid.uuid4()) for _ in range(8)]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda identifier: call('/api/macmint/devices/activate', dict(device_id=identifier, name='Fixture'), token), device_ids))
            assert sum(status == 200 for status, _ in results) == 1, results
            assert sum(status == 409 for status, _ in results) == 7, results
            active = next(value['device']['device_id'] for status, value in results if status == 200)
            assert call('/api/macmint/devices/deactivate', dict(device_id=active), token)[0] == 200
            assert call('/api/macmint/devices/activate', dict(device_id=active), token)[0] == 409
            assert call('/api/macmint/devices/activate', dict(device_id=active, reactivate=True), token)[0] == 200
            print('PASS: concurrent activation respects last slot; removed device requires explicit reactivation')
            status, checkout = call('/api/macmint/checkout', dict(request_key=str(uuid.uuid4())), token)
            assert status == 200, (status, checkout)
            session = next(iter(sessions.values()))
            def webhook(event_type, valid=True):
                event = dict(type=event_type, data=dict(object=dict(id=session['id'], metadata=session['metadata'])))
                raw = json.dumps(event).encode(); timestamp = str(int(time.time()))
                signature = hmac.new(b'fixture-signing-secret', timestamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
                return call('/api/macmint/stripe/webhook', raw, headers={'Stripe-Signature': f't={timestamp},v1={signature if valid else "0" * 64}'})
            assert webhook('checkout.session.completed', False)[0] == 400
            assert webhook('checkout.session.completed')[0] == 200  # still unpaid
            db = sqlite3.connect(folder / 'data/data.db')
            assert db.execute('SELECT COUNT(*) FROM licenses').fetchone()[0] == 0
            session['payment_status'] = 'paid'
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                events = list(pool.map(lambda _: webhook('checkout.session.async_payment_succeeded'), range(8)))
            assert all(status == 200 for status, _ in events), events
            assert db.execute('SELECT COUNT(*) FROM licenses').fetchone()[0] == 1
            assert db.execute('SELECT state FROM checkout_orders').fetchone()[0] == 'fulfilled'
            assert db.execute("SELECT id FROM _collections WHERE name='licenses'").fetchone()[0] == 'legacy_licenses'
            db.close()
            print('PASS: real raw-body HMAC, unpaid -> paid fulfillment, 8 duplicate concurrent webhooks grant one license')
            print('PASS: migrations preserve pre-existing collection IDs and reapply cleanly')
        finally:
            process.terminate(); process.wait(timeout=5)
fixture.shutdown()
