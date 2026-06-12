-- 0008 — stale_write must SURFACE to the client, not time out.
--
-- save_business_doc raised stale conflicts with errcode 40001 (serialization_failure),
-- the standard "safe to retry" class — so the API layer retried the doomed write until
-- the gateway returned "upstream request timeout". The client's conflict recovery keys
-- off seeing 'stale_write' in the error message, so multi-device conflict merges never
-- triggered; conflicts degraded into timeouts. Same body, non-retryable errcode.

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
    raise exception 'stale_write' using errcode = 'P0001';  -- non-retryable: client re-hydrates & merges
  end if;
  return v;
end $$;
