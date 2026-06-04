-- ════════════════════════════════════════════════════════════════════════════
-- The Ledger — Phase 2 FINAL multi-tenant migration  (0001_init_FINAL.sql)
-- Single self-contained script. Run top-to-bottom in the Supabase SQL editor.
-- Dependency order: extensions → enums → tables → helper fns/triggers →
--                   RLS enable+FORCE → policies → grants.
--
-- Launch = DOCUMENT MODE: businesses.data jsonb holds the whole D object.
-- The normalized tables (products, transactions, invoices, invoice_items,
-- price_refs, business_settings) exist for Phase-2b but are NOT on the live
-- read/write path yet. RLS is fully enforced on them from day one.
--
-- ── SECURITY FIXES APPLIED (from the 3 adversarial audits) ──────────────────
--  tenant-leak C-1  / auth-bypass HIGH-1 : profiles now FORCE ROW LEVEL SECURITY.
--  tenant-leak C-3  / insert-forgery C3 / auth-bypass CRITICAL-2 :
--        memberships policies forbid non-owner from writing role='owner' and
--        forbid editing your OWN role row; last-owner-demotion trigger guard.
--  insert-forgery C1 : handle_new_user cannot be used to hijack/forge a profile;
--        profiles.email/id/migrated_at are server-pinned (no email trust),
--        clients may only change display_name.
--  insert-forgery C2 / tenant-leak M-2 : default EXECUTE on functions revoked
--        from public/anon so no future SECURITY DEFINER fn is anon-callable.
--  tenant-leak H-1 / auth-bypass MEDIUM-1 : direct UPDATE on businesses.data is
--        revoked; data writes go only through save_business_doc (LWW guard
--        cannot be bypassed); owner_id cannot be overwritten by a member;
--        biz_update WITH CHECK gated to owner.
--  tenant-leak H-2 / insert-forgery H1 / auth-bypass HIGH : every WRITE path is
--        gated by has_role_in(owner/admin/staff) — a 'viewer' is read-only;
--        save_business_doc / next_invoice_number gate by role, not bare membership.
--  tenant-leak M-1 / auth-bypass MEDIUM-4 : removed the permissive
--        "alter default privileges ... GRANT ... to authenticated" time-bomb;
--        grants are explicit per-table; anon gets ZERO table grants.
--  auth-bypass HIGH-3 / tenant-leak (search_path) : ALL functions are
--        SECURITY DEFINER-safe — STABLE where read-only, search_path = ''
--        (empty) with every object schema-qualified (public.*, auth.uid()).
--  auth-bypass HIGH-4 / insert-forgery M1 : migrate_local_data takes a
--        SELECT ... FOR UPDATE row lock to close the migration TOCTOU race.
-- ════════════════════════════════════════════════════════════════════════════

-- ── extensions ──────────────────────────────────────────────────────────────
create extension if not exists pgcrypto;

-- Harden: low-priv roles must not be able to plant shadowing objects in public
-- (Supabase already does this on new projects; assert it so search_path='' is safe).
revoke create on schema public from public;

-- ════════════════════════════════════════════════════════════════════════════
-- ENUMS
-- ════════════════════════════════════════════════════════════════════════════
create type member_role   as enum ('owner','admin','staff','viewer');
create type txn_type      as enum ('sale','restock','use','expense');
create type unit_type     as enum ('weight','count');
create type discount_type as enum ('amt','pct');

-- ════════════════════════════════════════════════════════════════════════════
-- TABLES
-- ════════════════════════════════════════════════════════════════════════════

-- ── profiles (1:1 auth.users) ──
-- email/id/migrated_at are SERVER-controlled (see pin_profile_columns trigger).
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  display_name text,
  migrated_at  timestamptz,                 -- mirror; businesses.migrated_at is authoritative
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- ── businesses (tenant root + launch document store) ──
create table public.businesses (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete restrict,
  name        text not null default 'My Business',
  data        jsonb not null default '{"strains":{},"cur":"","invoices":[],"business":{}}'::jsonb,
  migrated_at timestamptz,                  -- set once the localStorage D import completes
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ── memberships (user ↔ business, with role) ──  authz source of truth
create table public.memberships (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  role         member_role not null default 'staff',
  invited_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (business_id, user_id)
);
create index idx_memberships_user     on public.memberships(user_id);
create index idx_memberships_business on public.memberships(business_id);

-- ── business_settings (1:1; relational-mode profile/app settings, Phase 2b) ──
create table public.business_settings (
  business_id    uuid primary key references public.businesses(id) on delete cascade,
  name           text,
  logo_url       text,                       -- Storage URL (Phase 2b); dataURL stays in businesses.data at launch
  address        text,
  phone          text,
  email          text,
  tax_id         text,
  tax_rate       numeric(7,4) default 0,
  invoice_prefix text default 'INV',
  invoice_next   integer not null default 1, -- counter; see next_invoice_number()
  terms          text,
  pay_info       text,
  inv_style      text default 'classic',
  inv_font       text default 'sans',
  currency_symbol     text default '$',
  low_stock_threshold numeric(14,4) default 0,
  pin_hash            text,                   -- never store raw PIN; never SELECTed to client (col revoke below)
  active_product_id   uuid,
  lang                text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ── products (D.strains[name]) ──
create table public.products (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  name          text not null,
  archived_at   timestamptz,
  stock         numeric(14,4) not null default 0,
  start_stock   numeric(14,4) not null default 0,
  expenses      numeric(14,2) not null default 0,
  earned        numeric(14,2) not null default 0,
  use_total     numeric(14,4) not null default 0,
  restock_total numeric(14,4) not null default 0,
  unit_type     unit_type not null default 'count',
  unit_singular text,
  unit_plural   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint uq_product_name unique (business_id, name)
);
create unique index uq_product_name_ci on public.products (business_id, lower(name));
create index idx_products_business on public.products (business_id) where archived_at is null;

-- ── price_refs (D.strains[].priceRef[]) ──  business_id denormalized for RLS
create table public.price_refs (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  product_id   uuid not null references public.products(id) on delete cascade,
  label        text not null,
  price        numeric(14,2) not null,
  sort         integer not null default 0,
  extra        jsonb,
  created_at   timestamptz not null default now()
);
create index idx_pricerefs_product  on public.price_refs (product_id, sort);
create index idx_pricerefs_business on public.price_refs (business_id);

-- ── transactions (unified D.strains[].logs[]: sale|restock|use|expense) ──
create table public.transactions (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id) on delete cascade,
  product_id    uuid references public.products(id) on delete restrict,  -- null only for general expenses
  type          txn_type not null,
  occurred_at   timestamptz not null default now(),
  amount        numeric(14,2),
  unit_price    numeric(14,4),
  qty           numeric(14,4),
  weight        numeric(14,4),
  balance_after numeric(14,4),
  pack          text,
  payment       text,
  amount_paid   numeric(14,2),
  batch_id      uuid,
  batch_items   jsonb,
  category      text,
  note          text,
  created_at    timestamptz not null default now(),
  constraint txn_shape check (
    case type
      when 'sale'    then product_id is not null and amount is not null
      when 'restock' then product_id is not null and weight is not null
      when 'use'     then product_id is not null and weight is not null
      when 'expense' then amount is not null
    end
  )
);
create index idx_txn_biz_time      on public.transactions (business_id, occurred_at desc);
create index idx_txn_product_time  on public.transactions (product_id, occurred_at desc) where product_id is not null;
create index idx_txn_biz_type_time on public.transactions (business_id, type, occurred_at desc);
create index idx_txn_batch         on public.transactions (batch_id) where batch_id is not null;

-- ── invoices (D.invoices[]) ──
create table public.invoices (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references public.businesses(id) on delete cascade,
  number           integer not null,
  display_number   text,
  issue_date       date,
  due_date         date,
  po_number        text,
  customer_name    text,
  customer_address text,
  customer_phone   text,
  customer_email   text,
  customer_tax_id  text,
  title            text,
  discount         numeric(14,2) default 0,
  discount_type    discount_type default 'amt',
  tax_rate         numeric(7,4) default 0,
  note             text,
  terms            text,
  pay_info         text,
  inv_style        text,
  inv_font         text,
  paid             boolean not null default false,
  src_txn_id       uuid references public.transactions(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint uq_invoice_number unique (business_id, number)
);
create index idx_invoices_biz_date on public.invoices (business_id, issue_date desc);
create index idx_invoices_biz_paid on public.invoices (business_id, paid);

-- ── invoice_items (child of invoices) ──  business_id denormalized for RLS
create table public.invoice_items (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  invoice_id   uuid not null references public.invoices(id) on delete cascade,
  description  text,
  qty          numeric(14,4) not null default 1,
  unit         text,
  price        numeric(14,4) not null default 0,
  sort         integer not null default 0,
  created_at   timestamptz not null default now()
);
create index idx_invoice_items_invoice  on public.invoice_items (invoice_id, sort);
create index idx_invoice_items_business on public.invoice_items (business_id);

-- ── migration_imports (audit + idempotency) ──
create table public.migration_imports (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  source       text not null default 'localStorage_D',
  raw_payload  jsonb,
  imported_at  timestamptz not null default now(),
  unique (business_id, source)
);
create index idx_migration_user on public.migration_imports(user_id);

-- ════════════════════════════════════════════════════════════════════════════
-- HELPER FUNCTIONS & TRIGGERS  (created BEFORE policies — policies reference them)
--
-- All functions pin search_path = '' (empty) and schema-qualify every object
-- (auth-bypass HIGH-3 / L4): nothing in an attacker-writable schema can shadow
-- an unqualified name inside a SECURITY DEFINER body.
-- ════════════════════════════════════════════════════════════════════════════

-- ── updated_at trigger ──
create or replace function public.set_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger trg_profiles_updated  before update on public.profiles          for each row execute function public.set_updated_at();
create trigger trg_biz_updated       before update on public.businesses        for each row execute function public.set_updated_at();
create trigger trg_settings_updated  before update on public.business_settings for each row execute function public.set_updated_at();
create trigger trg_products_updated  before update on public.products          for each row execute function public.set_updated_at();
create trigger trg_invoices_updated  before update on public.invoices          for each row execute function public.set_updated_at();

-- ── profiles column-pinning trigger (insert-forgery C1) ──
-- email/id/migrated_at are NEVER trusted from the client. On any client UPDATE
-- they are forced back to server-authoritative values; only display_name (and
-- updated_at via the trigger above) is client-mutable. This kills the
-- "claim victim@corp.com" email-invite hijack and any id/migrated_at forgery.
create or replace function public.pin_profile_columns() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.id          := old.id;
  new.email       := old.email;          -- server-set (auth.users.email) only; never client-trusted
  new.migrated_at := old.migrated_at;    -- authoritative copy is businesses.migrated_at
  new.created_at  := old.created_at;
  return new;
end $$;
create trigger trg_pin_profile_columns before update on public.profiles
  for each row execute function public.pin_profile_columns();

-- ── tenant helpers (SECURITY DEFINER → bypass memberships RLS, no recursion) ──
-- Identity comes ONLY from auth.uid() (the signed JWT sub), never from a payload
-- field, so these are unspoofable. STABLE + search_path='' (tenant-leak / auth
-- VERIFIED-SAFE items; hardened per auth-bypass HIGH-3).
create or replace function public.is_member_of(b uuid) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.business_id = b and m.user_id = auth.uid()
  );
$$;

-- owner satisfies every role check by design (documented). For SELECT-style
-- "am I in this tenant" use is_member_of; for WRITE gating pass the allowed roles.
create or replace function public.has_role_in(b uuid, roles member_role[]) returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.memberships m
    where m.business_id = b and m.user_id = auth.uid()
      and (m.role = any(roles) or m.role = 'owner')
  );
$$;

-- ── auto-provision profile on signup (insert-forgery C1) ──
-- Email is taken from auth.users (server), never from any client input. The
-- pin trigger above guarantees it can't be mutated afterward.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end $$;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function public.handle_new_user();

-- ── last-owner guard (tenant-leak C-3 / auth-bypass CRITICAL-2) ──
-- RLS can't count rows cleanly; a BEFORE trigger forbids demoting/deleting the
-- final 'owner' membership of a business (prevents tenant lockout / orphaning).
create or replace function public.guard_last_owner() returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_biz uuid; v_owner_count int;
begin
  if tg_op = 'UPDATE' then
    if old.role = 'owner' and new.role <> 'owner' then v_biz := old.business_id; end if;
  elsif tg_op = 'DELETE' then
    if old.role = 'owner' then v_biz := old.business_id; end if;
  end if;

  if v_biz is not null then
    select count(*) into v_owner_count
    from public.memberships
    where business_id = v_biz and role = 'owner'
      and id <> old.id;
    if v_owner_count = 0 then
      raise exception 'cannot remove the last owner of business %', v_biz using errcode = '23514';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger trg_guard_last_owner
  before update or delete on public.memberships
  for each row execute function public.guard_last_owner();

-- ── provision_business: business + owner membership + settings, atomically ──
-- Always sets owner_id = auth.uid() and the owner membership for the caller; the
-- fresh business id means you can never attach yourself to an existing tenant.
create or replace function public.provision_business(p_name text default 'My Business')
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare bid uuid; v_uid uuid := auth.uid(); v_name text;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '42501'; end if;
  v_name := coalesce(nullif(trim(p_name), ''), 'My Business');

  insert into public.businesses (owner_id, name)
    values (v_uid, v_name)
    returning id into bid;
  insert into public.memberships (business_id, user_id, role)
    values (bid, v_uid, 'owner');
  insert into public.business_settings (business_id, name)
    values (bid, v_name);
  return bid;
end $$;

-- ── save_business_doc: launch write-through + optimistic-concurrency guard ──
-- Role-gated (tenant-leak H-2 / auth-bypass HIGH): a 'viewer' is read-only and
-- CANNOT clobber the document. updated_at guard rejects stale multi-device
-- writes. This RPC is the ONLY path that writes businesses.data (direct UPDATE
-- of data is revoked below — auth-bypass MEDIUM-1), so the LWW guard is
-- un-bypassable.
create or replace function public.save_business_doc(p_id uuid, p_data jsonb, p_base timestamptz)
returns timestamptz
language plpgsql security definer
set search_path = ''
as $$
declare v timestamptz;
begin
  if not public.has_role_in(p_id, array['owner','admin','staff']::member_role[]) then
    raise exception 'no write access to business %', p_id using errcode = '42501';
  end if;
  update public.businesses
     set data = p_data, updated_at = now()
   where id = p_id and (p_base is null or updated_at = p_base)
   returning updated_at into v;
  if v is null then
    raise exception 'stale_write' using errcode = '40001';  -- client re-hydrates
  end if;
  return v;
end $$;

-- ── next_invoice_number: atomic read-and-increment (relational mode; Phase 2b) ──
create or replace function public.next_invoice_number(b uuid)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare n integer;
begin
  if not public.has_role_in(b, array['owner','admin','staff']::member_role[]) then
    raise exception 'no write access to business %', b using errcode = '42501';
  end if;
  update public.business_settings
     set invoice_next = invoice_next + 1, updated_at = now()
   where business_id = b
   returning invoice_next - 1 into n;
  if n is null then raise exception 'no settings row for business %', b; end if;
  return n;
end $$;

-- ── migrate_local_data: one-shot localStorage D import (idempotent, locked) ──
-- Owner-only. FOR UPDATE row lock closes the multi-device TOCTOU race
-- (auth-bypass HIGH-4 / insert-forgery M1) so two concurrent calls can't both
-- pass the migrated_at check.
create or replace function public.migrate_local_data(p_business_id uuid, p_d jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid(); v_migrated timestamptz;
begin
  if not public.has_role_in(p_business_id, array['owner']::member_role[]) then
    raise exception 'Not authorized for business %', p_business_id using errcode = '42501';
  end if;

  -- serialize concurrent imports
  select migrated_at into v_migrated
  from public.businesses
  where id = p_business_id
  for update;

  if v_migrated is not null then
    raise exception 'Business already migrated';
  end if;

  -- LAUNCH = document mode: store the whole D, derive name, stamp migrated_at.
  update public.businesses
     set data = p_d,
         name = coalesce(nullif(p_d->'business'->>'name', ''), name),
         migrated_at = now()
   where id = p_business_id;

  insert into public.migration_imports (business_id, user_id, source, raw_payload)
  values (p_business_id, v_uid, 'localStorage_D', p_d)
  on conflict (business_id, source) do nothing;

  -- Phase 2b: also decompose p_d into products/price_refs/transactions/invoices/
  -- invoice_items + business_settings here, in this same transaction.
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — ENABLE + FORCE on EVERY table (incl. profiles)
-- profiles FORCE was the missing line in the draft (tenant-leak C-1 / HIGH-1).
-- ════════════════════════════════════════════════════════════════════════════
alter table public.profiles          enable row level security;
alter table public.businesses        enable row level security;
alter table public.memberships       enable row level security;
alter table public.business_settings enable row level security;
alter table public.products          enable row level security;
alter table public.price_refs        enable row level security;
alter table public.transactions      enable row level security;
alter table public.invoices          enable row level security;
alter table public.invoice_items     enable row level security;
alter table public.migration_imports enable row level security;

alter table public.profiles          force row level security;   -- FIX: was missing
alter table public.businesses        force row level security;
alter table public.memberships       force row level security;
alter table public.business_settings force row level security;
alter table public.products          force row level security;
alter table public.price_refs        force row level security;
alter table public.transactions      force row level security;
alter table public.invoices          force row level security;
alter table public.invoice_items     force row level security;
alter table public.migration_imports force row level security;

-- ════════════════════════════════════════════════════════════════════════════
-- POLICIES
-- Convention: SELECT = is_member_of (any role may read its tenant).
--             WRITE  = has_role_in(owner/admin/staff) — 'viewer' is read-only
--                      (tenant-leak H-2 / insert-forgery H1 / auth-bypass HIGH).
-- ════════════════════════════════════════════════════════════════════════════

-- ── profiles: a user reads/updates ONLY their own row. ──
-- No INSERT policy: rows are born via the handle_new_user trigger (definer),
-- so a client can never forge a profile row (insert-forgery C1). UPDATE is
-- self-only; the pin trigger restricts it to display_name. No DELETE.
create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = auth.uid());
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ── businesses ──
-- NO client INSERT (only provision_business creates them).
-- NO client UPDATE policy at all: direct UPDATE privilege is revoked below, so
--   businesses.data is writable ONLY through save_business_doc (LWW-guarded)
--   and businesses.name only via column grant (auth-bypass MEDIUM-1 / tenant H-1).
--   owner_id can never be overwritten by a member.
create policy biz_select on public.businesses
  for select to authenticated
  using (public.is_member_of(id));
create policy biz_update_name on public.businesses
  for update to authenticated
  using (public.has_role_in(id, array['owner','admin']::member_role[]))
  with check (public.has_role_in(id, array['owner','admin']::member_role[]));
create policy biz_delete on public.businesses
  for delete to authenticated
  using (public.has_role_in(id, array['owner']::member_role[]));

-- ── memberships ──
-- Owner/admin manage members, BUT only an owner may create/elevate an 'owner'
-- row, and NOBODY may edit their OWN role row (tenant-leak C-3 / insert-forgery
-- C3 / auth-bypass CRITICAL-2). Last-owner removal is blocked by trigger.
create policy mem_select on public.memberships
  for select to authenticated
  using (user_id = auth.uid() or public.is_member_of(business_id));
create policy mem_insert on public.memberships
  for insert to authenticated
  with check (
    public.has_role_in(business_id, array['owner','admin']::member_role[])
    and (role <> 'owner' or public.has_role_in(business_id, array['owner']::member_role[]))
  );
create policy mem_update on public.memberships
  for update to authenticated
  using (
    public.has_role_in(business_id, array['owner','admin']::member_role[])
    and user_id <> auth.uid()                          -- cannot edit your own role
  )
  with check (
    public.has_role_in(business_id, array['owner','admin']::member_role[])
    and (role <> 'owner' or public.has_role_in(business_id, array['owner']::member_role[]))
    and user_id <> auth.uid()
  );
create policy mem_delete on public.memberships
  for delete to authenticated
  using (
    public.has_role_in(business_id, array['owner','admin']::member_role[])
    and user_id <> auth.uid()                          -- cannot delete your own membership
  );

-- ── business_settings (1:1 tenant) ──  read any-role, write owner/admin/staff
create policy bset_select on public.business_settings
  for select to authenticated
  using (public.is_member_of(business_id));
create policy bset_insert on public.business_settings
  for insert to authenticated
  with check (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]));
create policy bset_update on public.business_settings
  for update to authenticated
  using (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]))
  with check (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]));
create policy bset_delete on public.business_settings
  for delete to authenticated
  using (public.has_role_in(business_id, array['owner','admin']::member_role[]));

-- ── products ──
create policy prod_select on public.products
  for select to authenticated using (public.is_member_of(business_id));
create policy prod_insert on public.products
  for insert to authenticated
  with check (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]));
create policy prod_update on public.products
  for update to authenticated
  using (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]))
  with check (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]));
create policy prod_delete on public.products
  for delete to authenticated
  using (public.has_role_in(business_id, array['owner','admin']::member_role[]));

-- ── price_refs ──  WITH CHECK verifies the PARENT product shares the tenant.
create policy pref_select on public.price_refs
  for select to authenticated using (public.is_member_of(business_id));
create policy pref_insert on public.price_refs
  for insert to authenticated
  with check (
    public.has_role_in(business_id, array['owner','admin','staff']::member_role[])
    and exists (select 1 from public.products p
                where p.id = product_id and p.business_id = price_refs.business_id)
  );
create policy pref_update on public.price_refs
  for update to authenticated
  using (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]))
  with check (
    public.has_role_in(business_id, array['owner','admin','staff']::member_role[])
    and exists (select 1 from public.products p
                where p.id = product_id and p.business_id = price_refs.business_id)
  );
create policy pref_delete on public.price_refs
  for delete to authenticated
  using (public.has_role_in(business_id, array['owner','admin']::member_role[]));

-- ── transactions ──  WITH CHECK verifies the PARENT product shares the tenant
-- (product_id is null only for general expenses).
create policy txn_select on public.transactions
  for select to authenticated using (public.is_member_of(business_id));
create policy txn_insert on public.transactions
  for insert to authenticated
  with check (
    public.has_role_in(business_id, array['owner','admin','staff']::member_role[])
    and (product_id is null
         or exists (select 1 from public.products p
                    where p.id = product_id and p.business_id = transactions.business_id))
  );
create policy txn_update on public.transactions
  for update to authenticated
  using (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]))
  with check (
    public.has_role_in(business_id, array['owner','admin','staff']::member_role[])
    and (product_id is null
         or exists (select 1 from public.products p
                    where p.id = product_id and p.business_id = transactions.business_id))
  );
create policy txn_delete on public.transactions
  for delete to authenticated
  using (public.has_role_in(business_id, array['owner','admin']::member_role[]));

-- ── invoices ──
create policy inv_select on public.invoices
  for select to authenticated using (public.is_member_of(business_id));
create policy inv_insert on public.invoices
  for insert to authenticated
  with check (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]));
create policy inv_update on public.invoices
  for update to authenticated
  using (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]))
  with check (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]));
create policy inv_delete on public.invoices
  for delete to authenticated
  using (public.has_role_in(business_id, array['owner','admin']::member_role[]));

-- ── invoice_items ──  WITH CHECK verifies the PARENT invoice shares the tenant;
-- this blocks re-parenting a child onto another tenant's invoice on INSERT+UPDATE.
create policy item_select on public.invoice_items
  for select to authenticated using (public.is_member_of(business_id));
create policy item_insert on public.invoice_items
  for insert to authenticated
  with check (
    public.has_role_in(business_id, array['owner','admin','staff']::member_role[])
    and exists (select 1 from public.invoices i
                where i.id = invoice_id and i.business_id = invoice_items.business_id)
  );
create policy item_update on public.invoice_items
  for update to authenticated
  using (public.has_role_in(business_id, array['owner','admin','staff']::member_role[]))
  with check (
    public.has_role_in(business_id, array['owner','admin','staff']::member_role[])
    and exists (select 1 from public.invoices i
                where i.id = invoice_id and i.business_id = invoice_items.business_id)
  );
create policy item_delete on public.invoice_items
  for delete to authenticated
  using (public.has_role_in(business_id, array['owner','admin']::member_role[]));

-- ── migration_imports ──  audit rows; owner-only read, owner-only write.
create policy mig_select on public.migration_imports
  for select to authenticated
  using (public.has_role_in(business_id, array['owner']::member_role[]));
create policy mig_insert on public.migration_imports
  for insert to authenticated
  with check (public.has_role_in(business_id, array['owner']::member_role[]));

-- ════════════════════════════════════════════════════════════════════════════
-- GRANTS
-- anon = ZERO table grants and ZERO function execute.
-- No permissive ALTER DEFAULT PRIVILEGES ... GRANT (removed the fail-open
-- time-bomb — tenant-leak M-1 / auth-bypass MEDIUM-4): every future table must
-- be granted explicitly in the migration that also enables its RLS.
-- ════════════════════════════════════════════════════════════════════════════

-- Strip everything from anon (tables + functions) and never grant it back.
revoke all on all tables    in schema public from anon;
revoke all on all functions in schema public from anon;

-- Default-deny EXECUTE on functions so no FUTURE function is anon/public-callable
-- (insert-forgery C2 / tenant-leak M-2). This must precede the explicit grants.
revoke execute on all functions in schema public from public, anon;
alter default privileges in schema public revoke execute on functions from public;

-- Explicit per-table DML to authenticated (RLS still filters every row).
grant select, insert, update, delete on
  public.memberships,
  public.business_settings,
  public.products,
  public.price_refs,
  public.transactions,
  public.invoices,
  public.invoice_items,
  public.migration_imports
  to authenticated;

-- profiles: SELECT + UPDATE only (no client INSERT/DELETE; the pin trigger keeps
-- email/id/migrated_at server-controlled — insert-forgery C1).
grant select, update on public.profiles to authenticated;

-- businesses: SELECT for all members; UPDATE restricted to the name COLUMN only
-- so businesses.data can be written EXCLUSIVELY through save_business_doc
-- (auth-bypass MEDIUM-1 / tenant-leak H-1). No direct INSERT/DELETE/data-UPDATE.
grant select          on public.businesses to authenticated;
grant update (name)   on public.businesses to authenticated;

-- business_settings: never expose pin_hash to the client — column-level revoke
-- so `select *` cannot exfiltrate it for offline cracking (insert-forgery M2).
revoke select (pin_hash) on public.business_settings from authenticated;
-- (Phase 2b: verify PINs via a SECURITY DEFINER verify_pin() RPC instead.)

-- Explicit EXECUTE grants — only these RPCs are callable, and only by authenticated.
grant execute on function public.provision_business(text)                        to authenticated;
grant execute on function public.save_business_doc(uuid, jsonb, timestamptz)      to authenticated;
grant execute on function public.next_invoice_number(uuid)                       to authenticated;
grant execute on function public.migrate_local_data(uuid, jsonb)                 to authenticated;
grant execute on function public.is_member_of(uuid)                              to authenticated;
grant execute on function public.has_role_in(uuid, member_role[])                to authenticated;
-- set_updated_at, pin_profile_columns, handle_new_user, guard_last_owner are
-- trigger-only and intentionally have NO execute grant (not REST-callable).

-- ════════════════════════════════════════════════════════════════════════════
-- POST-DEPLOY ASSERTION (run manually; must return ZERO rows)
-- Catches the FORCE-RLS / drift class (tenant-leak C-1, auth-bypass L1):
--   select c.relname
--     from pg_class c join pg_namespace n on n.oid = c.relnamespace
--    where n.nspname = 'public' and c.relkind = 'r'
--      and (not c.relrowsecurity or not c.relforcerowsecurity);
-- ════════════════════════════════════════════════════════════════════════════
