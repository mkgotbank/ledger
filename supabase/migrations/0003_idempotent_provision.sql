-- 0003 — make provision_business IDEMPOTENT.
--
-- The original always INSERTed a new business, so a momentarily-empty membership read
-- (replica lag / transient RLS gap) could create a DUPLICATE empty business and strand the
-- user on it. Now: if the caller already owns a business, return that one instead of
-- creating another. Combined with the client preferring the business that has data, this
-- ends the "data comes and goes" behaviour and prevents new duplicates.

create or replace function public.provision_business(p_name text default 'My Business')
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare bid uuid; v_uid uuid := auth.uid(); v_name text;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '42501'; end if;

  -- Idempotent guard: reuse the caller's existing (oldest) owned business if one exists.
  select m.business_id into bid
  from public.memberships m
  where m.user_id = v_uid and m.role = 'owner'
  order by m.created_at asc
  limit 1;
  if bid is not null then return bid; end if;

  v_name := coalesce(nullif(trim(p_name), ''), 'My Business');
  insert into public.businesses (owner_id, name) values (v_uid, v_name) returning id into bid;
  insert into public.memberships (business_id, user_id, role) values (bid, v_uid, 'owner');
  insert into public.business_settings (business_id, name) values (bid, v_name);
  return bid;
end $$;
