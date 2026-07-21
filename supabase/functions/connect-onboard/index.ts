// connect-onboard — start / refresh a business's Stripe Connect (Standard) onboarding.
//
// Called by the OWNER from the app. Creates the connected account on first use (money goes
// straight to the business), records the non-secret account id via the service-role RPC, and
// returns a Stripe-hosted onboarding URL. `action:"status"` refreshes charges_enabled instead.
//
// The Stripe SECRET KEY lives only in this function's env (STRIPE_SECRET_KEY) — never in the DB,
// the client, or git. RLS + owner check gate who can trigger it.
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
    // Identify the caller from their Supabase JWT.
    const auth = req.headers.get("Authorization") ?? "";
    const asUser = createClient(SUPABASE_URL, ANON, { global: { headers: { Authorization: auth } } });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "not authenticated" }, 401);

    const { business_id, action } = await req.json().catch(() => ({}));
    if (!business_id) return json({ error: "business_id required" }, 400);

    const admin = createClient(SUPABASE_URL, SERVICE);
    // Only the OWNER may connect payouts — it's their bank/payout relationship.
    const { data: mem } = await admin.from("memberships").select("role")
      .eq("business_id", business_id).eq("user_id", user.id).maybeSingle();
    if (mem?.role !== "owner") return json({ error: "owner only" }, 403);

    const { data: existing } = await admin.from("payment_accounts")
      .select("account_ref, charges_enabled")
      .eq("business_id", business_id).eq("provider", "stripe").maybeSingle();

    // Just report status (used by the client to show "connected / ready").
    if (action === "status") {
      let charges = !!existing?.charges_enabled;
      if (existing?.account_ref) {
        const acct = await stripe.accounts.retrieve(existing.account_ref);
        charges = !!acct.charges_enabled;
        await admin.rpc("upsert_payment_account", {
          p_business_id: business_id, p_provider: "stripe", p_account_ref: acct.id,
          p_charges_enabled: charges,
          p_details: { country: acct.country ?? null, details_submitted: !!acct.details_submitted },
        });
      }
      return json({ connected: !!existing?.account_ref, charges_enabled: charges });
    }

    // Create the connected account on first use.
    let acctId = existing?.account_ref;
    if (!acctId) {
      const { data: biz } = await admin.from("businesses").select("name").eq("id", business_id).maybeSingle();
      const acct = await stripe.accounts.create({
        type: "standard",
        metadata: { business_id },
        business_profile: { name: biz?.name ?? "Business" },
      });
      acctId = acct.id;
      await admin.rpc("upsert_payment_account", {
        p_business_id: business_id, p_provider: "stripe", p_account_ref: acctId,
        p_charges_enabled: false, p_details: {},
      });
    }

    // Hosted onboarding link — the owner finishes setup on Stripe, then returns to the app.
    const link = await stripe.accountLinks.create({
      account: acctId,
      refresh_url: `${APP_URL}?pay_setup=refresh`,
      return_url: `${APP_URL}?pay_setup=done`,
      type: "account_onboarding",
    });
    return json({ url: link.url });
  } catch (e: any) {
    return json({ error: String(e?.message ?? e) }, 400);
  }
});
