-- ════════════════════════════════════════════════════════════════════════════
-- 0009 — ONLINE PAYMENTS (Stripe Connect + PayPal), multi-tenant.
--
-- Model: each BUSINESS connects its OWN payment account and receives its own money.
--   • Stripe  → Stripe Connect (Standard): each business has a connected account id.
--   • PayPal  → each business stores its own PayPal merchant/email.
-- The Ledger is the PLATFORM; it never holds funds and never sees card data (Stripe/
-- PayPal host the checkout). We only store CONNECTION METADATA + a record of payments.
--
-- SECURITY (mirrors 0001's model):
--   • ENABLE + FORCE RLS on every table.
--   • NO secret keys are ever stored here. Stripe/PayPal API secrets live ONLY in
--     Supabase Edge Function secrets (server-side env), never in a table, never in the
--     client, never in git. This schema stores only PUBLIC ids (connected-account id,
--     publishable-safe references) + payment results.
--   • Clients may READ their business's connection status + payments (any member) and
--     the owner/admin may start/removeconnections via RPC — but the actual writes to
--     payment_events come ONLY from the webhook edge function (service role, bypasses
--     RLS), so a client can never forge a "paid" record.
--   • All enum casts schema-qualified as ::public.member_role[] (search_path='' funcs),
--     per the 0002 fix — never a bare ::member_role[].
-- ════════════════════════════════════════════════════════════════════════════

create type payment_provider as enum ('stripe','paypal');
create type payment_status   as enum ('pending','succeeded','failed','refunded');

-- ── payment_accounts — one row per business per provider (its CONNECTED account) ──
-- Holds only non-secret connection metadata. For Stripe Connect Standard the
-- `account_ref` is the connected account id (acct_...); for PayPal it's the merchant
-- id / receiving email. charges_enabled mirrors the provider's onboarding state.
create table public.payment_accounts (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  provider        payment_provider not null,
  account_ref     text,                     -- Stripe acct_… OR PayPal merchant id/email (NOT a secret)
  charges_enabled boolean not null default false,
  details         jsonb not null default '{}'::jsonb,  -- non-secret onboarding detail (country, etc.)
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (business_id, provider)
);
create index idx_payacct_business on public.payment_accounts(business_id);

-- ── payment_events — a record of each payment attempt/result for an invoice ──
-- WRITTEN ONLY by the webhook edge function (service role). Clients read-only.
-- `provider_ref` is the Stripe session/PaymentIntent id or PayPal order id — unique so
-- the webhook is idempotent (a provider may deliver the same event more than once).
create table public.payment_events (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references public.businesses(id) on delete cascade,
  invoice_number integer,                   -- links back to invoices.number within the business
  provider       payment_provider not null,
  provider_ref   text not null,             -- session/intent/order id — idempotency key
  amount         numeric(14,2),
  currency       text default 'usd',
  status         payment_status not null default 'pending',
  raw            jsonb,                      -- trimmed provider payload for audit (no secrets)
  created_at     timestamptz not null default now(),
  unique (provider, provider_ref)
);
create index idx_payevt_business on public.payment_events(business_id, created_at desc);
create index idx_payevt_invoice  on public.payment_events(business_id, invoice_number);

-- ════════════════════════════════════════════════════════════════════════════
-- RLS
-- ════════════════════════════════════════════════════════════════════════════
alter table public.payment_accounts enable row level security;
alter table public.payment_accounts force  row level security;
alter table public.payment_events   enable row level security;
alter table public.payment_events   force  row level security;

-- Any member may READ their business's connection status + payments.
create policy payacct_select on public.payment_accounts
  for select to authenticated using (public.is_member_of(business_id));
create policy payevt_select on public.payment_events
  for select to authenticated using (public.is_member_of(business_id));

-- NO client insert/update/delete policies: connection rows are written by the
-- connect/refresh RPCs (security definer, owner/admin gated) and payment_events are
-- written by the webhook via the service role (which bypasses RLS). Clients get zero
-- write grants on these tables.
revoke all on public.payment_accounts from anon, authenticated;
revoke all on public.payment_events   from anon, authenticated;
grant select on public.payment_accounts to authenticated;
grant select on public.payment_events   to authenticated;

-- ── connection-management RPCs (owner/admin only) ──────────────────────────────
-- These DON'T talk to Stripe/PayPal (that's the edge function's job with the secret
-- key); they just record/clear the non-secret connected-account reference the edge
-- function produced. The edge function calls upsert_payment_account with the service
-- role after it creates the Connect account; the owner can disconnect via clear.

create or replace function public.get_payment_accounts(p_business_id uuid)
returns table(provider payment_provider, account_ref text, charges_enabled boolean, details jsonb)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_member_of(p_business_id) then
    raise exception 'not a member of business %', p_business_id using errcode = '42501';
  end if;
  return query
    select a.provider, a.account_ref, a.charges_enabled, a.details
    from public.payment_accounts a where a.business_id = p_business_id;
end $$;

-- Owner/admin removes a connection (does NOT delete the account at the provider — the
-- business does that in their Stripe/PayPal dashboard; this just unlinks it here).
create or replace function public.disconnect_payment_account(p_business_id uuid, p_provider payment_provider)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  delete from public.payment_accounts
   where business_id = p_business_id and provider = p_provider;
end $$;

revoke execute on function public.get_payment_accounts(uuid)                         from public, anon;
revoke execute on function public.disconnect_payment_account(uuid, payment_provider) from public, anon;
grant  execute on function public.get_payment_accounts(uuid)                         to authenticated;
grant  execute on function public.disconnect_payment_account(uuid, payment_provider) to authenticated;

-- upsert_payment_account is intentionally NOT granted to authenticated: only the edge
-- functions (service role) call it, after they create/refresh the provider account.
create or replace function public.upsert_payment_account(
  p_business_id uuid, p_provider payment_provider, p_account_ref text,
  p_charges_enabled boolean, p_details jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.payment_accounts (business_id, provider, account_ref, charges_enabled, details, updated_at)
  values (p_business_id, p_provider, p_account_ref, coalesce(p_charges_enabled,false), coalesce(p_details,'{}'::jsonb), now())
  on conflict (business_id, provider) do update
    set account_ref     = excluded.account_ref,
        charges_enabled = excluded.charges_enabled,
        details         = excluded.details,
        updated_at      = now();
end $$;
revoke execute on function public.upsert_payment_account(uuid, payment_provider, text, boolean, jsonb) from public, anon, authenticated;

-- record_payment_event is likewise service-role only (the webhook). Idempotent on
-- (provider, provider_ref). Returns the invoice number so the function can react.
create or replace function public.record_payment_event(
  p_business_id uuid, p_invoice_number integer, p_provider payment_provider,
  p_provider_ref text, p_amount numeric, p_currency text, p_status payment_status, p_raw jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.payment_events
    (business_id, invoice_number, provider, provider_ref, amount, currency, status, raw)
  values
    (p_business_id, p_invoice_number, p_provider, p_provider_ref, p_amount,
     coalesce(nullif(p_currency,''),'usd'), coalesce(p_status,'pending'), p_raw)
  on conflict (provider, provider_ref) do update
    set status = excluded.status, amount = excluded.amount, raw = excluded.raw;
end $$;
revoke execute on function public.record_payment_event(uuid, integer, payment_provider, text, numeric, text, payment_status, jsonb) from public, anon, authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- POST-DEPLOY ASSERTION (must return ZERO rows): every new table RLS-locked.
--   select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
--    where n.nspname='public' and c.relkind='r'
--      and c.relname in ('payment_accounts','payment_events')
--      and (not c.relrowsecurity or not c.relforcerowsecurity);
-- ════════════════════════════════════════════════════════════════════════════
