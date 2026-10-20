# Stripe subscriptions and purchase setup

The owner-approved offer is **MacMint Pro, Annual**: an auto-renewing yearly subscription with a **7-day free trial**, a card collected up front, and three device tiers. One free trial per person.

| Tier | Macs | Price per year | ≈ per month | Per-Mac saving |
| --- | --- | --- | --- | --- |
| `mac1` | 1 | **US$39.95** | $3.33 | — |
| `mac2` | 2 | **US$59.95** | $5.00 | about 25% |
| `mac5` | 5 | **US$99.95** | $8.33 | 50% |

Visitors buy on the public plan page through **Stripe Payment Links** (one link per tier). Signed-in returning customers can still buy from the account page through the server-created Checkout Session (the top-level offer; no second trial). The intended Stripe business account has not been identified or verified in this session, and no Stripe object was created by this change.

Use `backend/commerce.subscription.example.json` as the template. It deliberately has `enabled: false`, `livemode: false` and blank Price, Payment Link and portal IDs. The legacy `commerce.example.json` remains available for compatible one-time purchases.

## Plan-page funnel (Payment Links)

```text
homepage CTA → /start (choose 1/2/5 Macs, enter email) → POST /api/macmint/trial/start
  → Stripe Payment Link ?prefilled_email=…&client_reference_id=mmt_…
  → card collected, 7-day trial starts → redirect /welcome?session_id={CHECKOUT_SESSION_ID}
  → webhook checkout.session.completed records a private purchase claim
  → /welcome: set a password (or sign in if the email already has an account)
  → /download → install, sign in on the Mac, device activates on the tier's allowance
```

- **Prices are server configuration.** `/start` shows amounts from `GET /api/macmint/plans`, which exposes display terms only (no Price or link IDs). The browser never sends an amount; `trial/start` takes only `{ email, tier }` and returns the configured link URL. [`prefilled_email` and `client_reference_id`](https://docs.stripe.com/payment-links/url-parameters) are Stripe's documented Payment Link URL parameters; the reference is an opaque random value with no authority.
- **The webhook decides.** A completed session is accepted only when its `payment_link` is one of the configured tier links and the retrieved session's mode, livemode, currency, total (zero with a trial), single line item, quantity 1, Price ID, unit amount, yearly interval and licensed usage all match that tier. Payment Links outside the configuration are acknowledged and ignored. A configured link whose terms differ is recorded as `attention = terms_mismatch` and grants nothing.
- **Claims.** Each accepted session creates one private `purchase_claims` row (unique by session). If a **verified** account already exists for the Stripe email (case-insensitive), the purchase is linked to it immediately and `/welcome` asks the buyer to sign in; nothing is created or changed on that account besides the subscription. An **unverified** account for that email is never linked automatically (anyone can register an unverified account under someone else's address): the claim stays pending with `attention = unverified_owner`, the buyer can create their account with a different sign-in email, and the owner of that address can sign in, verify it and add the purchase through `POST /api/macmint/purchase/attach` (authenticated; requires a verified account whose email equals the billing email, plus the session ID). Otherwise `/welcome` lets the holder of the session link create the account **once, within 72 hours**: the claim transition, user creation and order binding share one database transaction, so a replay gets `already_claimed`. The order created from a claim carries the tier's Price, amount, devices (`max_devices`), trial and the payment link, and then reuses the existing subscription lifecycle (sync, trials, renewals, holds, refunds, disputes, portal).
- **Webhook after the redirect.** `/welcome` polls `POST /api/macmint/purchase/status` (session ID in the body, never in a URL) for up to a minute ("Finishing your purchase…"). Only when the webhook is plausibly late (10 seconds after the server first sees that session) does it retrieve the session from Stripe itself, at most once per minute per session, and it applies the same acceptance rule. Misses are cached in a bounded in-memory table (`app.store()`).
- **Sign-in email.** The buyer may choose a different sign-in email on `/welcome`; Stripe's email stays the billing email (`checkout_orders.customer_email`, receipts, portal). An occupied sign-in email is refused (`email_taken`) and the claim stays usable.
- **Verification policy.** Stripe never proves mailbox ownership, so every account created on `/welcome` starts **unverified** and the normal verification email is requested (best effort: it is delivered once SMTP is configured; the claim never waits for it). The funnel does not depend on email delivery: desktop sign-in, device activation, the trial itself, the billing portal and downloads do not require verification. Verification gates only the signed-in account-page checkout (not used by the funnel) and the explicit `attach` route. Account emails are stored lowercase, sign-in matches them case-insensitively, and case-variant duplicate signups are refused.
- **Privacy.** `/start`, `/welcome` and `/download` send `Referrer-Policy: no-referrer` (Apache rule in `web/scripts/deploy.sh`, and a page meta tag); `/welcome` removes `session_id` from the address bar, and the account app loads no third-party scripts.
- **One trial per email.** `trial/start` refuses an email whose account already used a trial (`subscription_trial_used`), has an active plan or ongoing subscription, or whose billing email already has a recorded trial claim, with one generic answer (`sign_in_required`: "This email can't start another free trial. Sign in to continue.") that does not say which case applies, and offers sign-in instead (a returning customer buys without a trial from the account page). **Payment Links cannot hard-enforce this**: someone can reopen a link directly or change the email at Stripe. When a second trial still arrives, the webhook records `attention = duplicate_trial` and binds the subscription with `access_hold = duplicate_trial`, so it grants **no access**; the account shows that support must review it. Decide in Stripe (end the trial now so the first year is charged, or cancel/refund), then release with `POST /api/macmint/admin/billing/release-hold`. If the account already has an ongoing subscription, the claim becomes `attention = duplicate_subscription` and is not bound at all: cancel and refund the duplicate in Stripe.
- **Recovery.** `POST /api/macmint/admin/purchase/link` (superuser) with `{ "session": "cs_…", "user": "<user id>" }` links an expired or unmatched claim to an account after you have checked the purchase in Stripe.

### Create the Stripe objects (test mode first)

In the intended account, in **test mode / a sandbox**:

1. **Product:** `MacMint Pro`.
2. **Three Prices** on it, all **recurring, yearly, licensed (per unit), USD**: 39.95, 59.95, 99.95. No trial on the Price itself.
3. **Three Payment Links**, one per Price:
   - Quantity **1**, "Let customers adjust quantity" **off**.
   - **Subscription free trial: 7 days**.
   - **Collect payment method: always** (card required up front, even for the $0 trial). Missing payment method at trial end: cancel.
   - Promotion codes **off** (a discount changes the total and is recorded as `terms_mismatch`).
   - **After payment:** "Don't show confirmation page" → redirect to `https://macmint.co/welcome?session_id={CHECKOUT_SESSION_ID}` (keep the literal `{CHECKOUT_SESSION_ID}`).
   - Do not use a custom link domain: the server accepts only `https://buy.stripe.com/test_…` links in test mode and `https://buy.stripe.com/…` in live mode.
   - Optional metadata `macmint_tier` = `mac1` / `mac2` / `mac5`.

Or run the helper with a short-lived **test-mode** key that can write Products, Prices and Payment Links (it refuses live keys, prints only IDs/URLs):

```sh
STRIPE_SETUP_KEY=rk_test_… python3 backend/scripts/create-payment-links.py --create-test-links --origin https://staging.macmint.co
```

4. **Customer portal** (Settings → Billing → Customer portal, then create a configuration and copy its `bpc_…`): payment-method updates **on**, invoice history **on**, cancellation **on, at period end**, subscription updates/plan switching **off** (switching tiers is not implemented).
5. **Webhook endpoint** `https://<backend>/api/macmint/stripe/webhook` with the events listed under [Webhooks and deployment](#webhooks-and-deployment), including the subscription and trial events.
6. **Restricted key** (runtime): see [Provider credentials and permissions](#provider-credentials-and-permissions). Payment Links access is not needed at runtime.

### Commerce configuration with tiers

```json
{
  "enabled": true,
  "livemode": false,
  "web_origin": "https://macmint.co",
  "billing_mode": "subscription",
  "price_id": "price_…1Mac",
  "amount_minor": 3995,
  "currency": "usd",
  "plan": "pro",
  "duration_days": 0,
  "billing_interval": "year",
  "billing_interval_count": 1,
  "trial_days": 7,
  "max_devices": 1,
  "portal_configuration_id": "bpc_…",
  "tiers": [
    { "tier": "mac1", "devices": 1, "payment_link_id": "plink_…", "url": "https://buy.stripe.com/test_…", "price_id": "price_…", "amount_minor": 3995, "currency": "usd", "trial_days": 7 },
    { "tier": "mac2", "devices": 2, "payment_link_id": "plink_…", "url": "https://buy.stripe.com/test_…", "price_id": "price_…", "amount_minor": 5995, "currency": "usd", "trial_days": 7 },
    { "tier": "mac5", "devices": 5, "payment_link_id": "plink_…", "url": "https://buy.stripe.com/test_…", "price_id": "price_…", "amount_minor": 9995, "currency": "usd", "trial_days": 7 }
  ]
}
```

The top-level fields are the signed-in account-page offer (returning customers get no trial). `tiers` holds 1–6 entries with distinct `tier`, `devices`, `payment_link_id`, `url` and `price_id`; `trial_days` 0–30; optional `billing_interval` (defaults to the top-level one). An invalid tier blocks the whole offer, and the readiness script reports `payment_link_tiers`. Store the JSON in the private `app_config` record with `key = commerce`.

### Test-mode walkthrough

1. Create the test objects above and load the test config on **staging** (backup, migrations through `1792109700_trial_funnel`, hooks). Keep a validated release record (or expect `/download` to fall back to the latest public GitHub `MacMint.dmg`).
2. `node backend/scripts/check-commerce-readiness.cjs --config backend/commerce.local.json` → `local_prerequisites_complete`.
3. Open `https://staging…/start`, choose 2 Macs, enter a new email, **Start free trial**. Stripe shows $0.00 due today, the 7-day trial and the yearly price. Pay with `4242 4242 4242 4242`.
4. Stripe redirects to `/welcome`. See "Finishing your purchase…" briefly, then your email. Set a password → `/download`. `/account` shows MacMint Pro, trial end, next charge ($59.95 on the trial end date), 2-Mac allowance, Manage billing and Download.
5. Repeat `/start` with the same email → refused with a sign-in link. Buy with an email that already has an account → `/welcome` says to sign in; no second account exists.
6. In the Dashboard, end the trial early or use a test clock: `invoice.paid` → access becomes `subscription` until the paid period end. Cancel in the portal → access remains until period end.
7. Replay `checkout.session.completed` from the Dashboard: nothing changes. Reopen the `/welcome` link: `already_claimed`.

## Architecture and access rules

The app and website never receive provider credentials or card details. Hosted Stripe Checkout creates the subscription, Billing handles renewals, and an authenticated server route creates short-lived Customer Portal sessions for payment details, invoices and cancellation.

Each order freezes its user, email, return origin, Price, amount, cadence, trial eligibility, device allowance and portal configuration before the first provider request. A transaction permits one unresolved checkout per user; retries reuse the original order and idempotency key. Browser return parameters never grant access. Database-only status checks cannot create provider requests or silently replace an uncertain checkout.

`billing_subscriptions` is private. Its access dates are separate from redeemed/one-time licenses. Trial access ends at the verified `trial_end`; an unpaid first invoice never grants an annual period. Renewals replace an absolute verified invoice service-period end rather than appending time. Repeated deliveries cannot double the duration. `past_due` retains only previously paid time; `unpaid`, `paused`, `canceled` and `incomplete_expired` grant no recurring access. Period-end cancellation preserves the paid period. Cancellation never erases an independent valid lifetime license. Explicit account revocation/suspension blocks access.

Subscription and invoice events fetch current Stripe objects. Ownership resolves through the original authoritative Checkout Session, not arbitrary invoice metadata. Concurrent sync generations reject older results, and terminal subscription records cannot reactivate. A verified fulfilled subscription can be repurchased only after it is terminal, with no ongoing subscription or other active access. An unpaid subscription must be recovered through billing rather than duplicated.

Trial eligibility is private and marked used when the completed Checkout binding is recorded, even if a subsequent provider read fails. A canceled/expired trial cannot be restarted on the same account. A returning customer receives a refreshed zero-trial offer. Previously saved orders retain their original terms. The initial zero-value trial invoice is not treated as a paid year.

## Configuration and preflight

```sh
cp backend/commerce.subscription.example.json backend/commerce.local.json
node backend/scripts/check-commerce-readiness.cjs --config backend/commerce.local.json
```

The local JSON is Git-ignored. The command is read-only, never contacts Stripe and never prints secret values. Exit 2 means blocked; exit 0 means only local prerequisites complete. `launch_ready` is always false because real provider, email and installer evidence is separate.

| Field | Recurring offer |
| --- | --- |
| `enabled` | Keep false until staging, provider and installer acceptance pass. |
| `livemode` | false for the isolated sandbox; true only in the intended live account. |
| `web_origin` | Trusted HTTPS website origin, no path/query/credentials/fragment. Defaults to `https://macmint.co`. |
| `billing_mode` | `subscription` (legacy blank/`payment` retains one-time semantics). |
| `price_id` | Active recurring licensed Price from that same Stripe account/mode (the 1-Mac yearly Price for signed-in purchases). |
| `amount_minor`, `currency` | `3995`, `usd`, exactly matching the Price. |
| `plan`, `duration_days` | `pro`, `0`; recurring access comes from verified trial/invoice periods. |
| `billing_interval`, `billing_interval_count` | `year`, `1`. Monthly offers are also supported explicitly. |
| `trial_days` | `7`; zero for ineligible returning accounts; bounded integer 0–30. |
| `max_devices` | `1` for the signed-in offer; accepted range 1–100. |
| `portal_configuration_id` | Explicit active `bpc_…` in the same account/mode. |
| `tiers` | Plan-page Payment Link tiers (see [Commerce configuration with tiers](#commerce-configuration-with-tiers)). Optional; when present every tier must be valid. |

Configure the portal with payment-method updates and cancellation **at period end**. Disable subscription updates: changing to an unknown Price is not implemented by this single-offer integration. The server checks the portal configuration before creating Checkout and before opening the portal. New checkout can be disabled without blocking existing customers from managing/canceling subscriptions.

Only sandbox local development accepts HTTP localhost/127.0.0.1 origins. Real staging uses HTTPS. Currency display follows Stripe charge units, including special zero-decimal conventions. [Stripe currency rules](https://docs.stripe.com/currencies#special-cases).

## Provider credentials and permissions

Use the intended business account and a separate general Stripe sandbox. Store a least-privilege restricted API key and matching signing secret in the host's protected secret store:

- `STRIPE_RESTRICTED_KEY`, or private `app_secrets.name = stripe_restricted_key`.
- `STRIPE_WEBHOOK_SECRET`, or private `app_secrets.name = stripe_webhook_secret`.

The adapter needs Checkout Sessions create/read (read covers plan-page Payment Link sessions) (including line items, and listing by subscription and by payment intent), Prices read, Subscriptions read, Invoices read (including invoice payments, which map a refunded or disputed subscription charge to its invoice), Charges read, Disputes read, Billing Portal Configurations read and Billing Portal Sessions create. Verify actual restricted-key permissions in the isolated sandbox. No publishable key or Stripe.js is required. Never commit values or paste them into chat. [Stripe key handling](https://docs.stripe.com/keys), [sandboxes](https://docs.stripe.com/sandboxes).

PocketBase Goja cannot load Stripe's Node SDK, so the server-only REST adapter pins `2026-08-26.dahlia`. It uses invoice `parent.subscription_details.subscription`, line `pricing.price_details.price`, and subscription-item `current_period_end`. Verify these shapes against the pinned provider API during real sandbox acceptance; protocol fixtures do not certify real credentials or API compatibility.

## Webhooks and deployment

Back up staging first and apply **all** versioned migrations, including `1792109500_subscriptions.js` and `1792109700_trial_funnel.js` (private `purchase_claims`, `checkout_orders.payment_link_id`, and the funnel rate-limit rules). Reapplying migrations is tested; rollback deliberately preserves billing evidence. Deploy hooks/migrations before the website consuming the new response contract. No provider IDs or secrets are accepted from the browser as billing ownership.

Register the backend endpoint `/api/macmint/stripe/webhook` with a matching API version and these events:

```text
checkout.session.completed
checkout.session.async_payment_succeeded
checkout.session.async_payment_failed
checkout.session.expired
charge.refunded
charge.dispute.created
charge.dispute.updated
customer.subscription.created
customer.subscription.updated
customer.subscription.deleted
customer.subscription.paused
customer.subscription.resumed
customer.subscription.trial_will_end
invoice.paid
invoice.payment_failed
invoice.payment_action_required
invoice.finalization_failed
invoice.voided
invoice.marked_uncollectible
```

The handler verifies the raw-body HMAC and timestamp, retrieves authoritative objects, and returns retryable 503 on synchronization failure. Provider calls occur outside database transactions. Original Checkout ownership, mode, customer, Price, amount, currency, quantity, cadence and invoice period are validated before updating access. [Stripe subscription webhooks](https://docs.stripe.com/billing/subscriptions/webhooks), [trial behavior](https://docs.stripe.com/billing/subscriptions/trials).

Refunds and disputes are handled the same way: the signed event is a trigger, and the server retrieves the Charge or Dispute and maps its payment intent.

- **One-time orders** (payment intent recorded at fulfillment; older orders are found through their Checkout Session): one transaction marks the order `refunded` or `disputed`, revokes its license and recomputes the entitlement from the user's remaining licenses. When none remain, the entitlement becomes the plain free state, not `revoked`: `revoked`/`suspended` stay reserved for operator account restrictions, which also block subscriptions. A refunded order permits a new purchase attempt; a disputed one does not.
- **Subscription invoices** (payment intent → InvoicePayment → invoice → subscription, which must be MacMint's and owned by the same customer and mode): one transaction sets `access_hold` (`refunded` or `disputed`) on that `billing_subscriptions` row. Held subscriptions grant no access. Status syncs and renewal invoices keep updating the row but never clear the hold, so a later renewal cannot silently restore access. While the subscription stays ongoing, the account cannot start a second subscription.
- In both cases replays change nothing, a later success or renewal event cannot restore access, and a partial refund only sets `attention = partial_refund` for operator review. A dispute *inquiry* (`warning_needs_response` / `warning_under_review`) withdraws no funds and only sets `attention = dispute_inquiry`. A formal chargeback (`needs_response`, `under_review`, `lost`) revokes or holds, including an inquiry that escalates and arrives as `charge.dispute.updated`. A dispute first seen as won or closed is ignored. Operator-set (`manual`) or restricted entitlements are not rewritten; an `entitlement_review` audit row is written instead. Payments of other products are acknowledged and ignored.

**Operator re-grant.** Nothing restores access automatically, including a won dispute. For a subscription, resolve the case in Stripe (cancel the subscription if access should end), then call `POST /api/macmint/admin/billing/release-hold` with `{ "order": "<order id>" }` or `{ "subscription": "sub_…" }` and a `"reason"`; the release is audited. For a one-time purchase, mint a replacement license (`POST /api/macmint/admin/licenses`) and have the customer redeem it.

Plan-page Payment Link sessions arrive as `checkout.session.completed`; only configured links are processed (see above). `customer.subscription.trial_will_end` re-synchronizes a trial three days before it converts.

Endpoints:

- `GET /api/macmint/plans`: public tier display terms or `enabled:false`. No-store.
- `POST /api/macmint/trial/start`: `{ email, tier }` → the tier's Payment Link URL, or 409 `trial_used` / `active_plan`. Rate limited (10 per 10 minutes per client).
- `POST /api/macmint/purchase/status` (60 per 10 minutes per client) and `POST /api/macmint/purchase/claim` (20 per 10 minutes): `/welcome` status and the single-use account claim. `Referrer-Policy: no-referrer`.
- `POST /api/macmint/purchase/attach`: authenticated, verified owner of the billing email adds a pending purchase (10 per 10 minutes).
- `POST /api/macmint/billing/refresh`: authenticated re-sync of the caller's ongoing subscriptions (used if Stripe was briefly unavailable during a claim).
- `GET /api/macmint/download`: the validated DMG for `/download` (feed first, else the latest non-prerelease GitHub release asset `MacMint.dmg` of QuntmTech/mac-mint, cached 10 minutes; never another host).
- `GET /api/macmint/checkout/config`: public offer or `enabled:false`; authenticated users get their trial eligibility. No-store.
- `GET /api/macmint/checkout/status?request_key=<UUID>`: authenticated owner-only durable state and frozen offer, no provider calls.
- `POST /api/macmint/billing/portal`: authenticated owner-bound customer; ignores browser customer/return URLs. Works while checkout is disabled.
- `GET /api/macmint/admin/commerce/readiness`: superuser-only reason codes, no configuration/secrets/object IDs. Local prerequisites alone are not launch evidence.

Superuser recovery routes:

- `POST /api/macmint/admin/checkout/reconcile` with `{ "order": "<order id>" }`: applies Stripe's authoritative state through the normal code paths. A one-time order's Checkout Session goes paid → fulfilled once, expired → expired. A subscription order with a bound subscription is resynchronized from its subscription and latest invoice (holds survive). An unbound subscription order is bound through its session. Open sessions and complete-but-unpaid asynchronous payments are reported, not changed; resend the missing Stripe event instead. An order that never recorded a session takes `"session": "cs_..."` (found by its `macmint_order` metadata; the session must carry that order ID), or, only after checking Stripe and at least 25 hours after creation, `"confirm_expired_without_session": true`.
- `POST /api/macmint/admin/licenses/revoke` with `{ "license": "<id>" }`, `{ "code": "MINT-…" }`, `{ "order": "<order id>" }` or `{ "subscription": "sub_…" }`, optional `"reason"`: revokes a license and recomputes the owner's entitlement, or places an `operator` hold on a subscription order. Idempotent.
- `POST /api/macmint/admin/billing/release-hold`: the subscription re-grant described above.

An unresolved old order or an uncertain create response outside the safe idempotency window requires operator reconciliation against Stripe. Preserve its row/request identity. Confirm actual provider state before permitting a replacement; never delete the evidence or grant access from a return URL. Refunds and disputes follow the rules above; anything flagged for review needs an operator decision against Stripe.

## Verification before sales

```sh
node --test backend/tests/*.test.cjs
python3 backend/tests/integration.py
python3 backend/tests/service_integration.py
python3 backend/tests/subscriptions_integration.py
python3 backend/tests/funnel_integration.py
(cd web && npm run build && npm run lint)
bash web/scripts/build-homepage.sh
(cd web && npm run test:browser)
```

These use disposable databases, synthetic provider protocol responses and local mail fixtures. Native account/offline/AI lifecycle tests run in macOS CI. They do **not** prove real account permissions, charges, email delivery or downloaded consumer installation.

In the intended isolated Stripe sandbox, prove account verification → annual offer → payment-method collection → three-day trial → explicit Mac activation → first paid invoice → renewal → payment failure/action-required → recovery → period-end cancellation → final expiry. Use test clocks where supported. Include canceling during the trial, duplicate/reordered/retried webhooks, dropped create responses, a changed account email/offer, second-trial refusal, cross-user portal access, device limits and device transfer. Confirm Stripe trial reminders/receipt emails and the short trial's first-charge disclosure. [Customer Portal integration](https://docs.stripe.com/customer-management/integrate-customer-portal).

An additional **real API contract probe** passed on 2026-10-19 in a fresh unclaimed sandbox (expires October 26), using no live account or real card. Its nine checks include the configured annual Price, zero-total trial Checkout, subscription-item/invoice schema, portal response, manually ended trial, first annual invoice paid with `tok_visa`, cancellation flags and terminal cancellation. The test subscription was canceled and the unused Checkout expired. The sanitized [report](validation/stripe-sandbox-2026-10-19.json) includes the probe script hash. Test-clock and account-read permissions were denied for the anonymous key; neither was bypassed. The probe uses manual trial completion and does not certify annual renewal, real webhook transport, Checkout form completion, or the intended business account.

For an operator-selected isolated sandbox, supply a restricted test key through protected environment injection, confirm the selected account separately, and run:

```sh
python3 backend/scripts/probe-stripe-sandbox.py --run-test-objects --report .build/stripe-sandbox/probe-report.json
```

This command creates test products, a Price, portal configuration, customer, payment method and subscription. It pays only a test invoice, cancels its subscription and expires its unused Checkout; it leaves test product/Price evidence. It rejects live/unrestricted key prefixes and never prints credentials or hosted-session URLs. It is explicitly opt-in and never part of ordinary CI.

In the sandbox, also prove one-time and subscription-invoice full refunds → access revoked/held, partial refund → flagged only, dispute inquiry → flagged only, chargeback → revoked/held, a renewal after a chargeback → still held, and the operator release.

Before live checkout, prove external verification/reset email delivery and a validated Developer ID-signed, notarized, stapled stable download with a real Gatekeeper/permission walkthrough. Stripe is installed/enabled in this session but exposes no account tools; the live backend currently lacks these billing routes/migrations and has SMTP disabled. No live Price, subscription, charge or production billing configuration was created by this review. Consider Stripe Tax after confirming registration requirements; automatic tax remains disabled pending that setup and separate validation.

## Go-live checklist

Operator steps. Nothing in the repository deploys itself, and none of this was done by the change that added the funnel.

1. **Backend deploy.**
   - Back up production PocketBase and confirm the backup restores on staging.
   - On staging restored from it: deploy the hooks, apply migrations in order through `1792109700_trial_funnel` (`migrate history`).
   - **Rate limits:** the migrations install the funnel rules but cannot enable limiting safely on their own. Set Settings → Application → Trusted proxy → headers to the header your proxy overwrites with the client IP first, then turn on **`rateLimits.enabled`** (Settings → Rate limits) if it is still off. Verify: 11 `POST /api/macmint/trial/start` from one client → 429, while another client still gets 200.
   - Run the test-mode walkthrough above end to end on staging.
   - Then production in the same order after a fresh backup.
2. **Stripe live mode.**
   - Recreate the Product, three yearly Prices, three Payment Links (same settings, live redirect `https://macmint.co/welcome?session_id={CHECKOUT_SESSION_ID}`), the portal configuration and the webhook endpoint with all events listed above, in the intended live account.
   - Create the live restricted key with the permissions above; store `STRIPE_RESTRICTED_KEY` and `STRIPE_WEBHOOK_SECRET` (live `whsec_`) in the host secret store.
   - Put the live IDs/URLs into the commerce config with `livemode: true` (live links have no `test_` prefix), run the readiness script, then set `enabled: true`.
   - Make a real low-risk purchase with your own card, confirm `/welcome` → `/download` → app sign-in, then cancel/refund it in Stripe and confirm access follows.
3. **The DMG release.**
   - Strongly recommended: Developer ID signing and notarization (see [RELEASING.md](RELEASING.md)), so customers don't need the Gatekeeper "Open Anyway" step. `release.yml` already publishes `MacMint.dmg`; unsigned builds are marked prerelease and are not offered by `/download`'s GitHub fallback.
   - After testing the downloaded DMG on a disposable Mac, publish the `app_releases` record (`validated`, `notarized`, `published`, `.dmg` URL, `sha256`, `size_bytes`). `/download` then uses it and hides the Gatekeeper note.
4. **Website deploy** (operator step): `bash web/scripts/deploy.sh` from the repository root builds the homepage and the account app, backs up the docroot and installs the `/start`, `/welcome`, `/download` rewrites and their `no-referrer` header. Deploy the backend first. Then check `/`, `/start`, `/welcome` (without a session it explains the link is incomplete), `/download` and `/account` directly, on desktop and phone.

