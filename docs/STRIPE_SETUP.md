# Stripe subscriptions and purchase setup

The approved starting offer is **US$39.99/year, a three-day free trial, and up to three Macs per account**. Collect a payment method in hosted Checkout; allow one trial per MacMint account. Terms remain server configurable. The intended Stripe business account has not been identified or verified in this session.

Use `backend/commerce.subscription.example.json` for this offer. It deliberately has `enabled: false`, `livemode: false`, and blank Price/portal IDs. The legacy `commerce.example.json` remains available for compatible one-time purchases. Changing `duration_days` never schedules renewals.

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
| `price_id` | Active recurring licensed Price from that same Stripe account/mode. |
| `amount_minor`, `currency` | `3999`, `usd`, exactly matching the Price. |
| `plan`, `duration_days` | `pro`, `0`; recurring access comes from verified trial/invoice periods. |
| `billing_interval`, `billing_interval_count` | `year`, `1`. Monthly offers are also supported explicitly. |
| `trial_days` | `3`; zero for ineligible returning accounts; bounded integer 0–30. |
| `max_devices` | `3`; accepted range 1–100. |
| `portal_configuration_id` | Explicit active `bpc_…` in the same account/mode. |

Configure the portal with payment-method updates and cancellation **at period end**. Disable subscription updates: changing to an unknown Price is not implemented by this single-offer integration. The server checks the portal configuration before creating Checkout and before opening the portal. New checkout can be disabled without blocking existing customers from managing/canceling subscriptions.

Only sandbox local development accepts HTTP localhost/127.0.0.1 origins. Real staging uses HTTPS. Currency display follows Stripe charge units, including special zero-decimal conventions. [Stripe currency rules](https://docs.stripe.com/currencies#special-cases).

## Provider credentials and permissions

Use the intended business account and a separate general Stripe sandbox. Store a least-privilege restricted API key and matching signing secret in the host's protected secret store:

- `STRIPE_RESTRICTED_KEY`, or private `app_secrets.name = stripe_restricted_key`.
- `STRIPE_WEBHOOK_SECRET`, or private `app_secrets.name = stripe_webhook_secret`.

The adapter needs Checkout Sessions create/read (including line items/list by subscription), Prices read, Subscriptions read, Invoices read, Billing Portal Configurations read and Billing Portal Sessions create. Verify actual restricted-key permissions in the isolated sandbox. No publishable key or Stripe.js is required. Never commit values or paste them into chat. [Stripe key handling](https://docs.stripe.com/keys), [sandboxes](https://docs.stripe.com/sandboxes).

PocketBase Goja cannot load Stripe's Node SDK, so the server-only REST adapter pins `2026-08-26.dahlia`. It uses invoice `parent.subscription_details.subscription`, line `pricing.price_details.price`, and subscription-item `current_period_end`. Verify these shapes against the pinned provider API during real sandbox acceptance; protocol fixtures do not certify real credentials or API compatibility.

## Webhooks and deployment

Back up staging first and apply **all** versioned migrations, including `1792109500_subscriptions.js`. Reapplying migrations is tested; rollback deliberately preserves billing evidence. Deploy hooks/migrations before the website consuming the new response contract. No provider IDs or secrets are accepted from the browser as billing ownership.

Register the backend endpoint `/api/macmint/stripe/webhook` with a matching API version and these events:

```text
checkout.session.completed
checkout.session.async_payment_succeeded
checkout.session.async_payment_failed
checkout.session.expired
customer.subscription.created
customer.subscription.updated
customer.subscription.deleted
customer.subscription.paused
customer.subscription.resumed
invoice.paid
invoice.payment_failed
invoice.payment_action_required
invoice.finalization_failed
invoice.voided
invoice.marked_uncollectible
```

The handler verifies the raw-body HMAC and timestamp, retrieves authoritative objects, and returns retryable 503 on synchronization failure. Provider calls occur outside database transactions. Original Checkout ownership, mode, customer, Price, amount, currency, quantity, cadence and invoice period are validated before updating access. [Stripe subscription webhooks](https://docs.stripe.com/billing/subscriptions/webhooks), [trial behavior](https://docs.stripe.com/billing/subscriptions/trials).

Endpoints:

- `GET /api/macmint/checkout/config`: public offer or `enabled:false`; authenticated users get their trial eligibility. No-store.
- `GET /api/macmint/checkout/status?request_key=<UUID>`: authenticated owner-only durable state and frozen offer, no provider calls.
- `POST /api/macmint/billing/portal`: authenticated owner-bound customer; ignores browser customer/return URLs. Works while checkout is disabled.
- `GET /api/macmint/admin/commerce/readiness`: superuser-only reason codes, no configuration/secrets/object IDs. Local prerequisites alone are not launch evidence.

An unresolved old order or an uncertain create response outside the safe idempotency window requires operator reconciliation against Stripe. Preserve its row/request identity. Confirm actual provider state before permitting a replacement; never delete the evidence or grant access from a return URL. Refunds/disputes require an explicit operator policy and provider reconciliation; this implementation does not invent automatic refund or revocation rules.

## Verification before sales

```sh
node --test backend/tests/*.test.cjs
python3 backend/tests/integration.py
python3 backend/tests/service_integration.py
python3 backend/tests/subscriptions_integration.py
(cd web && npm run build && npm run lint)
bash web/scripts/build-homepage.sh
(cd web && npm run test:browser)
```

These use disposable databases, synthetic provider protocol responses and local mail fixtures. Native account/offline/AI lifecycle tests run in macOS CI. They do **not** prove real account permissions, charges, email delivery or downloaded consumer installation.

In the intended isolated Stripe sandbox, prove account verification → annual offer → payment-method collection → three-day trial → explicit Mac activation → first paid invoice → renewal → payment failure/action-required → recovery → period-end cancellation → final expiry. Use test clocks where supported. Include canceling during the trial, duplicate/reordered/retried webhooks, dropped create responses, a changed account email/offer, second-trial refusal, cross-user portal access, device limits and device transfer. Confirm Stripe trial reminders/receipt emails and the short trial's first-charge disclosure. [Customer Portal integration](https://docs.stripe.com/customer-management/integrate-customer-portal).

Before live checkout, prove external verification/reset email delivery and a validated Developer ID-signed, notarized, stapled stable download with a real Gatekeeper/permission walkthrough. Stripe is installed/enabled in this session but exposes no account tools; the live backend currently lacks these billing routes/migrations and has SMTP disabled. No live Price, subscription, charge or production billing configuration was created by this review. Consider Stripe Tax after confirming registration requirements; automatic tax remains disabled pending that setup and separate validation.
