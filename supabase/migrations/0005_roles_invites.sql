-- 0005 — Optional multi-user ROLES: email invites + member management.
--
-- Backend already had member_role (owner/admin/staff/viewer), memberships, has_role_in,
-- role-gated write RPCs and RLS. This adds the invite plumbing + management RPCs.
-- ALL casts schema-qualified as ::public.member_role[] (search_path='' functions) — never
-- a bare ::member_role[] (that caused the 0002 outage).

-- ── pending invites (email-based; consumed when that email next signs in) ──
create table if not exists public.pending_invites (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  email       text not null,
  role        public.member_role not null default 'staff',
  invited_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  unique (business_id, email)
);
create index if not exists idx_pending_invites_email on public.pending_invites(lower(email));

alter table public.pending_invites enable row level security;
alter table public.pending_invites force  row level security;

-- Owner/admin of the business may VIEW its pending invites; all writes go through RPCs.
drop policy if exists pending_invites_select on public.pending_invites;
create policy pending_invites_select on public.pending_invites
  for select using (public.has_role_in(business_id, array['owner','admin']::public.member_role[]));
revoke insert, update, delete on public.pending_invites from authenticated;

-- ── invite a member (owner/admin only) ──
create or replace function public.invite_member(p_business_id uuid, p_email text, p_role public.member_role)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if p_role = 'owner' then raise exception 'cannot invite someone as owner'; end if;
  insert into public.pending_invites (business_id, email, role, invited_by)
  values (p_business_id, lower(trim(p_email)), p_role, auth.uid())
  on conflict (business_id, email) do update set role = excluded.role, invited_by = excluded.invited_by;
end $$;

-- ── accept any invites matching the caller's email → create the memberships ──
create or replace function public.accept_my_invites()
returns int language plpgsql security definer set search_path = '' as $$
declare v_email text := lower(auth.jwt() ->> 'email'); n int := 0;
begin
  if v_email is null or v_email = '' then return 0; end if;
  insert into public.memberships (business_id, user_id, role, invited_by)
  select pi.business_id, auth.uid(), pi.role, pi.invited_by
  from public.pending_invites pi
  where lower(pi.email) = v_email
  on conflict (business_id, user_id) do nothing;
  get diagnostics n = row_count;
  delete from public.pending_invites where lower(email) = v_email;
  return n;
end $$;

-- ── change a member's role (owner/admin; never the owner, never TO owner) ──
create or replace function public.set_member_role(p_business_id uuid, p_user_id uuid, p_role public.member_role)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if p_role = 'owner' then raise exception 'cannot assign owner'; end if;
  if exists (select 1 from public.memberships where business_id = p_business_id and user_id = p_user_id and role = 'owner') then
    raise exception 'cannot change the owner''s role';
  end if;
  update public.memberships set role = p_role where business_id = p_business_id and user_id = p_user_id;
end $$;

-- ── remove a member (owner/admin; never the owner) ──
create or replace function public.remove_member(p_business_id uuid, p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  if exists (select 1 from public.memberships where business_id = p_business_id and user_id = p_user_id and role = 'owner') then
    raise exception 'cannot remove the owner';
  end if;
  delete from public.memberships where business_id = p_business_id and user_id = p_user_id;
end $$;

-- ── list members with emails (owner/admin only) ──
create or replace function public.list_members(p_business_id uuid)
returns table(user_id uuid, email text, role public.member_role, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return query
    select m.user_id, u.email::text, m.role, m.created_at
    from public.memberships m
    join auth.users u on u.id = m.user_id
    where m.business_id = p_business_id
    order by (m.role = 'owner') desc, m.created_at asc;
end $$;

-- ── cancel a pending invite (owner/admin only) ──
create or replace function public.cancel_invite(p_business_id uuid, p_email text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.has_role_in(p_business_id, array['owner','admin']::public.member_role[]) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  delete from public.pending_invites where business_id = p_business_id and lower(email) = lower(trim(p_email));
end $$;

grant execute on function public.cancel_invite(uuid, text)                       to authenticated;
grant execute on function public.invite_member(uuid, text, public.member_role)  to authenticated;
grant execute on function public.accept_my_invites()                            to authenticated;
grant execute on function public.set_member_role(uuid, uuid, public.member_role) to authenticated;
grant execute on function public.remove_member(uuid, uuid)                       to authenticated;
grant execute on function public.list_members(uuid)                             to authenticated;
