// payments-webhook — the server-verified source of truth for payment state.
//
// Stripe (incl. Connected accounts) calls this. We VERIFY the signature before trusting anything,
// then record via service-role RPCs (idempotent). Deploy with `--no-verify-jwt`: Stripe can't send
// a Supabase JWT — the Stripe signature IS the authentication here.
//
//   account.updated            → refresh the business's charges_enabled (onboarding finished)
//   checkout.session.completed → record a succeeded payment for the invoice (webhook = truth,
//                                never the browser's success redirect)
// deno-lint-ignore-file no-explicit-any
import Stripe from "npm:stripe@18";
import { createClient } from "jsr:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "");
const WH = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const cryptoProvider = Stripe.createSubtleCryptoProvider(); // async verify for Deno/edge
const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature");
  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig ?? "", WH, undefined, cryptoProvider);
  } catch (e: any) {
    return new Response(`bad signature: ${e?.message}`, { status: 400 });
  }

  try {
    if (event.type === "account.updated") {
      const a = event.data.object as Stripe.Account;
      const business_id = a.metadata?.business_id;
      if (business_id) {
        await admin.rpc("upsert_payment_account", {
          p_business_id: business_id, p_provider: "stripe", p_account_ref: a.id,
          p_charges_enabled: !!a.charges_enabled,
          p_details: { country: a.country ?? null, details_submitted: !!a.details_submitted },
        });
      }
    } else if (event.type === "checkout.session.completed") {
      const s = event.data.object as Stripe.Checkout.Session;
      const business_id = s.metadata?.business_id;
      const parsed = s.metadata?.invoice_number ? parseInt(s.metadata.invoice_number, 10) : NaN;
      const invoice_number = Number.isFinite(parsed) ? parsed : null;
      if (business_id && s.payment_status === "paid") {
        await admin.rpc("record_payment_event", {
          p_business_id: business_id,
          p_invoice_number: invoice_number,
          p_provider: "stripe",
          p_provider_ref: s.id, // idempotency key — a retry can't double-record
          p_amount: (s.amount_total ?? 0) / 100,
          p_currency: s.currency ?? "usd",
          p_status: "succeeded",
          p_raw: {
            id: s.id, amount_total: s.amount_total, currency: s.currency,
            customer_email: s.customer_details?.email ?? s.customer_email ?? null,
          },
        });
      }
    }
    return new Response(JSON.stringify({ received: true }), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  } catch (e: any) {
    // 500 → Stripe retries later, so a transient DB hiccup won't drop the payment record.
    return new Response(`handler error: ${e?.message}`, { status: 500 });
  }
});
