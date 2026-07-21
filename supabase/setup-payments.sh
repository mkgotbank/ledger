#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One-command deploy of The Ledger payment backend to YOUR Supabase project.
# Run this on YOUR machine (it needs your logged-in Supabase CLI + your keys).
#
# One-time prep:
#   1. brew install supabase/tap/supabase        # install the Supabase CLI
#   2. supabase login                            # opens your browser to authorize
#   3. supabase link --project-ref <your-ref>    # from your project's dashboard URL
#   4. cp supabase/.env.payments.example supabase/.env.payments   # then fill it in
#
# Then:  bash supabase/setup-payments.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
env_file="$here/.env.payments"

command -v supabase >/dev/null || { echo "✗ Supabase CLI not found. Install: brew install supabase/tap/supabase"; exit 1; }
[ -f "$env_file" ] || { echo "✗ Missing $env_file — copy .env.payments.example to .env.payments and fill in your keys."; exit 1; }

set -a; . "$env_file"; set +a
: "${STRIPE_SECRET_KEY:?set STRIPE_SECRET_KEY in supabase/.env.payments}"
: "${STRIPE_WEBHOOK_SECRET:?set STRIPE_WEBHOOK_SECRET in supabase/.env.payments}"
APP_URL="${APP_URL:-https://mkgotbank.github.io/ledger/}"

cd "$root"
echo "→ setting edge-function secrets (server-side only)…"
supabase secrets set STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY" STRIPE_WEBHOOK_SECRET="$STRIPE_WEBHOOK_SECRET" APP_URL="$APP_URL"

echo "→ applying the database migration (0009_payments)…"
supabase db push

echo "→ deploying edge functions…"
supabase functions deploy connect-onboard
supabase functions deploy create-checkout
supabase functions deploy payments-webhook --no-verify-jwt   # Stripe calls this; its signature is the auth

echo
echo "✓ Backend deployed."
echo "  Last step (browser, ~2 min): in the Stripe dashboard → Developers → Webhooks, add an"
echo "  endpoint at your 'payments-webhook' function URL, tick 'listen to events on Connected"
echo "  accounts', and select account.updated + checkout.session.completed. Put its signing"
echo "  secret into .env.payments as STRIPE_WEBHOOK_SECRET and re-run this script once."
echo "  Full click-path + test-mode run: supabase/PAYMENTS.md"
