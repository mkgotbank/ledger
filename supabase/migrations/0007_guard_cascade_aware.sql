-- 0007 — guard_last_owner: stand down during business deletion.
--
-- The guard blocked the FK CASCADE that removes memberships when a business row is
-- deleted ("cannot remove the last owner") — making businesses undeletable once they
-- had exactly one owner. PostgreSQL runs the cascade AFTER the parent row is gone, so
-- the fix: if the business row no longer exists, there is nothing left to protect —
-- allow the removal. Direct membership deletes (business still present) stay guarded.

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
    -- Business row already deleted → this is the CASCADE of a business deletion.
    if not exists (select 1 from public.businesses where id = v_biz) then
      if tg_op = 'DELETE' then return old; end if;
      return new;
    end if;
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
