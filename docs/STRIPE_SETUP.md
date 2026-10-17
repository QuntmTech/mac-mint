# Stripe purchase setup

MacMint uses a hosted Stripe Checkout page, server-side purchase orders, signed webhooks, and transactional license grants. The app and website never receive a Stripe secret or restricted API key. The current license implementation accepts **one-time payments** for either time-limited Pro access or lifetime access. Access duration is not a recurring subscription interval.

Pricing is intentionally unset in `backend/commerce.example.json`. Keep checkout disabled while the owner chooses the offer. A recurring subscription requires a separate Billing lifecycle implementation and tests; changing `duration_days` alone does not add renewals, cancellation, or recurring charges.

## Inputs still needed

Before provisioning a real offer, confirm the intended Stripe account/sandbox, price and currency, one-time versus recurring billing, access duration, device allowance, and refund/support policy. No price or live product was created by the readiness work.

The Stripe connector initially reported `UNAUTHORIZED` / “requires reauthentication,” including after a reconnect was reported. A later retry returned “MCP tool call blocked by app configuration.” Neither retry provided account access. This prevented inspection or configuration of the user's Stripe account. The public production checkout-config endpoint returned HTTP 404 during the read-only readiness check; repository changes must be deployed and migrations tested before that route is available there. These are observed setup gaps, not proof of a payment failure.

## Configuration template and offline preflight

From the repository root:

```sh
cp backend/commerce.example.json backend/commerce.local.json
node backend/scripts/check-commerce-readiness.cjs --config backend/commerce.local.json
```

`commerce.local.json` is ignored by Git. The example contains no price and the command is expected to exit **2** with `status: blocked` until the inputs are supplied. It never changes the file, contacts Stripe, enables checkout, or prints credential/configuration values.

| Field | Meaning |
| --- | --- |
| `enabled` | Keep false until staging verification and release gates pass. |
| `livemode` | Explicitly false for the isolated sandbox; true only for the intended live account. |
| `web_origin` | Trusted account-website origin for return links. Defaults to `https://macmint.co` when omitted; set the staging HTTPS origin for staging. No path, query, credentials or fragment. |
| `price_id` | The approved account's existing active one-time Stripe Price. |
| `amount_minor` | Exact integer `unit_amount` returned by Stripe for that Price. |
| `currency` | The matching lowercase Stripe currency code. |
| `plan` | `pro` for time-limited access or `lifetime`. |
| `duration_days` | Positive for Pro; zero for lifetime. Does not schedule future charges. |
| `max_devices` | Approved license device allowance, between 1 and 100. |

The CLI also checks the shape and mode of `STRIPE_RESTRICTED_KEY` and the presence of `STRIPE_WEBHOOK_SECRET` in its environment. Supply them through a protected secret store or a safe local secret-injection workflow; do not put values into source files or paste them into chat. Hosts using the private `app_secrets` fallback should use the authenticated server diagnostic instead of assuming local environment checks describe the deployed host.

For isolated local development, `http://localhost:<port>` or `http://127.0.0.1:<port>` is accepted only when `livemode` is false. Real staging should use HTTPS. The origin and account email freeze onto each order before its first Stripe request, so a settings or email change cannot alter a retry's idempotent parameters. Older orders retain their original production return origin. Browser-supplied return URLs are ignored.

Exit **0** means `local_prerequisites_complete`, not launch approval. `launch_ready` remains false because the CLI cannot establish Price ownership, real key permissions, event delivery, release validation, email delivery, or an actual purchase. Currency presentation follows Stripe charge units, including its special cases; see [Stripe's currency rules](https://docs.stripe.com/currencies#special-cases).

## Server secrets and permissions

Use a separate general Stripe sandbox for development, isolated from live account settings and from CI fixtures. Store a least-privilege restricted key and matching endpoint signing secret in the host's secret store:

- `STRIPE_RESTRICTED_KEY`, or private `app_secrets.name = stripe_restricted_key`.
- `STRIPE_WEBHOOK_SECRET`, or private `app_secrets.name = stripe_webhook_secret`.

The REST adapter needs Checkout Session create/read access, including line-item retrieval and listing sessions by payment intent, Price read access, and Charges and Disputes read access for refund and dispute handling. Verify the exact restricted-key permissions in the sandbox; a plausible prefix does not establish authorization. No publishable key or Stripe.js is needed for this hosted redirect flow. See [Stripe key handling](https://docs.stripe.com/keys) and [sandbox guidance](https://docs.stripe.com/sandboxes).

The PocketBase Goja runtime cannot load the Node Stripe SDK. `macmint_payments_lib.js` therefore uses a small server-only REST client pinned to API version `2026-08-26.dahlia`. Stripe error bodies and credentials are not forwarded to clients.

## Migrations, deployment, and diagnostics

Test migrations against a backed-up staging database before deployment. The order migration adds immutable request data and an `expired` state while preserving old payment evidence. Existing orders without the data needed for a safe retry remain available for fulfillment/reconciliation; they do not silently become new payment attempts.

Deploy backend hooks/migrations before the website that consumes the new status contract. The local account app's explicit Check Purchase uses the existing device activation API. A purchase grants entitlement; registering this Mac remains an explicit account action. Periodic verification must not reactivate a deactivated device.

Read-only endpoints:

- `GET /api/macmint/checkout/config`: public purchasable offer, or `enabled: false` when prerequisites are absent. Returns no credentials.
- `GET /api/macmint/checkout/status?request_key=<UUID>`: authenticated, owner-scoped order status. Known orders include their immutable offer terms. It makes no Stripe API calls. Only verified terminal `failed`/`expired` states permit a new attempt.
- `GET /api/macmint/admin/commerce/readiness`: superuser-only diagnostic returning `ready` and named `reasons`. It never returns the configuration, secret values, or Stripe object IDs. A true result checks configured local prerequisites, not sandbox end-to-end evidence.

Superuser recovery routes:

- `POST /api/macmint/admin/checkout/reconcile` with `{ "order": "<order id>" }`: retrieves the order's Checkout Session from Stripe and applies its authoritative state through the normal fulfillment and expiry code (paid → fulfilled once; expired → expired). Use it for `checkout_attention` and for pending orders whose terminal webhook never arrived. An open session or a complete-but-unpaid asynchronous payment is reported, not changed; resend the missing Stripe event instead. An order that never recorded a session takes `"session": "cs_..."` (found by its `macmint_order` metadata in the Dashboard; the session must carry that order ID), or, only after checking Stripe and at least 25 hours after creation, `"confirm_expired_without_session": true`.
- `POST /api/macmint/admin/licenses/revoke` with `{ "license": "<id>" }`, `{ "code": "MINT-…" }` or `{ "order": "<order id>" }`, optional `"reason"`: revokes the license and recomputes the owner's entitlement in one transaction. Idempotent.

Browser returns such as `checkout=processing` are hints for the interface, never proof of payment. A missing or unrecognized order remains unconfirmed. The browser preserves retry identity on cancellation, network errors, and uncertain responses; another unresolved order must be resumed or reconciled before a new one is created.

## Required webhook endpoint

Register the deployed backend URL ending in:

```text
/api/macmint/stripe/webhook
```

Subscribe to these event types with a compatible API version:

```text
checkout.session.completed
checkout.session.async_payment_succeeded
checkout.session.async_payment_failed
checkout.session.expired
charge.refunded
charge.dispute.created
charge.dispute.updated
```

The handler verifies the raw-body signature and timestamp, then retrieves the authoritative Checkout Session and line items. Payment must be paid and match the immutable order's user, mode, Price, amount, currency and quantity before an atomic license/entitlement grant. Expired/failed notifications cannot downgrade a fulfilled purchase. Concurrent/repeated successful deliveries do not extend access twice. See [Stripe fulfillment](https://docs.stripe.com/checkout/fulfillment?payment-ui=stripe-hosted).

Refunds and disputes are handled the same way: the signed event is a trigger, and the server retrieves the Charge or Dispute, maps its payment intent to the order (recorded at fulfillment; older orders are found through their Checkout Session), and in one transaction marks the order `refunded` or `disputed`, revokes its license and recomputes the entitlement from the user's remaining licenses. Replays change nothing, and a later success event cannot restore access. A partial refund only sets `attention = partial_refund` on the order for operator review. A dispute *inquiry* (status `warning_needs_response` / `warning_under_review`) withdraws no funds and only sets `attention = dispute_inquiry`; a formal chargeback (`needs_response`, `under_review`, `lost`), including an inquiry that escalates and arrives as `charge.dispute.updated`, revokes. A refunded order permits a new purchase attempt; a disputed one does not. Operator-set (`manual`) entitlements are not rewritten; an `entitlement_review` audit row is written instead. Events for payments that are not MacMint checkouts are acknowledged and ignored. A won dispute does not restore access automatically, and a dispute first seen as won or closed is ignored; grant a replacement license if appropriate.

An unresolved legacy order or a lost create response outside the safe idempotency window requires operator reconciliation with Stripe (see the reconcile route above). Preserve its row and request identity. Check the actual session/payment state before marking a terminal outcome; do not delete the order, grant access from the return URL, or create an uncertain replacement payment. If a terminal webhook is missing, database-only status deliberately remains pending even if trying to resume reports an expired provider session. Fix delivery and reconcile the authoritative state before permitting a replacement.

## Verification before opening sales

Repository checks, using the pinned disposable PocketBase test runtime:

```sh
node --test backend/tests/*.test.cjs
python3 backend/tests/integration.py
python3 backend/tests/service_integration.py
cd web
npm run build
npm run lint
npx playwright test
```

These tests use synthetic Stripe protocol responses and isolated databases; they do **not** establish that the owner's real Stripe account, restricted key or webhook registration works. Native account lifecycle tests run in macOS CI.

In the intended isolated sandbox, prove verified account → configured offer → Stripe Checkout → paid webhook → owner status → account entitlement → explicit Mac activation. Also test declined, cancelled, expired and delayed payments; dropped create/return responses; reloads/new tabs; concurrent webhook retries; different users; a changed account email, offer or return origin; device limits; and sign-out during verification.

Use a validated, notarized stable build before enabling checkout. Prove external verification/reset email delivery. In the sandbox, also prove full refund → access revoked, partial refund → flagged only, and dispute → access revoked. Keep any future subscription lifecycle explicit rather than treating the existing one-time purchase implementation as support for it. Automatic tax requires confirmed registrations and separate testing before enabling it. Only publish the offer and open live sales after the actual sandbox and consumer-install gates pass.
