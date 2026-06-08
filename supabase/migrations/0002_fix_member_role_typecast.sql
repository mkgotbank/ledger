-- 0002 — FIX: write functions error with `type "member_role" does not exist`.
--
-- save_business_doc / next_invoice_number / migrate_local_data run with
-- `set search_path = ''` (security hardening) but cast to the enum UNqualified
-- (`::member_role[]`). Under an empty search_path the type can't be resolved, so
-- EVERY cloud write raised "type member_role does not exist" and silently failed —
-- data only ever lived on-device. Fix: schema-qualify the type as
-- `public.member_role[]`. Reads (RLS via is_member_of) were unaffected, which is
-- why data loaded but never saved. Idempotent: safe to run on any environment.

create or replace function public.save_business_doc(p_id uuid, p_data jsonb, p_base timestamptz)
returns timestamptz
language plpgsql security definer
set search_path = ''
as $$
declare v timestamptz;
begin
  if not public.has_role_in(p_id, array['owner','admin','staff']::public.member_role[]) then
    raise exception 'no write access to business %', p_id using errcode = '42501';
  end if;
  update public.businesses
     set data = p_data, updated_at = now()
   where id = p_id and (p_base is null or updated_at = p_base)
   returning updated_at into v;
  if v is null then
    raise exception 'stale_write' using errcode = '40001';
  end if;
  return v;
end $$;

create or replace function public.next_invoice_number(b uuid)
returns integer
language plpgsql security definer
set search_path = ''
as $$
declare n integer;
begin
  if not public.has_role_in(b, array['owner','admin','staff']::public.member_role[]) then
    raise exception 'no write access to business %', b using errcode = '42501';
  end if;
  update public.business_settings
     set invoice_next = invoice_next + 1, updated_at = now()
   where business_id = b
   returning invoice_next - 1 into n;
  if n is null then raise exception 'no settings row for business %', b; end if;
  return n;
end $$;

create or replace function public.migrate_local_data(p_business_id uuid, p_d jsonb)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid(); v_migrated timestamptz;
begin
  if not public.has_role_in(p_business_id, array['owner']::public.member_role[]) then
    raise exception 'Not authorized for business %', p_business_id using errcode = '42501';
  end if;
  select migrated_at into v_migrated
  from public.businesses
  where id = p_business_id
  for update;
  if v_migrated is not null then
    raise exception 'Business already migrated';
  end if;
  update public.businesses
     set data = p_d,
         name = coalesce(nullif(p_d->'business'->>'name', ''), name),
         migrated_at = now()
   where id = p_business_id;
  insert into public.migration_imports (business_id, user_id, source, raw_payload)
  values (p_business_id, v_uid, 'localStorage_D', p_d)
  on conflict (business_id, source) do nothing;
end $$;
