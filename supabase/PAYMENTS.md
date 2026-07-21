# The Ledger — Online Payments (Stripe Connect + PayPal)

Multi-tenant online invoice payments: **each business connects its own processor account and
receives its own money.** The Ledger is the *platform* — it never holds funds and never touches
card data (Stripe/PayPal host the checkout page).

> **Status:** in progress on branch `claude/payments-connect`. This doc is the plan of record.
> Nothing here goes live until the whole flow is built **and** validated in the processors'
> **test/sandbox mode**. Do not point it at real cards/accounts until the test-mode run passes.

## How it works (the flow)

```
Owner connects payouts ─┐
                        ▼
  [client] "Connect Stripe/PayPal"  → edge fn: create Connect account → provider onboarding URL
                        │                                   │
                        └──────────── owner completes onboarding at Stripe/PayPal ──────────────┐
                                                                                                 ▼
  provider webhook → edge fn (verify signature) → upsert_payment_account(charges_enabled=true)

Customer pays an invoice ─┐
                          ▼
  [client] "Request payment" on invoice → edge fn: create Checkout Session ON the business's
                                          connected account (amount + invoice # in metadata)
                          │
                          ▼
  customer pays on Stripe/PayPal hosted page  →  provider webhook → edge fn (verify signature)
                          │                                          → record_payment_event(succeeded)
                          ▼
  [client] reconcile: reads payment_events (RLS) → marks matching invoice paid in D.invoices
```

**Why a webhook (not just the browser redirect):** never trust the client's "success" redirect —
the webhook is the server-verified source of truth, signature-checked and idempotent.

## Pieces

| Piece | Where | Status |
|-------|-------|--------|
| DB schema (`payment_accounts`, `payment_events`, RPCs, RLS) | `migrations/0009_payments.sql` | ✅ built |
| `connect-onboard` (create/refresh connected account → onboarding URL) | `functions/connect-onboard/` | ✅ built |
| `create-checkout` (Checkout Session on the connected account for an invoice) | `functions/create-checkout/` | ✅ built |
| `payments-webhook` (verify signature, record payment / update account) | `functions/payments-webhook/` | ✅ built |
| One-command deploy script + `.env` template | `setup-payments.sh`, `.env.payments.example` | ✅ built |
| Client UI (connect payouts, "Request payment" button, reconcile) | `index.html` | ⏳ next (after test-mode passes) |

Staging: **Phase 1 = Stripe Connect end-to-end** (onboard → checkout → webhook → reconcile), then
**Phase 2 = add PayPal** reusing the same tables + reconcile. Building both rails at once multiplies
risk; PayPal slots into the scaffolding once Stripe works.

## Secrets — server-side ONLY

Set as Supabase Edge Function secrets (`supabase secrets set …`), **never** in a table, the client,
or git:

| Secret | From |
|--------|------|
| `STRIPE_SECRET_KEY` | Stripe dashboard → Developers → API keys (use **test** key first) |
| `STRIPE_WEBHOOK_SECRET` | Stripe → Developers → Webhooks → your endpoint → signing secret |
| `PAYPAL_CLIENT_ID` / `PAYPAL_SECRET` | PayPal Developer dashboard (sandbox first) |
| `APP_URL` | `https://mkgotbank.github.io/ledger/` (checkout success/cancel return) |

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected into edge functions automatically.

## Prerequisites (you do these — I can't; they need your accounts)

1. **Enable Stripe Connect** on your Stripe account (Dashboard → Connect → Get started). Pick
   **Standard** accounts (each business fully owns their Stripe account; least platform liability).
2. **Apply for PayPal Partner / Commerce Platform** access (for multi-merchant). ⚠️ This can require
   review/approval and take days — start it early, in parallel with the Stripe build.
3. A processor account in **test/sandbox** mode to develop against.
4. Later, for go-live: your platform business details, and a terms/refund policy for your users.

## Deploy (Stripe / Phase 1 — ready now)

One-time: install the Supabase CLI (`brew install supabase/tap/supabase`), then `supabase login`
and `supabase link --project-ref <your-ref>`. Then:

```sh
cp supabase/.env.payments.example supabase/.env.payments   # fill in your TEST keys
bash supabase/setup-payments.sh                            # sets secrets, db push, deploys funcs
```

The script deploys `payments-webhook` with `--no-verify-jwt` (Stripe can't send a Supabase JWT;
the Stripe signature is the auth). After it runs, add the webhook endpoint in the Stripe
dashboard (below) and re-run once with the real `STRIPE_WEBHOOK_SECRET`.

**Register the webhook (browser, ~2 min):** Stripe → Developers → Webhooks → *Add endpoint* →
point it at your `payments-webhook` function URL, tick **"Listen to events on Connected accounts"**,
and select `account.updated` + `checkout.session.completed`. Copy its **signing secret** into
`.env.payments`.

## Test plan (before any real money)

1. Stripe **test mode**: connect a test business, use card `4242 4242 4242 4242`, confirm the webhook
   fires and the invoice flips to paid.
2. Use the **Stripe CLI** (`stripe listen --forward-to …/payments-webhook`) to replay events and
   verify **idempotency** (same event twice = one payment row).
3. Repeat in **PayPal sandbox** once Phase 2 lands.
4. Only after both pass in test/sandbox: switch secrets to live keys.

## Security notes

- No API secret is ever stored in the DB, the client, or git — only in edge-function secrets.
- Webhooks verify the provider signature before trusting any event.
- `payment_events` is written **only** by the webhook (service role); clients are read-only, so a
  client can never forge a "paid" record.
- Idempotency: `unique (provider, provider_ref)` — webhook retries can't double-record.
- Connect **Standard** keeps KYC/compliance/payout liability with each business's own account.
