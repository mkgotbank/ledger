-- 0004 — CLOUD BACKUPS: keep the last ~7 snapshots of each business's data server-side,
-- in addition to the on-device rolling backups, so data can be restored on any device.
--
-- All enum casts are schema-qualified as ::public.member_role[] (search_path='' functions),
-- per the 0002 fix — never use a bare ::member_role[].

create table if not exists public.business_backups (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id) on delete cascade,
  created_at   timestamptz not null default now(),
  data         jsonb not null
);
create index if not exists idx_business_backups_biz
  on public.business_backups(business_id, created_at desc);

alter table public.business_backups enable row level security;
alter table public.business_backups force  row level security;

-- Members of the business may READ its backups (any role).
drop policy if exists business_backups_select on public.business_backups;
create policy business_backups_select on public.business_backups
  for select using (public.is_member_of(business_id));

-- Direct writes are revoked — snapshots go ONLY through the role-gated RPC below.
revoke insert, update, delete on public.business_backups from authenticated;

-- save_business_backup: insert a snapshot, then prune to the newest 7 for that business.
create or replace function public.save_business_backup(p_business_id uuid, p_data jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin','staff']::public.member_role[]) then
    raise exception 'no write access to business %', p_business_id using errcode = '42501';
  end if;
  insert into public.business_backups (business_id, data) values (p_business_id, p_data);
  delete from public.business_backups
   where business_id = p_business_id
     and id not in (
       select id from public.business_backups
       where business_id = p_business_id
       order by created_at desc
       limit 7
     );
end $$;

grant execute on function public.save_business_backup(uuid, jsonb) to authenticated;
