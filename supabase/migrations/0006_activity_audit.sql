-- 0006 — Tamper-proof activity audit log (Option A, Stage 1).
--
-- ADDITIVE ONLY: this creates a brand-new table + function. It does NOT read, modify, or
-- delete businesses.data or any existing data — so it cannot affect current users' logs.
--
-- The author of each event is stamped by the DATABASE from the verified JWT (auth.uid()),
-- which a client cannot forge — that's what makes it tamper-proof, unlike the in-document
-- 'by' field (which the app sets and a determined user could edit).
-- All enum casts schema-qualified as ::public.member_role[] (search_path='' functions).

create table if not exists public.activity_events (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  actor        uuid references auth.users(id) on delete set null,  -- REAL author (server-set); null = legacy/import
  actor_label  text,                                               -- denormalized email for display
  type         text not null,                                      -- 'sale' | 'restock' | 'use' | 'expense' | ...
  summary      jsonb not null default '{}'::jsonb,                 -- entry details (amount, product, qty, note…)
  client_id    text,                                               -- the in-app log entry id (link / de-dupe)
  source       text not null default 'live',                       -- 'live' (server-stamped) | 'import' (backfill)
  created_at   timestamptz not null default now()
);
create index if not exists idx_activity_events_biz on public.activity_events(business_id, created_at desc);

alter table public.activity_events enable row level security;
alter table public.activity_events force  row level security;

-- Any member may READ their business's audit log; inserts go only through the RPCs below.
drop policy if exists activity_events_select on public.activity_events;
create policy activity_events_select on public.activity_events
  for select using (public.is_member_of(business_id));
revoke insert, update, delete on public.activity_events from authenticated;

-- log_activity: author is auth.uid() — stamped server-side, un-fakeable. Used for new (live) events.
create or replace function public.log_activity(p_business_id uuid, p_type text, p_summary jsonb, p_client_id text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin','staff']::public.member_role[]) then
    raise exception 'no write access to business %', p_business_id using errcode = '42501';
  end if;
  -- de-dupe: skip if this client_id was already recorded for this business
  if p_client_id is not null and exists (
       select 1 from public.activity_events where business_id = p_business_id and client_id = p_client_id and source = 'live'
     ) then return; end if;
  insert into public.activity_events (business_id, actor, actor_label, type, summary, client_id, source)
  values (p_business_id, auth.uid(), coalesce(nullif(lower(auth.jwt() ->> 'email'), ''), 'member'),
          p_type, coalesce(p_summary, '{}'::jsonb), p_client_id, 'live');
end $$;

grant execute on function public.log_activity(uuid, text, jsonb, text) to authenticated;

-- import_activity: one-time backfill of existing in-document logs, marked 'import' (historical,
-- NOT server-verified — shown as such in the UI). Owner/admin only. De-dupes on client_id.
create or replace function public.import_activity(p_business_id uuid, p_events jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare n int := 0;
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  insert into public.activity_events (business_id, actor, actor_label, type, summary, client_id, source, created_at)
  select p_business_id, null, nullif(e->>'by',''), coalesce(e->>'type','entry'),
         coalesce(e->'summary','{}'::jsonb), e->>'client_id', 'import',
         coalesce((e->>'at')::timestamptz, now())
  from jsonb_array_elements(p_events) e
  where (e->>'client_id') is not null
    and not exists (select 1 from public.activity_events a
                    where a.business_id = p_business_id and a.client_id = e->>'client_id');
  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function public.import_activity(uuid, jsonb) to authenticated;
