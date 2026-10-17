"""Disposable PocketBase integration checks. No production account, credentials or network calls.
Set POCKETBASE_BIN to PocketBase 0.40.5. Stripe responses below are local protocol fixtures.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import concurrent.futures, hashlib, hmac, itertools, json, os, shutil, socket, sqlite3, subprocess, tempfile, threading, time, urllib.request, urllib.error, urllib.parse, uuid

root = Path(__file__).resolve().parents[2]
pocketbase = Path(os.environ.get('POCKETBASE_BIN', root / '.build/pocketbase-bin/pocketbase')).resolve()
assert pocketbase.exists(), 'Set POCKETBASE_BIN to the pinned PocketBase executable'
(root / '.build').mkdir(exist_ok=True)
sessions = {}
charges = {}
disputes = {}
provider_requests = []

class StripeFixture(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def respond(self, body):
        data = json.dumps(body).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        provider_requests.append(("GET", self.path))
        if self.path.startswith('/v1/prices/'):
            return self.respond(dict(id='price_fixture', active=True, type='one_time', unit_amount=1900, currency='usd', livemode=False))
        path, _, query = self.path.partition('?')
        if path.startswith('/v1/charges/'): return self.respond(charges[path.rsplit('/', 1)[-1]])
        if path.startswith('/v1/disputes/'): return self.respond(disputes[path.rsplit('/', 1)[-1]])
        if path == '/v1/checkout/sessions':
            intent = urllib.parse.parse_qs(query).get('payment_intent', [''])[0]
            return self.respond(dict(object='list', has_more=False, data=[v for v in sessions.values() if v.get('payment_intent') == intent][:1]))
        self.respond(sessions[path.rsplit('/', 1)[-1]])
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
      const su=new Record(app.findCollectionByNameOrId("_superusers"));su.set("email","operator@example.invalid");su.setPassword("operator-test-password-123");app.save(su)
      // Fixture proxy header: each test client supplies its own address, like a trusted reverse proxy.
      const settings=app.settings();settings.trustedProxy.headers=["X-Test-Client-IP"];app.save(settings)
      for(const [key,value] of [["ai",{enabled:true}],["commerce",{enabled:true,price_id:"price_fixture",amount_minor:1900,currency:"usd",plan:"pro",duration_days:365,max_devices:3,livemode:false,web_origin:"https://staging.macmint.test"}]]){
        const c=new Record(app.findCollectionByNameOrId("app_config"));c.set("key",key);c.set("value",value);app.save(c)
      }
      const release=new Record(app.findCollectionByNameOrId("app_releases"));release.set("version","0.0.1");release.set("channel","stable");release.set("sha256","a".repeat(64));release.set("download_url","https://github.com/QuntmTech/mac-mint/releases/download/v0.0.1/MacMint.zip");release.set("validated",true);release.set("notarized",true);release.set("published",true);app.save(release)
    },()=>{})''')
    (folder / 'hooks/test.pb.js').write_text('''routerAdd("POST","/__test/reserve",e=>{
      const ai=require(`${__hooks}/macmint_ai_lib.js`),user=e.app.findFirstRecordByFilter("users","email='fixture@example.invalid'")
      try{return e.json(200,{id:ai.reserve(e.app,user.id,"review","claude-opus-5-5",100,100)})}
      catch(err){return e.json(err.status||500,{error:err.code||String(err)})}
    })
    routerAdd("GET","/__test/rate-limits",e=>{
      const limits=e.app.settings().rateLimits
      return e.json(200,{enabled:limits.enabled,labels:limits.rules.map(r=>r.label)})
    })
    routerAdd("POST","/__test/release",e=>{
      const r=new Record(e.app.findCollectionByNameOrId("app_releases"));r.set("version","0.0."+e.requestInfo().body.build);r.set("channel","stable")
      r.set("sha256","b".repeat(64));r.set("download_url",e.requestInfo().body.url);r.set("validated",true);r.set("notarized",true);r.set("published",true)
      try{e.app.save(r);return e.json(200,{saved:true})}catch(err){return e.json(400,{saved:false})}
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
    client_numbers = itertools.count(1)
    def call(path, data=None, token=None, headers=None, ip=None):
        # Distinct simulated clients unless a test pins one address to exercise its limit.
        n = next(client_numbers)
        ip = ip or f'10.{(n >> 16) & 255}.{(n >> 8) & 255}.{n & 255}'
        content = data if isinstance(data, bytes) else (json.dumps(data).encode() if data is not None else None)
        request_headers = {'Content-Type': 'application/json', 'X-Test-Client-IP': ip, **(headers or {})}
        if token: request_headers['Authorization'] = token
        request = urllib.request.Request(origin + path, data=content, headers=request_headers)
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raw = response.read(); return response.status, json.loads(raw) if raw else {}
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
            second_status, second_auth = call('/api/collections/users/auth-with-password', dict(identity='second@example.invalid', password='fixture-test-password-123'))
            assert second_status == 200, (second_status, second_auth)
            second_token = second_auth['token']
            assert call('/__test/auth-config')[1] == dict(subject='Operator verification',resetSeconds=3600)
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                results = list(pool.map(lambda _: call('/__test/reserve', {}), range(16)))
            assert sum(status == 200 for status, _ in results) == 8, results
            assert sum(status == 429 for status, _ in results) == 8, results
            print('PASS: 16 concurrent AI reservations, exactly 8 approvals')
            limits = call('/__test/rate-limits')[1]
            assert limits['enabled'] is True, limits
            assert {'/api/macmint/redeem', '/api/macmint/checkout', '*:auth', 'users:create', 'site_events:create', '/api/macmint/stripe/webhook', '/api/'} <= set(limits['labels'])
            bogus = dict(code='MINT-AAAA-BBBB-CCCC-DDDD')
            redeems = [call('/api/macmint/redeem', bogus, token, ip='198.51.100.7')[0] for _ in range(11)]
            assert redeems == [404] * 10 + [429], redeems
            assert call('/api/macmint/redeem', bogus, token, ip='198.51.100.70')[0] == 404
            wrong = dict(identity='fixture@example.invalid', password='wrong-password-000')
            right = dict(identity='fixture@example.invalid', password='fixture-test-password-123')
            sign_ins = [call('/api/collections/users/auth-with-password', wrong, ip='198.51.100.8')[0] for _ in range(10)]
            assert sign_ins == [400] * 10, sign_ins
            assert call('/api/collections/users/auth-with-password', right, ip='198.51.100.8')[0] == 429
            assert call('/api/collections/users/auth-with-password', right, ip='198.51.100.80')[0] == 200
            deliveries = [call('/api/macmint/stripe/webhook', b'{}', headers={'Stripe-Signature': 't=1,v1=' + '0' * 64}, ip='198.51.100.9')[0] for _ in range(30)]
            assert deliveries == [400] * 30, deliveries
            print('PASS: per-client 429 after redeem and sign-in bursts behind a trusted proxy header; other clients and webhooks unaffected')
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
            with urllib.request.urlopen(urllib.request.Request(origin + '/api/macmint/checkout/status?request_key=' + request_key, headers={'Authorization': token, 'X-Test-Client-IP': '10.255.0.1'})) as status_response:
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
            session['payment_status'] = 'paid'; session['payment_intent'] = 'pi_test_' + session['metadata']['macmint_order']
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
            failed_session['payment_status'] = 'paid'; failed_session['payment_intent'] = 'pi_test_' + failed_session['metadata']['macmint_order']
            for event_type in ['checkout.session.expired', 'checkout.session.async_payment_failed', 'checkout.session.async_payment_succeeded']:
                assert webhook(event_type, target=failed_session)[0] == 200
            assert checkout_status(failed_key) == (200, checkout_payload('fulfilled'))
            assert db.execute('SELECT COUNT(*) FROM licenses').fetchone()[0] == 2
            assert db.execute('SELECT customer_email, web_origin FROM checkout_orders WHERE request_key=? AND user=?', (request_key, auth['record']['id'])).fetchone() == ('fixture@example.invalid', 'https://staging.macmint.test')
            print('PASS: expired/failed webhook verification, duplicate/out-of-order delivery, and immutable email migration')
            status, operator = call('/api/collections/_superusers/auth-with-password', dict(identity='operator@example.invalid', password='operator-test-password-123'))
            assert status == 200, operator
            admin = operator['token']
            def signed(event, valid=True):
                raw = json.dumps(event).encode(); timestamp = str(int(time.time()))
                signature = hmac.new(b'fixture-signing-secret', timestamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
                return call('/api/macmint/stripe/webhook', raw, headers={'Stripe-Signature': f't={timestamp},v1={signature if valid else "0" * 64}'})
            def reversal(event_type, object_id, valid=True):
                return signed(dict(type=event_type, data=dict(object=dict(id=object_id, object='charge' if object_id.startswith('ch_') else 'dispute'))), valid)
            def active(account_token): return call('/api/macmint/me', token=account_token)[1]['entitlement']['active']
            def order_row(session_id): return db.execute('SELECT id, state, attention, refunded_minor, payment_intent FROM checkout_orders WHERE session_id=?', (session_id,)).fetchone()
            def license_status(session_id): return db.execute('SELECT status FROM licenses WHERE order_ref=?', (session_id,)).fetchone()[0]
            second_id = second_auth['record']['id']
            second_session = next(v for v in sessions.values() if v['client_reference_id'] == second_id)
            second_session.update(status='complete', payment_status='paid', payment_intent='pi_test_second')
            assert not active(second_token)
            assert webhook('checkout.session.completed', target=second_session)[0] == 200
            assert active(second_token) and order_row(second_session['id'])[4] == 'pi_test_second'
            charges['ch_test_second'] = dict(id='ch_test_second', object='charge', payment_intent='pi_test_second', amount=1900, amount_refunded=1900, refunded=True, livemode=False, currency='usd')
            assert reversal('charge.refunded', 'ch_test_second', valid=False)[0] == 400
            assert active(second_token)
            assert reversal('charge.refunded', 'ch_test_second')[0] == 200
            assert not active(second_token)
            assert order_row(second_session['id'])[1:4] == ('refunded', '', 1900)
            assert license_status(second_session['id']) == 'revoked'
            license_count = db.execute('SELECT COUNT(*) FROM licenses').fetchone()[0]
            for _ in range(2): assert reversal('charge.refunded', 'ch_test_second')[0] == 200
            assert webhook('checkout.session.completed', target=second_session)[0] == 200
            assert not active(second_token) and order_row(second_session['id'])[1] == 'refunded'
            assert db.execute('SELECT COUNT(*) FROM licenses').fetchone()[0] == license_count
            assert checkout_status(request_key, second_token) == (200, dict(state='refunded', can_start_new=True, offer=saved_offer))
            assert call('/api/macmint/checkout', dict(request_key=request_key), second_token)[1]['error'] == 'checkout_expired'
            print('PASS: signed full refund revokes the license and access in one transaction; replays and late success events stay revoked')
            charges['ch_test_partial'] = dict(id='ch_test_partial', object='charge', payment_intent=session['payment_intent'], amount=1900, amount_refunded=400, refunded=False, livemode=False, currency='usd')
            for _ in range(2): assert reversal('charge.refunded', 'ch_test_partial')[0] == 200
            assert order_row(session['id'])[1:4] == ('fulfilled', 'partial_refund', 400)
            assert active(token) and license_status(session['id']) == 'redeemed'
            print('PASS: partial refund flags the order for operator review without revoking access')
            disputes['dp_test_failed'] = dict(id='dp_test_failed', object='dispute', charge='ch_test_failed', payment_intent=failed_session['payment_intent'], livemode=False, status='needs_response')
            assert reversal('charge.dispute.created', 'dp_test_failed')[0] == 200
            assert order_row(failed_session['id'])[1] == 'disputed' and license_status(failed_session['id']) == 'revoked'
            assert active(token), 'the remaining purchase keeps its access'
            charges['ch_test_other'] = dict(id='ch_test_other', object='charge', payment_intent='pi_not_macmint', amount=100, amount_refunded=100, refunded=True, livemode=False)
            assert reversal('charge.refunded', 'ch_test_other')[0] == 200
            print('PASS: dispute revokes only the disputed purchase; unrelated charges are acknowledged and ignored')
            first_order = order_row(session['id'])[0]
            assert call('/api/macmint/admin/licenses/revoke', dict(order=first_order), token)[0] in (401, 403)
            status, revoked = call('/api/macmint/admin/licenses/revoke', dict(order=first_order, reason='fixture'), admin)
            assert status == 200 and revoked['already_revoked'] is False and revoked['entitlement']['active'] is False, revoked
            assert not active(token)
            assert call('/api/macmint/admin/licenses/revoke', dict(order=first_order), admin)[1]['already_revoked'] is True
            assert call('/api/macmint/admin/licenses/revoke', dict(license='missingmissing1'), admin)[0] == 404
            assert call('/api/macmint/admin/licenses/revoke', {}, admin)[0] == 400
            print('PASS: superuser license revocation cascades to the entitlement and is idempotent')
            def open_session(account_id):
                return next(v for v in sessions.values() if v['client_reference_id'] == account_id and v['status'] == 'open')
            stuck_key = str(uuid.uuid4())
            assert call('/api/macmint/checkout', dict(request_key=stuck_key), second_token)[0] == 200
            stuck = open_session(second_id); stuck_order = order_row(stuck['id'])[0]
            assert call('/api/macmint/admin/checkout/reconcile', dict(order=stuck_order), second_token)[0] in (401, 403)
            status, result = call('/api/macmint/admin/checkout/reconcile', dict(order=stuck_order), admin)
            assert status == 200 and (result['state'], result['changed'], result['session_status']) == ('pending', False, 'open'), result
            stuck['status'] = 'expired'  # Stripe expired it, but the webhook never arrived.
            status, result = call('/api/macmint/admin/checkout/reconcile', dict(order=stuck_order), admin)
            assert status == 200 and (result['state'], result['changed']) == ('expired', True), result
            assert checkout_status(stuck_key, second_token) == (200, checkout_payload('expired', True))
            paid_key = str(uuid.uuid4())
            assert call('/api/macmint/checkout', dict(request_key=paid_key), second_token)[0] == 200
            paid = open_session(second_id); paid.update(status='complete', payment_status='paid', payment_intent='pi_test_reconciled')
            paid_order = order_row(paid['id'])[0]
            assert call('/api/macmint/admin/checkout/reconcile', dict(order=paid_order), admin)[1]['state'] == 'fulfilled'
            assert active(second_token) and order_row(paid['id'])[4] == 'pi_test_reconciled'
            assert call('/api/macmint/admin/checkout/reconcile', dict(order=paid_order), admin)[1]['changed'] is False
            assert call('/api/macmint/admin/checkout/reconcile', dict(order='missingmissing1'), admin)[0] == 404
            print('PASS: superuser reconciliation applies authoritative Stripe expiry and payment without webhooks')
            assert call('/__test/release', dict(build=2, url='https://evil.example/MacMint.zip'))[1] == dict(saved=False)
            assert call('/__test/release', dict(build=3, url='http://github.com/QuntmTech/mac-mint/releases/download/v0.0.3/MacMint.zip'))[1] == dict(saved=False)
            assert call('/__test/release', dict(build=4, url='https://github.com/QuntmTech/mac-mint/releases/download/v0.0.4/MacMint.zip'))[1] == dict(saved=True)
            print('PASS: published feed releases require a first-party HTTPS download URL')
            for n in range(2):
                assert call('/api/collections/site_events/records', dict(event='view', variant='a', visitor=f'visitor-fixture-{n:04d}'))[0] == 200
            old_date, recent_date = '2020-01-01 00:00:00.000Z', time.strftime('%Y-%m-%d %H:%M:%S.000Z', time.gmtime(time.time() - 30 * 86400))
            event_ids = [row[0] for row in db.execute('SELECT id FROM site_events ORDER BY id')]
            db.execute('UPDATE site_events SET created=? WHERE id=?', (old_date, event_ids[0]))
            failure_ids = [row[0] for row in db.execute("SELECT id FROM audit_log WHERE event='redeem_failed' ORDER BY id")]
            assert len(failure_ids) >= 3, failure_ids
            db.execute('UPDATE audit_log SET created=? WHERE id=?', (old_date, failure_ids[0]))
            db.execute('UPDATE audit_log SET created=? WHERE id=?', (recent_date, failure_ids[1]))
            db.execute("UPDATE audit_log SET created=? WHERE event='checkout_fulfilled'", (old_date,))
            db.commit()
            kept_evidence = db.execute("SELECT COUNT(*) FROM audit_log WHERE event != 'redeem_failed'").fetchone()[0]
            assert call('/api/crons/macmint_retention', {}, admin)[0] == 204
            for _ in range(100):
                if not db.execute('SELECT COUNT(*) FROM site_events WHERE id=?', (event_ids[0],)).fetchone()[0]: break
                time.sleep(.05)
            assert [row[0] for row in db.execute('SELECT id FROM site_events ORDER BY id')] == event_ids[1:]
            assert [row[0] for row in db.execute("SELECT id FROM audit_log WHERE event='redeem_failed' ORDER BY id")] == failure_ids[1:]
            assert db.execute("SELECT COUNT(*) FROM audit_log WHERE event != 'redeem_failed'").fetchone()[0] == kept_evidence
            print('PASS: daily retention prunes old site events and failed-redeem audit rows, keeping recent rows and payment evidence')
            db.close()
            print('PASS: real raw-body HMAC, unpaid -> paid fulfillment, 8 duplicate concurrent webhooks grant one license')
            print('PASS: migrations preserve pre-existing collection IDs and reapply cleanly')
        finally:
            process.terminate(); process.wait(timeout=5)
fixture.shutdown()
