"""Plan page → Payment Link → webhook → /welcome claim → /me, against disposable PocketBase,
a local Stripe protocol server and a local GitHub releases fixture.
No real credentials, charges, emails or production database changes.
"""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import hmac
import itertools
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

ROOT = Path(__file__).resolve().parents[2]
PB = Path(os.environ.get('POCKETBASE_BIN', ROOT / '.build/pocketbase-bin/pocketbase')).resolve()
now = int(time.time())
sessions, subscriptions, invoices, requests = {}, {}, {}, []
TIERS = [dict(tier='mac1', devices=1, payment_link_id='plink_one', url='https://buy.stripe.com/test_one111', price_id='price_one', amount_minor=3995, currency='usd', trial_days=7),
         dict(tier='mac2', devices=2, payment_link_id='plink_two', url='https://buy.stripe.com/test_two222', price_id='price_two', amount_minor=5995, currency='usd', trial_days=7),
         dict(tier='mac5', devices=5, payment_link_id='plink_five', url='https://buy.stripe.com/test_five55', price_id='price_five', amount_minor=9995, currency='usd', trial_days=7)]
CONFIG = dict(enabled=True, livemode=False, web_origin='https://staging.macmint.test', billing_mode='subscription', price_id='price_one',
              amount_minor=3995, currency='usd', plan='pro', duration_days=0, billing_interval='year', billing_interval_count=1, trial_days=7,
              max_devices=1, portal_configuration_id='bpc_fixture', tiers=TIERS)
github_release = dict(tag_name='v1.4.0', draft=False, prerelease=False, published_at='2026-10-19T00:00:00Z', assets=[
    dict(name='MacMint.dmg', size=23456789, digest='sha256:' + 'e' * 64,
         browser_download_url='https://github.com/QuntmTech/mac-mint/releases/download/v1.4.0/MacMint.dmg')])


def price_for(tier):
    return dict(id=tier['price_id'], active=True, type='recurring', unit_amount=tier['amount_minor'], currency='usd', livemode=False,
                recurring=dict(interval='year', interval_count=1, usage_type='licensed'))


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def respond(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        requests.append(self.path)
        path = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(path.query)
        if path.path == '/repos/QuntmTech/mac-mint/releases/latest': return self.respond(github_release)
        if path.path == '/v1/checkout/sessions':
            found = [value for value in sessions.values() if value.get('subscription') == query['subscription'][0]]
            return self.respond(dict(data=found, has_more=False))
        if path.path.startswith('/v1/billing_portal/configurations/'):
            return self.respond(dict(id='bpc_fixture', active=True, livemode=False, features=dict(
                subscription_cancel=dict(enabled=True, mode='at_period_end'), payment_method_update=dict(enabled=True), subscription_update=dict(enabled=False))))
        identifier = path.path.rsplit('/', 1)[-1]
        source = sessions if '/checkout/sessions/' in path.path else subscriptions if '/subscriptions/' in path.path else invoices
        if identifier not in source: return self.respond(dict(error=dict(type='invalid_request_error')), 404)
        self.respond(source[identifier])


def purchase(name, tier, email, reference='', complete=True, **overrides):
    """A Payment Link session as Stripe would create it, with its trialing subscription."""
    session_id = 'cs_test_' + name
    sub_id, invoice_id, customer = 'sub_' + name, 'in_' + name, 'cus_' + name
    session = dict(id=session_id, object='checkout.session', payment_link=tier['payment_link_id'], mode='subscription',
                   status='complete' if complete else 'open', payment_status='no_payment_required' if complete else 'unpaid', livemode=False,
                   currency='usd', amount_total=0, client_reference_id=reference or None, metadata={},
                   customer=customer if complete else None, subscription=sub_id if complete else None,
                   customer_details=dict(email=email), line_items=dict(has_more=False, data=[dict(quantity=1, price=price_for(tier))]))
    session.update(overrides)
    sessions[session_id] = session
    subscriptions[sub_id] = dict(id=sub_id, customer=customer, status='trialing', livemode=False, cancel_at_period_end=False,
                                 trial_start=now, trial_end=now + 7 * 86400, latest_invoice=invoice_id, items=dict(has_more=False,
                                 data=[dict(quantity=1, price=price_for(tier), current_period_start=now, current_period_end=now + 7 * 86400)]))
    invoices[invoice_id] = dict(id=invoice_id, status='paid', customer=customer, currency='usd', livemode=False,
                                parent=dict(type='subscription_details', subscription_details=dict(subscription=sub_id)),
                                lines=dict(has_more=False, data=[dict(quantity=1, pricing=dict(price_details=dict(price=tier['price_id'])),
                                                                      period=dict(start=now, end=now + 7 * 86400))]))
    return session


provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
threading.Thread(target=provider.serve_forever, daemon=True).start()
fixture_origin = f'http://127.0.0.1:{provider.server_port}'
(ROOT / '.build').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='pb-funnel-', dir=ROOT / '.build') as raw:
    folder = Path(raw)
    shutil.copytree(ROOT / 'backend/pocketbase/pb_hooks', folder / 'hooks')
    shutil.copytree(ROOT / 'backend/pocketbase/pb_migrations', folder / 'migrations')
    # Redirect ONLY the copied test clients. Production code calls Stripe and GitHub over HTTPS.
    # The funnel's late-webhook timers are shortened for the fixture (10 s -> 1 s, 60 s -> 2 s).
    for name, old, new in [('macmint_payments_lib.js', 'https://api.stripe.com/v1/', fixture_origin + '/v1/'),
                           ('macmint_download.js', 'https://api.github.com/', fixture_origin + '/'),
                           ('macmint_funnel.js', 'LATE_MILLIS = 10000, RETRY_MILLIS = 60000', 'LATE_MILLIS = 1000, RETRY_MILLIS = 2000')]:
        target = folder / 'hooks' / name
        text = target.read_text()
        assert old in text
        target.write_text(text.replace(old, new))
    (folder / 'migrations/1792109800_fixture.js').write_text('''migrate(app=>{
      const su=new Record(app.findCollectionByNameOrId("_superusers"));su.set("email","operator@example.invalid");su.setPassword("operator-password-123");app.save(su)
      for(const email of ["Owner@Example.invalid","veteran@example.invalid"]){const u=new Record(app.findCollectionByNameOrId("users"));u.set("email",email);u.setPassword("fixture-password-123");u.set("verified",true);app.save(u)}
      const config=new Record(app.findCollectionByNameOrId("app_config"));config.set("key","commerce");config.set("value",''' + json.dumps(CONFIG) + ''');app.save(config)
      // A ZIP feed entry satisfies the checkout release gate but is not a DMG for /download.
      const release=new Record(app.findCollectionByNameOrId("app_releases"));for(const [k,v] of Object.entries({version:"0.0.1",channel:"stable",sha256:"a".repeat(64),download_url:"https://github.com/QuntmTech/mac-mint/releases/download/v0.0.1/MacMint.zip",validated:true,notarized:true,published:true,published_at:"2026-01-01 00:00:00.000Z"}))release.set(k,v);app.save(release)
      const settings=app.settings();settings.trustedProxy.headers=["X-Test-Client-IP"];settings.rateLimits.enabled=true;app.save(settings)
    },()=>{})''')
    (folder / 'hooks/fixture.pb.js').write_text('''routerAdd("POST","/__test/state",e=>{
      const data=e.requestInfo().body,lib=require(`${__hooks}/macmint_lib.js`)
      if(data.trialUsed){const u=e.app.findFirstRecordByFilter("users","email={:e}",{e:data.trialUsed});const r=lib.ensureEntitlement(e.app,u.id);r.set("subscription_trial_used",true);e.app.save(r)}
      if(data.verify){const u=e.app.findFirstRecordByFilter("users","email={:e}",{e:data.verify});u.set("verified",true);e.app.save(u)}
      if(data.expire){const r=e.app.findFirstRecordByFilter("purchase_claims","session_id={:s}",{s:data.expire});r.set("expires_at","2020-01-01 00:00:00.000Z");e.app.save(r)}
      if(data.dmg){const r=new Record(e.app.findCollectionByNameOrId("app_releases"));for(const [k,v] of Object.entries({version:"1.5.0",build:15,channel:"stable",min_os:"14.0",size_bytes:34567890,sha256:"f".repeat(64),download_url:"https://github.com/QuntmTech/mac-mint/releases/download/v1.5.0/MacMint.dmg",validated:true,notarized:true,published:true,published_at:"2026-10-20 00:00:00.000Z"}))r.set(k,v);e.app.save(r)}
      return e.json(200,{ok:true})
    })''')
    base = [str(PB), '--dir', str(folder / 'data'), '--hooksDir', str(folder / 'hooks'), '--migrationsDir', str(folder / 'migrations')]
    for _ in range(2):
        result = subprocess.run(base + ['migrate', 'up'], capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    client_numbers = itertools.count(1)

    def call(path, data=None, token=None, headers=None, ip=None, method=None):
        n = next(client_numbers)
        ip = ip or f'10.{(n >> 16) & 255}.{(n >> 8) & 255}.{n & 255}'
        content = data if isinstance(data, bytes) else json.dumps(data).encode() if data is not None else None
        outgoing = {'Content-Type': 'application/json', 'X-Test-Client-IP': ip, **(headers or {})}
        if token: outgoing['Authorization'] = token
        request = urllib.request.Request(f'http://127.0.0.1:{port}' + path, data=content, headers=outgoing, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, json.loads(raw) if raw else {}, dict(response.headers)
        except urllib.error.HTTPError as error:
            raw = error.read()
            return error.code, json.loads(raw) if raw else {}, dict(error.headers)

    def api(path, data=None, token=None, **kwargs):
        status, value, _ = call(path, data, token, **kwargs)
        return status, value

    def webhook(kind, obj):
        raw = json.dumps(dict(type=kind, data=dict(object=obj))).encode()
        stamp = str(int(time.time()))
        signature = hmac.new(b'fixture-signing-secret', stamp.encode() + b'.' + raw, hashlib.sha256).hexdigest()
        return api('/api/macmint/stripe/webhook', raw, headers={'Stripe-Signature': f't={stamp},v1={signature}'})

    def session_event(session):
        return dict(id=session['id'], object='checkout.session', payment_link=session['payment_link'], metadata={})

    def status_of(session_id, ip=None):
        return api('/api/macmint/purchase/status', dict(session_id=session_id), ip=ip)

    def stripe_reads(session_id):
        return sum(f'/v1/checkout/sessions/{session_id}' in path for path in requests)

    def late_status(session_id):
        """Poll like /welcome until the late-webhook window lets the server ask Stripe."""
        for _ in range(40):
            status, value = status_of(session_id)
            if value.get('state') != 'processing': return status, value
            time.sleep(.25)
        return status, value

    with (folder / 'server.log').open('w') as log:
        process = subprocess.Popen(base + ['serve', '--http', f'127.0.0.1:{port}'], stdout=log, stderr=log,
                                   env={**os.environ, 'STRIPE_RESTRICTED_KEY': 'fixture-only', 'STRIPE_WEBHOOK_SECRET': 'fixture-signing-secret'})
        try:
            for _ in range(100):
                try:
                    if api('/api/health')[0] == 200: break
                except OSError: time.sleep(.1)
            admin = api('/api/collections/_superusers/auth-with-password', dict(identity='operator@example.invalid', password='operator-password-123'))[1]['token']

            def users_named(email):
                found = api('/api/collections/users/records?filter=' + urllib.parse.quote(f"email:lower='{email.lower()}'"), token=admin)[1]
                return found['items']

            def me(token):
                status, value = api('/api/macmint/me', token=token)
                assert status == 200, (status, value, (folder / 'server.log').read_text()[-3000:])
                return value

            status, plans = api('/api/macmint/plans')
            assert status == 200 and plans['enabled'] is True, plans
            assert [(t['devices'], t['amount_minor'], t['trial_days'], t['billing_interval']) for t in plans['tiers']] == [(1, 3995, 7, 'year'), (2, 5995, 7, 'year'), (5, 9995, 7, 'year')]
            assert 'plink_' not in json.dumps(plans) and 'price_' not in json.dumps(plans) and 'buy.stripe.com' not in json.dumps(plans)
            assert api('/api/collections/purchase_claims/records')[0] in (401, 403)
            print('PASS: plan tiers come from server configuration without exposing link or Price bindings')

            # 1. Guest start → webhooks → claim → trialing Pro with the tier's device allowance.
            status, started = api('/api/macmint/trial/start', dict(email='New.Buyer@Example.invalid', tier='mac2'))
            assert status == 200, started
            link = urllib.parse.urlparse(started['url'])
            params = urllib.parse.parse_qs(link.query)
            assert (link.scheme, link.netloc, link.path) == ('https', 'buy.stripe.com', '/test_two222')
            assert params['prefilled_email'] == ['new.buyer@example.invalid'] and params['client_reference_id'][0].startswith('mmt_')
            assert api('/api/macmint/trial/start', dict(email='x@example.invalid', tier='mac2', amount_minor=1))[0] == 200, 'Client amounts are ignored'
            assert api('/api/macmint/trial/start', dict(email='x@example.invalid', tier='plink_two'))[0] == 400
            open_session = purchase('openone1', TIERS[1], 'new.buyer@example.invalid', complete=False)
            assert status_of(open_session['id'])[1]['state'] == 'processing'
            assert stripe_reads(open_session['id']) == 0, 'A fresh unknown session waits for the webhook before asking Stripe'
            assert api('/api/macmint/purchase/claim', dict(session_id=open_session['id'], password='a-strong-password-1'))[0] == 202
            session = purchase('newbuyer1', TIERS[1], 'new.buyer@example.invalid', reference=params['client_reference_id'][0])
            for kind, obj in [('customer.subscription.created', dict(id=session['subscription'])), ('checkout.session.completed', session_event(session)),
                              ('checkout.session.completed', session_event(session)), ('invoice.paid', dict(id='in_newbuyer1'))]:
                assert webhook(kind, obj)[0] == 200, kind
            status, claim_state, headers = call('/api/macmint/purchase/status', dict(session_id=session['id']))
            assert status == 200 and claim_state['state'] == 'ready' and claim_state['email'] == 'new.buyer@example.invalid', claim_state
            assert claim_state['plan']['devices'] == 2 and claim_state['plan']['amount_minor'] == 5995
            assert headers.get('Referrer-Policy') == 'no-referrer' and 'no-store' in headers.get('Cache-Control', '')
            assert api('/api/macmint/purchase/claim', dict(session_id=session['id'], password='short'))[0] == 400
            status, claimed = api('/api/macmint/purchase/claim', dict(session_id=session['id'], password='a-strong-password-1'))
            assert status == 200 and claimed['meta']['state'] == 'claimed', (status, claimed, (folder / 'server.log').read_text()[-3000:])
            assert claimed['record']['email'] == 'new.buyer@example.invalid' and claimed['record']['verified'] is False, 'Stripe never proves the mailbox'
            account = me(claimed['token'])
            assert account['entitlement']['active'] is True and account['entitlement']['source'] == 'subscription_trial', account
            assert account['entitlement']['max_devices'] == 2
            assert account['billing']['subscription']['status'] == 'trialing' and account['billing']['subscription']['amount_minor'] == 5995
            assert account['billing']['subscription']['trial_through'] and account['billing']['subscription']['max_devices'] == 2
            for n in range(2):
                assert api('/api/macmint/devices/activate', dict(device_id=f'FUNNEL-MAC-DEVICE-{n}'), claimed['token'])[0] == 200
            assert api('/api/macmint/devices/activate', dict(device_id='FUNNEL-MAC-DEVICE-9'), claimed['token'])[0] == 409
            signed_in = api('/api/collections/users/auth-with-password', dict(identity='new.buyer@example.invalid', password='a-strong-password-1'))
            assert signed_in[0] == 200
            print('PASS: guest start, signed webhooks and single claim create a trialing two-Mac account and sign it in')

            # 2. Replays never create a second account or rebind the purchase.
            replay = api('/api/macmint/purchase/claim', dict(session_id=session['id'], password='another-password-2'))
            assert replay[0] == 409 and replay[1]['error'] == 'already_claimed', replay
            assert status_of(session['id'])[1]['state'] == 'claimed'
            assert len(users_named('new.buyer@example.invalid')) == 1
            assert api('/api/collections/users/auth-with-password', dict(identity='new.buyer@example.invalid', password='another-password-2'))[0] == 400
            print('PASS: a replayed claim is refused and cannot reset the password')

            # 3. An existing account for the billing email is linked, never duplicated or taken over.
            owner_token = api('/api/collections/users/auth-with-password', dict(identity='Owner@Example.invalid', password='fixture-password-123'))[1]['token']
            assert api('/api/macmint/trial/start', dict(email='owner@example.invalid', tier='mac1'))[0] == 200
            owner_session = purchase('owner0001', TIERS[0], 'OWNER@example.invalid')
            assert webhook('checkout.session.completed', session_event(owner_session))[0] == 200
            assert status_of(owner_session['id'])[1]['state'] == 'existing_account'
            linked = api('/api/macmint/purchase/claim', dict(session_id=owner_session['id'], password='attacker-password-1'))
            assert linked[0] == 200 and linked[1] == dict(state='existing_account', email='owner@example.invalid') and 'token' not in linked[1], linked
            assert len(users_named('owner@example.invalid')) == 1
            assert api('/api/collections/users/auth-with-password', dict(identity='Owner@Example.invalid', password='attacker-password-1'))[0] == 400
            owner = me(owner_token)
            assert owner['entitlement']['active'] is True and owner['entitlement']['max_devices'] == 1 and owner['entitlement']['source'] == 'subscription_trial'
            print('PASS: an existing-email purchase links to that account without a duplicate, password change or sign-in')

            # 4. Trial abuse: used trials and active plans are refused up front; a slipped-through trial is held.
            for email in ['new.buyer@example.invalid', 'OWNER@example.invalid']:
                refused = api('/api/macmint/trial/start', dict(email=email, tier='mac5'))
                assert refused[0] == 409 and refused[1]['error'] == 'sign_in_required', refused
            assert api('/__test/state', dict(trialUsed='veteran@example.invalid'))[0] == 200
            refused = api('/api/macmint/trial/start', dict(email='veteran@example.invalid', tier='mac1'))
            assert refused[0] == 409 and refused[1] == dict(error='sign_in_required', message=refused[1]['message']), refused
            veteran_session = purchase('veteran1', TIERS[0], 'veteran@example.invalid')
            assert webhook('checkout.session.completed', session_event(veteran_session))[0] == 200
            veteran_token = api('/api/collections/users/auth-with-password', dict(identity='veteran@example.invalid', password='fixture-password-123'))[1]['token']
            veteran = me(veteran_token)
            assert veteran['entitlement']['active'] is False and veteran['billing']['subscription']['access_held'] is True, veteran
            assert veteran['billing']['subscription']['hold_reason'] == 'duplicate_trial'
            claim_row = api('/api/collections/purchase_claims/records?filter=' + urllib.parse.quote(f"session_id='{veteran_session['id']}'"), token=admin)[1]['items'][0]
            assert claim_row['attention'] == 'duplicate_trial' and claim_row['state'] == 'linked'
            released = api('/api/macmint/admin/billing/release-hold', dict(subscription=veteran_session['subscription'], reason='operator reviewed'), admin)
            assert released[0] == 200 and released[1]['previous_hold'] == 'duplicate_trial' and me(veteran_token)['entitlement']['active'] is True
            print('PASS: used trials and active plans are refused before redirect; a slipped-through trial binds held for operator review')

            # 5. Webhook after redirect, a different sign-in email, and an occupied email.
            billing_session = purchase('billing01', TIERS[2], 'billing@example.invalid')
            assert status_of(billing_session['id'])[1]['state'] == 'processing' and stripe_reads(billing_session['id']) == 0
            ready = late_status(billing_session['id'])
            assert ready[1]['state'] == 'ready' and ready[1]['email'] == 'billing@example.invalid', ready
            assert stripe_reads(billing_session['id']) == 1, 'Exactly one authoritative read once the webhook is late'
            taken = api('/api/macmint/purchase/claim', dict(session_id=billing_session['id'], password='a-strong-password-3', email='owner@example.invalid'))
            assert taken[0] == 409 and taken[1]['error'] == 'email_taken', taken
            assert api('/api/macmint/purchase/claim', dict(session_id=billing_session['id'], password='a-strong-password-3', email='not an email'))[0] == 400
            status, chosen = api('/api/macmint/purchase/claim', dict(session_id=billing_session['id'], password='a-strong-password-3', email='SignIn@Example.invalid'))
            assert status == 200 and chosen['record']['email'] == 'signin@example.invalid' and chosen['record']['verified'] is False, chosen
            chosen_account = me(chosen['token'])
            assert chosen_account['entitlement']['active'] is True and chosen_account['entitlement']['max_devices'] == 5
            order = api('/api/collections/checkout_orders/records?filter=' + urllib.parse.quote(f"session_id='{billing_session['id']}'"), token=admin)[1]['items'][0]
            assert order['customer_email'] == 'billing@example.invalid' and order['payment_link_id'] == 'plink_five' and order['max_devices'] == 5
            assert webhook('checkout.session.completed', session_event(billing_session))[0] == 200, 'A late webhook is idempotent'
            assert len(users_named('signin@example.invalid')) == 1 and not users_named('billing@example.invalid')
            refused = api('/api/macmint/trial/start', dict(email='billing@example.invalid', tier='mac1'))
            assert refused[0] == 409 and refused[1]['error'] == 'sign_in_required', 'The billing email has used its trial'
            assert api('/api/macmint/billing/refresh', {}, chosen['token'])[1]['refreshed'] == 1
            print('PASS: the redirect can arrive before the webhook; a different sign-in email keeps Stripe\'s billing email')

            # 6. Unknown links, changed terms, expiry and operator recovery.
            foreign = dict(purchase('foreign01', TIERS[0], 'foreign@example.invalid'), payment_link='plink_not_macmint')
            sessions[foreign['id']] = foreign
            assert webhook('checkout.session.completed', session_event(foreign))[0] == 200
            assert late_status(foreign['id'])[1]['state'] == 'not_found'
            reads = stripe_reads(foreign['id'])
            assert [status_of(foreign['id'])[1]['state'] for _ in range(3)] == ['not_found'] * 3 and stripe_reads(foreign['id']) == reads, 'Misses are cached'
            tampered = purchase('tamper01', TIERS[0], 'tamper@example.invalid')
            tampered['line_items']['data'][0]['price'] = price_for(TIERS[0]) | dict(unit_amount=1)
            assert webhook('checkout.session.completed', session_event(tampered))[0] == 200
            assert status_of(tampered['id'])[1]['state'] == 'attention'
            assert api('/api/macmint/purchase/claim', dict(session_id=tampered['id'], password='a-strong-password-4'))[1]['error'] == 'attention'
            assert not users_named('tamper@example.invalid')
            late = purchase('late0001', TIERS[0], 'late@example.invalid')
            assert webhook('checkout.session.completed', session_event(late))[0] == 200
            assert api('/__test/state', dict(expire=late['id']))[0] == 200
            expired = api('/api/macmint/purchase/claim', dict(session_id=late['id'], password='a-strong-password-5'))
            assert expired[0] == 410 and not users_named('late@example.invalid'), expired
            assert api('/api/macmint/admin/purchase/link', dict(session=late['id'], user=account['user']['id']))[0] in (401, 403)
            relinked = api('/api/macmint/admin/purchase/link', dict(session=late['id'], user=chosen['record']['id']), admin)
            assert relinked[0] == 200 and relinked[1]['state'] == 'attention', 'An account with an ongoing subscription cannot bind a second one'
            print('PASS: unknown links are ignored, changed terms and expired claims grant nothing, and recovery respects one subscription')

            # 7a. An attacker who pre-registers the buyer's email (unverified) never receives the purchase.
            signup = dict(email='Victim@Example.invalid', password='attacker-password-1', passwordConfirm='attacker-password-1')
            assert api('/api/collections/users/records', signup)[0] == 200
            variant = dict(signup, email='VICTIM@example.invalid')
            assert api('/api/collections/users/records', variant)[0] == 400, 'Case-variant duplicate signups are refused'
            assert [u['email'] for u in users_named('victim@example.invalid')] == ['victim@example.invalid']
            attacker = api('/api/collections/users/auth-with-password', dict(identity='VICTIM@example.invalid', password='attacker-password-1'))
            assert attacker[0] == 200, 'Sign-in matches the stored address case-insensitively'
            attacker_token = attacker[1]['token']
            victim_session = purchase('victim01', TIERS[0], 'victim@example.invalid')
            assert webhook('checkout.session.completed', session_event(victim_session))[0] == 200
            assert me(attacker_token)['entitlement']['active'] is False and me(attacker_token)['billing']['subscription'] is None
            ready = status_of(victim_session['id'])[1]
            assert ready['state'] == 'ready' and ready['owner_unverified'] is True, ready
            stolen = api('/api/macmint/purchase/attach', dict(session_id=victim_session['id']), attacker_token)
            assert stolen[0] == 403 and stolen[1]['error'] == 'verify_email', stolen
            blocked = api('/api/macmint/purchase/claim', dict(session_id=victim_session['id'], password='victim-password-1'))
            assert blocked[0] == 409 and blocked[1]['error'] == 'unverified_owner', blocked
            status, victim = api('/api/macmint/purchase/claim', dict(session_id=victim_session['id'], password='victim-password-1', email='victim.real@example.invalid'))
            assert status == 200 and me(victim['token'])['entitlement']['active'] is True, victim
            assert me(attacker_token)['entitlement']['active'] is False
            # A verified owner of the billing email can attach explicitly; another account cannot.
            assert api('/api/collections/users/records', dict(email='later@example.invalid', password='later-password-1', passwordConfirm='later-password-1'))[0] == 200
            later_session = purchase('later001', TIERS[0], 'later@example.invalid')
            assert webhook('checkout.session.completed', session_event(later_session))[0] == 200
            later_token = api('/api/collections/users/auth-with-password', dict(identity='later@example.invalid', password='later-password-1'))[1]['token']
            assert api('/api/macmint/purchase/attach', dict(session_id=later_session['id']), later_token)[1]['error'] == 'verify_email'
            assert api('/__test/state', dict(verify='later@example.invalid'))[0] == 200
            assert api('/api/macmint/purchase/attach', dict(session_id=later_session['id']), owner_token)[1]['error'] == 'email_mismatch'
            later_token = api('/api/collections/users/auth-with-password', dict(identity='later@example.invalid', password='later-password-1'))[1]['token']
            attached = api('/api/macmint/purchase/attach', dict(session_id=later_session['id']), later_token)
            assert attached[0] == 200 and attached[1]['state'] == 'linked' and me(later_token)['entitlement']['active'] is True, attached
            assert api('/api/macmint/purchase/attach', dict(session_id=later_session['id']), later_token)[0] == 409
            print('PASS: purchases attach only to verified owners; an unverified squatter gets nothing and case-variant signups are refused')

            # 7. Download: GitHub fallback until a validated DMG feed entry exists.
            status, fallback = api('/api/macmint/download')
            assert status == 200 and fallback['source'] == 'github' and fallback['url'] == 'https://github.com/QuntmTech/mac-mint/releases/download/v1.4.0/MacMint.dmg', fallback
            assert fallback['notarized'] is False and fallback['size_bytes'] == 23456789 and fallback['version'] == '1.4.0'
            assert api('/__test/state', dict(dmg=True))[0] == 200
            feed = api('/api/macmint/download')[1]
            assert feed['source'] == 'feed' and feed['notarized'] is True and feed['version'] == '1.5.0' and feed['sha256'] == 'f' * 64, feed
            assert sum('/releases/latest' in path for path in requests) == 1, 'The GitHub answer is cached'
            print('PASS: /download prefers the validated DMG feed and otherwise links only the project\'s GitHub DMG')

            # 8. Rate limits on the public funnel routes, per client.
            starts = [api('/api/macmint/trial/start', dict(email='burst@example.invalid', tier='mac1'), ip='198.51.100.20')[0] for _ in range(11)]
            assert starts == [200] * 10 + [429], starts
            assert api('/api/macmint/trial/start', dict(email='burst@example.invalid', tier='mac1'), ip='198.51.100.21')[0] == 200
            polls = [status_of('cs_test_unknownsession', ip='198.51.100.22')[0] for _ in range(61)]
            assert stripe_reads('cs_test_unknownsession') <= 1
            assert polls[-1] == 429 and polls.count(429) == 1, polls
            print('PASS: trial start and claim polling are rate limited per client')
            print('PASS: funnel migration reapplies safely and purchase claims stay private')
        finally:
            process.terminate()
            process.wait(timeout=5)
provider.shutdown()
