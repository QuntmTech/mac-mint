"""Disposable PocketBase integration checks. No production account, credentials or network calls.
Set POCKETBASE_BIN to PocketBase 0.40.5. Stripe responses below are local protocol fixtures.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import base64, concurrent.futures, hashlib, hmac, json, os, shutil, socket, sqlite3, subprocess, tempfile, threading, time, urllib.request, urllib.error, urllib.parse, uuid

root = Path(__file__).resolve().parents[2]
pocketbase = Path(os.environ.get('POCKETBASE_BIN', root / '.build/pocketbase-bin/pocketbase')).resolve()
assert pocketbase.exists(), 'Set POCKETBASE_BIN to the pinned PocketBase executable'
(root / '.build').mkdir(exist_ok=True)
sessions = {}
provider_requests = []
# Disposable Ed25519 seed for this run only; signatures are checked independently with Node's crypto.
signing_seed = os.urandom(32)
signing_key = 'mm-it-1:' + base64.b64encode(signing_seed).decode()
VERIFY_JS = """const c=require('crypto'),[compact,seed]=process.argv.slice(1),[p,s]=compact.split('.')
const key=c.createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.from(seed,'base64')]),format:'der',type:'pkcs8'})
process.stdout.write(c.verify(null,Buffer.from(p,'base64url'),c.createPublicKey(key),Buffer.from(s,'base64url'))?'valid':'invalid')"""

def verified_claims(compact):
    result = subprocess.run(['node', '-e', VERIFY_JS, compact, base64.b64encode(signing_seed).decode()], capture_output=True, text=True)
    assert result.stdout == 'valid', (result.stdout, result.stderr)
    payload = compact.split('.')[0]
    return json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))

class StripeFixture(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, body):
        data = json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        provider_requests.append(("GET", self.path))
        if self.path.startswith('/v1/prices/'):
            return self.respond(dict(id='price_fixture', active=True, type='one_time', unit_amount=1900, currency='usd', livemode=False))
        session_id = self.path.split('?')[0].rsplit('/', 1)[-1]
        self.respond(sessions[session_id])
    def do_POST(self):
        provider_requests.append(("POST", self.path))
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        order = fields['metadata[macmint_order]'][0]
        session_id = 'cs_test_' + order
        sessions.setdefault(session_id, dict(id=session_id, metadata=dict(macmint_order=order), client_reference_id=fields['client_reference_id'][0],
            mode='payment', payment_status='unpaid', status='open', expires_at=int(time.time()) + 3600,
            currency='usd', amount_total=1900, livemode=False,
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
      const second=new Record(app.findCollectionByNameOrId("users"));second.set("email","second@example.invalid");second.setPassword("fixture-test-password-123");second.set("verified",true);app.save(second)
      const ent=new Record(app.findCollectionByNameOrId("plan_entitlements"));ent.set("user",u.id);ent.set("plan","pro");ent.set("status","active");ent.set("max_devices",1);app.save(ent)
      for(const [key,value] of [["ai",{enabled:true}],["commerce",{enabled:true,price_id:"price_fixture",amount_minor:1900,currency:"usd",plan:"pro",duration_days:365,max_devices:3,livemode:false,web_origin:"https://staging.macmint.test"}]]){
        const c=new Record(app.findCollectionByNameOrId("app_config"));c.set("key",key);c.set("value",value);app.save(c)
      }
      const release=new Record(app.findCollectionByNameOrId("app_releases"));release.set("version","0.0.1");release.set("channel","stable");release.set("sha256","a".repeat(64));release.set("download_url","https://example.invalid/fixture.zip");release.set("validated",true);release.set("notarized",true);release.set("published",true);app.save(release)
    },()=>{})''')
    (folder / 'hooks/test.pb.js').write_text('''routerAdd("POST","/__test/reserve",e=>{
      const ai=require(`${__hooks}/macmint_ai_lib.js`),user=e.app.findFirstRecordByFilter("users","email='fixture@example.invalid'")
      try{return e.json(200,{id:ai.reserve(e.app,user.id,"review","claude-opus-5-5",100,100)})}
      catch(err){return e.json(err.status||500,{error:err.code||String(err)})}
    })
    routerAdd("POST","/__test/client-config",e=>{
      let c;try{c=e.app.findFirstRecordByFilter("app_config","key='client'")}catch(_){c=new Record(e.app.findCollectionByNameOrId("app_config"));c.set("key","client")}
      c.set("value",e.requestInfo().body);e.app.save(c);return e.json(200,{ok:true})
    })
    routerAdd("POST","/__test/license",e=>{
      const r=new Record(e.app.findCollectionByNameOrId("licenses")),code=e.requestInfo().body.code
      r.set("code",code);r.set("code_hint",code.slice(-4));r.set("plan","pro");r.set("duration_days",30);r.set("max_devices",1);r.set("status","available");r.set("source","manual")
      e.app.save(r);return e.json(200,{ok:true})
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
            env={**os.environ, 'STRIPE_RESTRICTED_KEY': 'fixture-only', 'STRIPE_WEBHOOK_SECRET': 'fixture-signing-secret',
                'MACMINT_ENTITLEMENT_SIGNING_KEY': signing_key})
        try:
            for _ in range(100):
                try:
                    if call('/api/health')[0] == 200: break
                except Exception: time.sleep(.1)
            status, auth = call('/api/collections/users/auth-with-password', dict(identity='fixture@example.invalid', password='fixture-test-password-123'))
            assert status == 200, (status, auth)
            token = auth['token']
            second_status, second_auth = call('/api/collections/users/auth-with-password', dict(identity='second@example.invalid', password='fixture-test-password-123'))
            assert second_status == 200, (second_status, second_auth)
            second_token = second_auth['token']
            assert call('/__test/auth-config')[1] == dict(subject='Operator verification',resetSeconds=3600)
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                results = list(pool.map(lambda _: call('/__test/reserve', {}), range(16)))
            assert sum(status == 200 for status, _ in results) == 8, results
            assert sum(status == 429 for status, _ in results) == 8, results
            print('PASS: 16 concurrent AI reservations, exactly 8 approvals')
            device_ids = [str(uuid.uuid4()) for _ in range(8)]
            def timed_activation(identifier):
                started = time.perf_counter(); result = call('/api/macmint/devices/activate', dict(device_id=identifier, name='Fixture'), token)
                return result, (time.perf_counter() - started) * 1000
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                timed_results = list(pool.map(timed_activation, device_ids))
            results = [result for result, _ in timed_results]
            cold_ms = next(ms for (status, _), ms in timed_results if status == 200)
            assert sum(status == 200 for status, _ in results) == 1, results
            assert sum(status == 409 for status, _ in results) == 7, results
            active = next(value['device']['device_id'] for status, value in results if status == 200)
            user_id = auth['record']['id']
            def timed(path, account_token=token):
                started = time.perf_counter(); result = call(path, token=account_token)
                return result, (time.perf_counter() - started) * 1000
            activated = next(value for status, value in results if status == 200)
            assert verified_claims(activated['entitlement_assertion'])['device_id'] == active
            (status, plain), baseline_ms = timed('/api/macmint/me')
            assert status == 200 and 'entitlement_assertion' not in plain, plain
            (status, me), cached_ms = timed('/api/macmint/me?device_id=' + active)
            assert status == 200 and me['entitlement_assertion'] == activated['entitlement_assertion'], me
            claims = verified_claims(me['entitlement_assertion'])
            assert claims['v'] == 1 and claims['kid'] == 'mm-it-1' and claims['user_id'] == user_id and claims['device_id'] == active, claims
            assert claims['active'] is True and claims['plan'] == 'pro' and claims['expires_at'] is None, claims
            assert claims['offline_until'] - claims['issued_at'] == 14 * 86400 and abs(claims['issued_at'] - time.time()) < 30, claims
            assert call('/__test/client-config', dict(min_version='0.0.1', offline_grace_days=7))[0] == 200
            (status, regraced), warm_ms = timed('/api/macmint/me?device_id=' + active)
            seven = verified_claims(regraced['entitlement_assertion'])
            assert seven['offline_until'] - seven['issued_at'] == 7 * 86400, seven
            assert 'entitlement_assertion' not in call('/api/macmint/me?device_id=' + str(uuid.uuid4()), token=token)[1]
            assert 'entitlement_assertion' not in call('/api/macmint/me?device_id=' + active, token=second_token)[1]
            print(f'PASS: activation and /me return a verifiable device-bound assertion (Goja Ed25519 latency: /me without assertion {baseline_ms:.0f} ms, '
                f'activation with first signature incl. key derivation {cold_ms:.0f} ms, /me re-signed with cached key {warm_ms:.0f} ms, /me reusing assertion {cached_ms:.0f} ms)')
            assert call('/api/macmint/devices/deactivate', dict(device_id=active), token)[0] == 200
            assert 'entitlement_assertion' not in call('/api/macmint/me?device_id=' + active, token=token)[1]
            assert call('/api/macmint/devices/activate', dict(device_id=active), token)[0] == 409
            status, refused = call('/api/macmint/devices/activate', dict(device_id=active, reactivate=False), token)
            assert status == 409 and refused['error'] == 'device_deactivated' and 'entitlement_assertion' not in refused, refused
            status, reactivated = call('/api/macmint/devices/activate', dict(device_id=active, reactivate=True), token)
            assert status == 200 and verified_claims(reactivated['entitlement_assertion'])['device_id'] == active, reactivated
            print('PASS: concurrent activation respects last slot; removed device gets no assertion and requires explicit reactivation')
            request_key = str(uuid.uuid4())
            saved_offer = dict(amount_minor=1900, currency='usd', plan='pro', duration_days=365, max_devices=3)
            def checkout_status(key, account_token=token):
                return call('/api/macmint/checkout/status?request_key=' + key, token=account_token)
            def checkout_payload(state, can_start_new=False):
                return dict(state=state, can_start_new=can_start_new, offer=saved_offer)
            assert checkout_status(request_key) == (200, dict(state='not_found', can_start_new=False))
            assert checkout_status('-' * 36)[0] == 400
            assert call('/api/macmint/checkout/status?request_key=' + request_key)[0] == 401
            assert call('/api/macmint/admin/commerce/readiness', token=token)[0] in (401, 403)
            assert call('/api/macmint/checkout', dict(request_key='-' * 36), token)[0] == 400
            # Racing distinct identities share one unresolved account purchase.
            keys = [request_key] + [str(uuid.uuid4()) for _ in range(7)]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                attempts = list(pool.map(lambda key: call('/api/macmint/checkout', dict(request_key=key), token), keys))
            assert sum(status == 200 for status, _ in attempts) == 1, attempts
            winner = next(i for i, (status, _) in enumerate(attempts) if status == 200)
            request_key = keys[winner]; status, checkout = attempts[winner]
            for result_status, body in attempts:
                if result_status != 200:
                    assert result_status == 409 and body['error'] == 'checkout_in_progress' and body['request_key'] == request_key, attempts
            assert len(sessions) == 1
            print('PASS: 8 concurrent distinct request keys produce one checkout and 7 owner-only resumptions')
            session = next(iter(sessions.values()))
            before_poll = len(provider_requests)
            assert checkout_status(request_key) == (200, checkout_payload('pending'))
            assert checkout_status(request_key, second_token) == (200, dict(state='not_found', can_start_new=False))
            assert len(provider_requests) == before_poll, 'Status polling must not call Stripe'
            with urllib.request.urlopen(urllib.request.Request(origin + '/api/macmint/checkout/status?request_key=' + request_key, headers={'Authorization': token})) as status_response:
                assert status_response.headers.get('Cache-Control') == 'no-store'
            print('PASS: checkout status is authenticated, owner-scoped, database-only, and rejects malformed request IDs')
            assert call('/api/macmint/checkout', dict(request_key=request_key), token) == (200, checkout)
            session['status'] = 'expired'
            status, expired = call('/api/macmint/checkout', dict(request_key=request_key), token)
            assert status == 409 and expired['error'] == 'checkout_expired', (status, expired)
            session['status'] = 'complete'
            status, complete = call('/api/macmint/checkout', dict(request_key=request_key), token)
            assert status == 409 and complete['error'] == 'checkout_complete', (status, complete)
            assert len(sessions) == 1
            print('PASS: checkout reuses its saved session; expired and completed retries never create another session')
            def webhook(event_type, valid=True, target=None):
                target = target or session
                event = dict(type=event_type, data=dict(object=dict(id=target['id'], metadata=target['metadata'])))
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
            assert db.execute('SELECT state FROM checkout_orders WHERE session_id=?', (session['id'],)).fetchone()[0] == 'fulfilled'
            assert checkout_status(request_key) == (200, checkout_payload('fulfilled'))
            assert call('/api/macmint/checkout', dict(request_key=request_key), token)[1]['error'] == 'checkout_complete'
            assert db.execute("SELECT id FROM _collections WHERE name='licenses'").fetchone()[0] == 'legacy_licenses'
            # A second owner may independently use the same request UUID. Their open
            # order must not block a different user's next verified purchase attempt.
            assert call('/api/macmint/checkout', dict(request_key=request_key), second_token)[0] == 200
            assert checkout_status(request_key, second_token) == (200, checkout_payload('pending'))
            assert checkout_status(request_key) == (200, checkout_payload('fulfilled'))
            # A signed terminal event is only a trigger; authoritative current state wins.
            expired_key = str(uuid.uuid4())
            assert call('/api/macmint/checkout', dict(request_key=expired_key), token)[0] == 200
            expired_session = list(sessions.values())[-1]
            assert webhook('checkout.session.expired', target=expired_session)[0] == 200
            assert checkout_status(expired_key) == (200, checkout_payload('pending'))
            expired_session['status'] = 'expired'
            for _ in range(2): assert webhook('checkout.session.expired', target=expired_session)[0] == 200
            assert checkout_status(expired_key) == (200, checkout_payload('expired', True))
            assert call('/api/macmint/checkout', dict(request_key=expired_key), token)[1]['error'] == 'checkout_expired'
            failed_key = str(uuid.uuid4())
            assert call('/api/macmint/checkout', dict(request_key=failed_key), token)[0] == 200
            failed_session = list(sessions.values())[-1]; failed_session['status'] = 'complete'
            for _ in range(2): assert webhook('checkout.session.async_payment_failed', target=failed_session)[0] == 200
            assert checkout_status(failed_key) == (200, checkout_payload('failed', True))
            # If a later notification arrives after Stripe reports paid, it fulfills once.
            failed_session['payment_status'] = 'paid'
            for event_type in ['checkout.session.expired', 'checkout.session.async_payment_failed', 'checkout.session.async_payment_succeeded']:
                assert webhook(event_type, target=failed_session)[0] == 200
            assert checkout_status(failed_key) == (200, checkout_payload('fulfilled'))
            assert db.execute('SELECT COUNT(*) FROM licenses').fetchone()[0] == 2
            assert db.execute('SELECT customer_email, web_origin FROM checkout_orders WHERE request_key=? AND user=?', (request_key, auth['record']['id'])).fetchone() == ('fixture@example.invalid', 'https://staging.macmint.test')
            print('PASS: expired/failed webhook verification, duplicate/out-of-order delivery, and immutable email migration')
            redeem_code = 'MINTREDEEMFIXTURE1'
            assert call('/__test/license', dict(code=redeem_code))[0] == 200
            status, redeemed = call('/api/macmint/redeem', dict(code=redeem_code, device_id=active), token)
            assert status == 200 and redeemed['redeemed'] is True, redeemed
            redeemed_claims = verified_claims(redeemed['entitlement_assertion'])
            assert redeemed_claims['device_id'] == active and redeemed_claims['active'] is True, redeemed_claims
            assert redeemed_claims['expires_at'] == (int(time.mktime(time.strptime(redeemed['entitlement']['expires_at'][:19], '%Y-%m-%dT%H:%M:%S'))) - time.timezone
                if redeemed['entitlement']['expires_at'] else None), (redeemed_claims, redeemed['entitlement'])
            assert 'entitlement_assertion' not in call('/api/macmint/redeem', dict(code=redeem_code), token)[1]
            print('PASS: redemption returns a device-bound assertion only when this device is named')
            db.close()
            print('PASS: real raw-body HMAC, unpaid -> paid fulfillment, 8 duplicate concurrent webhooks grant one license')
            print('PASS: migrations preserve pre-existing collection IDs and reapply cleanly')
        finally:
            process.terminate(); process.wait(timeout=5)
fixture.shutdown()
