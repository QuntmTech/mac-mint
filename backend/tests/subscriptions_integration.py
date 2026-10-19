"""Recurring billing against disposable PocketBase and a local Stripe protocol server.
No real credentials, charges, emails or production database changes.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import concurrent.futures
import hashlib
import hmac
import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]
PB = Path(os.environ.get('POCKETBASE_BIN', ROOT / '.build/pocketbase-bin/pocketbase')).resolve()
sessions, subscriptions, invoices, requests = {}, {}, {}, []
portal_valid = True
provider_fails = False
now = int(time.time())
price = dict(id='price_recurring', active=True, type='recurring', unit_amount=1900, currency='usd', livemode=False,
             recurring=dict(interval='month', interval_count=1, usage_type='licensed'))


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def respond(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        requests.append(('GET', self.path, {}))
        if provider_fails: return self.respond(dict(error='fixture upstream unavailable'), 503)
        path = urllib.parse.urlparse(self.path)
        if path.path.startswith('/v1/prices/'): return self.respond(price)
        if path.path == '/v1/checkout/sessions':
            identifier = urllib.parse.parse_qs(path.query)['subscription'][0]
            return self.respond(dict(data=[value for value in sessions.values() if value.get('subscription') == identifier], has_more=False))
        if path.path.startswith('/v1/billing_portal/configurations/'):
            return self.respond(dict(id='bpc_fixture', active=True, livemode=False, features=dict(
                subscription_cancel=dict(enabled=True, mode='at_period_end'), payment_method_update=dict(enabled=True),
                subscription_update=dict(enabled=not portal_valid))))
        identifier = path.path.rsplit('/', 1)[-1]
        source = sessions if '/checkout/sessions/' in path.path else subscriptions if '/subscriptions/' in path.path else invoices
        self.respond(source[identifier])

    def do_POST(self):
        fields = {key: value[0] for key, value in urllib.parse.parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode()).items()}
        requests.append(('POST', self.path, fields))
        if self.path == '/v1/billing_portal/sessions':
            return self.respond(dict(customer=fields['customer'], url='https://billing.stripe.com/p/session/fixture'))
        assert self.path == '/v1/checkout/sessions'
        assert fields['mode'] == 'subscription' and 'payment_method_types' not in fields
        order = fields['metadata[macmint_order]']
        assert fields['subscription_data[metadata][macmint_order]'] == order
        identifier = 'cs_' + order
        sessions.setdefault(identifier, dict(id=identifier, metadata=dict(macmint_order=order), client_reference_id=fields['client_reference_id'],
            mode='subscription', payment_status='unpaid', status='open', expires_at=now + 3600,
            currency='usd', amount_total=0 if fields.get('subscription_data[trial_period_days]') else price['unit_amount'], livemode=False, customer=fields.get('customer', 'cus_' + order),
            line_items=dict(has_more=False, data=[dict(quantity=1, price=price)]), url='https://checkout.stripe.com/c/pay/' + identifier))
        self.respond(sessions[identifier])


provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
threading.Thread(target=provider.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix='pb-subscriptions-', dir=ROOT / '.build') as raw:
    folder = Path(raw)
    shutil.copytree(ROOT / 'backend/pocketbase/pb_hooks', folder / 'hooks')
    shutil.copytree(ROOT / 'backend/pocketbase/pb_migrations', folder / 'migrations')
    client = folder / 'hooks/macmint_payments_lib.js'
    client.write_text(client.read_text().replace('https://api.stripe.com/v1/', f'http://127.0.0.1:{provider.server_port}/v1/'))
    (folder / 'migrations/1792109600_fixture.js').write_text('''migrate(app=>{
      for(const email of ["buyer@example.invalid","other@example.invalid"]){const u=new Record(app.findCollectionByNameOrId("users"));u.set("email",email);u.setPassword("fixture-password-123");u.set("verified",true);app.save(u)}
      const config=new Record(app.findCollectionByNameOrId("app_config"));config.set("key","commerce");config.set("value",{
        enabled:true,livemode:false,price_id:"price_recurring",amount_minor:1900,currency:"usd",plan:"pro",duration_days:0,max_devices:3,
        billing_mode:"subscription",billing_interval:"month",billing_interval_count:1,portal_configuration_id:"bpc_fixture",web_origin:"https://staging.macmint.test"});app.save(config)
      const release=new Record(app.findCollectionByNameOrId("app_releases"));for(const [k,v] of Object.entries({version:"0.0.1",channel:"stable",sha256:"a".repeat(64),download_url:"https://example.invalid/fixture.dmg",validated:true,notarized:true,published:true}))release.set(k,v);app.save(release)
    },()=>{})''')
    (folder / 'hooks/fixture.pb.js').write_text('''routerAdd("POST","/__test/settings",e=>{
      const data=e.requestInfo().body,lib=require(`${__hooks}/macmint_lib.js`)
      if(data.enabled!==undefined){const r=e.app.findFirstRecordByFilter("app_config","key='commerce'");const cfg=JSON.parse(toString(r.get("value")));cfg.enabled=data.enabled;r.set("value",cfg);e.app.save(r)}
      if(data.annualTrial){const r=e.app.findFirstRecordByFilter("app_config","key='commerce'");const cfg=JSON.parse(toString(r.get("value")));Object.assign(cfg,{amount_minor:3999,billing_interval:"year",trial_days:3});r.set("value",cfg);e.app.save(r)}
      if(data.expireTrial){const u=e.app.findFirstRecordByFilter("users","email='other@example.invalid'");const r=e.app.findFirstRecordByFilter("billing_subscriptions","user={:u} && terminal=false",{u:u.id});r.set("trial_through","2020-01-01T00:00:00Z");e.app.save(r)}
      const user=e.app.findFirstRecordByFilter("users","email='buyer@example.invalid'")
      if(data.expire){const r=e.app.findFirstRecordByFilter("billing_subscriptions","user={:u} && terminal=false",{u:user.id});r.set("paid_through","2020-01-01T00:00:00Z");e.app.save(r)}
      if(data.lifetime){const r=lib.ensureEntitlement(e.app,user.id);r.set("plan","pro");r.set("status","active");r.set("expires_at","");r.set("max_devices",5);e.app.save(r)}
      return e.json(200,{ok:true})
    })''')
    base = [str(PB), '--dir', str(folder / 'data'), '--hooksDir', str(folder / 'hooks'), '--migrationsDir', str(folder / 'migrations')]
    for _ in range(2):
        result = subprocess.run(base + ['migrate', 'up'], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]

    def call(path, data=None, token=None, headers=None):
        content = data if isinstance(data, bytes) else json.dumps(data).encode() if data is not None else None
        outgoing = {'Content-Type': 'application/json', **(headers or {})}
        if token: outgoing['Authorization'] = token
        request = urllib.request.Request(f'http://127.0.0.1:{port}' + path, data=content, headers=outgoing)
        try:
            with urllib.request.urlopen(request, timeout=30) as response: return response.status, json.load(response)
        except urllib.error.HTTPError as error: return error.code, json.load(error)

    def webhook(kind, identifier):
        raw = json.dumps(dict(type=kind, data=dict(object=dict(id=identifier)))).encode()
        # Checkout events carry the provider's original order metadata; invoice events intentionally don't.
        if kind.startswith('checkout.'):
            raw = json.dumps(dict(type=kind, data=dict(object=dict(id=identifier, metadata=sessions[identifier]['metadata'])))).encode()
        stamp = str(int(time.time()))
        signature = hmac.new(b'fixture-signing-secret', stamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
        return call('/api/macmint/stripe/webhook', raw, headers={'Stripe-Signature': f't={stamp},v1={signature}'})

    def complete(session):
        session.update(status='complete', subscription='sub_' + session['id'][3:])
        sub_id, invoice_id = session['subscription'], 'in_' + session['id'][3:]
        subscriptions[sub_id] = dict(id=sub_id, customer=session['customer'], status='incomplete', livemode=False,
            cancel_at_period_end=False, latest_invoice=invoice_id, items=dict(has_more=False,
                data=[dict(quantity=1, price=price, current_period_start=now, current_period_end=now + 30 * 86400)]))
        invoices[invoice_id] = dict(id=invoice_id, status='open', customer=session['customer'], currency='usd', livemode=False,
            parent=dict(type='subscription_details', subscription_details=dict(subscription=sub_id)),
            lines=dict(has_more=False, data=[dict(quantity=1, pricing=dict(price_details=dict(price='price_recurring')), period=dict(start=now, end=now + 30 * 86400))]))
        return subscriptions[sub_id], invoices[invoice_id]

    with (folder / 'server.log').open('w') as log:
        process = subprocess.Popen(base + ['serve', '--http', f'127.0.0.1:{port}'], stdout=log, stderr=log,
            env={**os.environ, 'STRIPE_RESTRICTED_KEY': 'fixture-only', 'STRIPE_WEBHOOK_SECRET': 'fixture-signing-secret'})
        try:
            for _ in range(100):
                try:
                    if call('/api/health')[0] == 200: break
                except OSError: time.sleep(.1)
            token = call('/api/collections/users/auth-with-password', dict(identity='buyer@example.invalid', password='fixture-password-123'))[1]['token']
            other = call('/api/collections/users/auth-with-password', dict(identity='other@example.invalid', password='fixture-password-123'))[1]['token']
            def me():
                status, value = call('/api/macmint/me', token=token)
                assert status == 200, (status, value, (folder / 'server.log').read_text())
                return value
            assert call('/api/macmint/checkout/config')[1]['billing_mode'] == 'subscription'
            assert call('/api/collections/billing_subscriptions/records', token=token)[0] == 403
            assert call('/api/macmint/billing/portal', {})[0] == 401
            keys = [str(uuid.uuid4()) for _ in range(8)]
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                attempts = list(pool.map(lambda key: call('/api/macmint/checkout', dict(request_key=key), token), keys))
            assert sum(status == 200 for status, _ in attempts) == 1, attempts
            assert sum(status == 409 for status, _ in attempts) == 7, attempts
            session = next(iter(sessions.values()))
            key = next(key for key, (status, _) in zip(keys, attempts) if status == 200)
            sub, invoice = complete(session)
            assert webhook('checkout.session.completed', session['id'])[0] == 200
            assert me()['entitlement']['active'] is False
            invoice['status'] = 'paid'; sub['status'] = 'active'; session['payment_status'] = 'paid'
            provider_fails = True
            assert webhook('invoice.paid', invoice['id'])[0] == 503
            assert me()['entitlement']['active'] is False
            provider_fails = False
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results = list(pool.map(lambda _: webhook('invoice.paid', invoice['id']), range(8)))
            assert all(status == 200 for status, _ in results), (results, (folder / 'server.log').read_text())
            assert me()['entitlement']['active'] is True
            initial_expiry = me()['entitlement']['expires_at']
            assert call('/api/macmint/billing/portal', {}, other)[0] == 503
            assert call('/api/macmint/billing/portal', dict(customer='cus_foreign'), token)[0] == 200
            assert requests[-1][2]['customer'] == session['customer']
            print('PASS: concurrent subscription checkout, unpaid initial state, provider failure/retry and duplicate invoice delivery')

            invoice['status'] = 'open'; sub['status'] = 'past_due'
            sub['items']['data'][0]['current_period_end'] += 30 * 86400
            invoice['lines']['data'][0]['period']['end'] += 30 * 86400
            assert webhook('invoice.payment_failed', invoice['id'])[0] == 200
            assert me()['entitlement']['expires_at'] == initial_expiry
            call('/__test/settings', dict(expire=True))
            assert me()['entitlement']['active'] is False
            assert call('/api/macmint/checkout', dict(request_key=str(uuid.uuid4())), token)[1]['error'] == 'plan_exists'
            invoice['status'] = 'paid'; sub['status'] = 'active'
            assert webhook('invoice.paid', invoice['id'])[0] == 200
            assert me()['entitlement']['active'] is True
            assert me()['entitlement']['expires_at'] != initial_expiry
            sub['cancel_at_period_end'] = True
            assert webhook('customer.subscription.updated', sub['id'])[0] == 200
            assert me()['billing']['subscription']['cancel_at_period_end'] is True
            call('/__test/settings', dict(enabled=False))
            assert call('/api/macmint/billing/portal', {}, token)[0] == 200
            print('PASS: failed renewal never extends access; payment recovery, period-end cancellation and portal survive checkout kill switch')

            sub['status'] = 'canceled'
            assert webhook('customer.subscription.deleted', sub['id'])[0] == 200
            assert me()['entitlement']['active'] is False
            status = call('/api/macmint/checkout/status?request_key=' + key, token=token)[1]
            assert status['state'] == 'fulfilled' and status['can_start_new'] is True
            call('/__test/settings', dict(enabled=True))
            portal_valid = False
            count = len(sessions)
            assert call('/api/macmint/checkout', dict(request_key=str(uuid.uuid4())), token)[0] == 503
            assert len(sessions) == count
            portal_valid = True
            # Resume the same durable unbound order after its portal prerequisite is fixed.
            pending_key = next(value['request_key'] for status, value in [call('/api/macmint/checkout', dict(request_key=str(uuid.uuid4())), token)] if status == 409)
            assert call('/api/macmint/checkout', dict(request_key=pending_key), token)[0] == 200
            new_session = list(sessions.values())[-1]
            assert new_session['customer'] == session['customer']
            new_sub, new_invoice = complete(new_session)
            new_sub['status'] = 'active'; new_invoice['status'] = 'paid'
            assert webhook('invoice.paid', new_invoice['id'])[0] == 200
            call('/__test/settings', dict(lifetime=True))
            new_sub['status'] = 'canceled'
            assert webhook('customer.subscription.deleted', new_sub['id'])[0] == 200
            assert me()['entitlement']['active'] is True and me()['entitlement']['expires_at'] is None
            assert me()['entitlement']['max_devices'] == 5
            print('PASS: terminal cancellation, safe resubscription, customer reuse, portal preflight and independent lifetime access')

            # The approved public offer: annual USD 39.99, three-day trial, three Macs.
            call('/__test/settings', dict(annualTrial=True))
            price.update(unit_amount=3999, recurring=dict(interval='year', interval_count=1, usage_type='licensed'))
            assert call('/api/macmint/checkout/config', token=other)[1]['trial_days'] == 3
            assert call('/api/macmint/checkout', dict(request_key=str(uuid.uuid4())), other)[0] == 200
            trial_session = list(sessions.values())[-1]
            fields = next(fields for method, path, fields in reversed(requests) if method == 'POST' and path == '/v1/checkout/sessions')
            assert fields['subscription_data[trial_period_days]'] == '3' and fields['payment_method_collection'] == 'always'
            trial_session['payment_status'] = 'no_payment_required'
            trial_sub, trial_invoice = complete(trial_session)
            trial_sub.update(status='trialing', trial_start=now, trial_end=now + 3 * 86400)
            trial_sub['items']['data'][0]['current_period_end'] = now + 3 * 86400
            trial_invoice['status'] = 'paid'
            trial_invoice['lines']['data'][0]['period']['end'] = now + 3 * 86400
            assert webhook('checkout.session.completed', trial_session['id'])[0] == 200
            trial_account = call('/api/macmint/me', token=other)[1]
            assert trial_account['entitlement']['active'] is True and trial_account['entitlement']['source'] == 'subscription_trial'
            assert trial_account['billing']['subscription']['amount_minor'] == 3999
            assert not trial_account['billing']['subscription']['paid_through']
            assert call('/api/macmint/checkout/config', token=other)[1]['trial_days'] == 0
            call('/__test/settings', dict(expireTrial=True))
            assert call('/api/macmint/me', token=other)[1]['entitlement']['active'] is False
            trial_sub['status'] = 'past_due'; trial_invoice['status'] = 'open'
            assert webhook('invoice.payment_failed', trial_invoice['id'])[0] == 200
            assert call('/api/macmint/me', token=other)[1]['entitlement']['active'] is False
            trial_sub['status'] = 'active'; trial_invoice['status'] = 'paid'
            trial_sub['items']['data'][0]['current_period_end'] = now + 368 * 86400
            trial_invoice['lines']['data'][0]['period'].update(start=now + 3 * 86400, end=now + 368 * 86400)
            assert webhook('invoice.paid', trial_invoice['id'])[0] == 200
            assert call('/api/macmint/me', token=other)[1]['entitlement']['source'] == 'subscription'
            trial_sub['status'] = 'canceled'
            assert webhook('customer.subscription.deleted', trial_sub['id'])[0] == 200
            assert call('/api/macmint/checkout', dict(request_key=str(uuid.uuid4())), other)[0] == 200
            retry_fields = next(fields for method, path, fields in reversed(requests) if method == 'POST' and path == '/v1/checkout/sessions')
            assert 'subscription_data[trial_period_days]' not in retry_fields
            print('PASS: approved annual offer, bounded three-day trial, expiry, failed first charge, paid conversion and one-trial-only resubscription')
            print('PASS: new billing migration reapplies safely and client billing records remain locked')
        finally:
            process.terminate()
            process.wait(timeout=5)
provider.shutdown()
