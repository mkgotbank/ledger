// create-checkout — create a Stripe Checkout session for one invoice, ON the business's own
// connected account (a "direct charge" — the money lands in that business's Stripe balance).
//
// Called by an OWNER/ADMIN from the app. Returns a hosted checkout URL to hand to the customer.
// Stripe hosts the card form, so we never touch card data / PCI scope. The invoice # rides in
// metadata so the webhook can mark that invoice paid.
// deno-lint-ignore-file no-explicit-any
import Stripe from "npm:stripe@18";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders, json } from "../_shared/cors.ts";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") ?? "");
const APP_URL = Deno.env.get("APP_URL") ?? "https://mkgotbank.github.io/ledger/";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const auth = req.headers.get("Authorization") ?? "";
    const asUser = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: auth } } });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "not authenticated" }, 401);

    const { business_id, invoice_number, amount, currency, customer_email, description } =
      await req.json().catch(() => ({}));
    if (!business_id || !(Number(amount) > 0)) {
      return json({ error: "business_id and a positive amount are required" }, 400);
    }

    const admin = createClient(SUPABASE_URL, SERVICE);
    const { data: mem } = await admin.from("memberships").select("role")
      .eq("business_id", business_id).eq("user_id", user.id).maybeSingle();
    if (!mem || !["owner", "admin"].includes(mem.role)) return json({ error: "owner/admin only" }, 403);

    const { data: acct } = await admin.from("payment_accounts")
      .select("account_ref, charges_enabled")
      .eq("business_id", business_id).eq("provider", "stripe").maybeSingle();
    if (!acct?.account_ref || !acct.charges_enabled) {
      return json({ error: "This business hasn't finished setting up Stripe payments yet." }, 400);
    }

    const cur = String(currency || "usd").toLowerCase();
    const invMeta = invoice_number != null ? String(invoice_number) : "";
    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      line_items: [{
        quantity: 1,
        price_data: {
          currency: cur,
          unit_amount: Math.round(Number(amount) * 100), // dollars → cents
          product_data: { name: description || (invoice_number ? `Invoice #${invoice_number}` : "Payment") },
        },
      }],
      customer_email: customer_email || undefined,
      metadata: { business_id, invoice_number: invMeta },
      payment_intent_data: { metadata: { business_id, invoice_number: invMeta } },
      success_url: `${APP_URL}?pay=success`,
      cancel_url: `${APP_URL}?pay=cancel`,
    }, { stripeAccount: acct.account_ref }); // ← direct charge on the connected account

    return json({ url: session.url });
  } catch (e: any) {
    return json({ error: String(e?.message ?? e) }, 400);
  }
});
