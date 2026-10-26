-- Accounts can be deleted from the app: deleting the auth user cascades to
-- every billing and analytics row of that account. A device keeps only its
-- random install ID and when its one-time free credit was claimed, so
-- deleting an account and signing up again does not claim it twice.
alter table billing_private.devices add column free_credit_claimed_at timestamptz;
update billing_private.devices set free_credit_claimed_at = now()
  where free_credit_user is not null;

create or replace function public.billing_touch(p_user uuid, p_anonymous boolean, p_device uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare amount bigint; claimed timestamptz;
begin
  insert into billing_private.accounts(user_id, is_anonymous) values(p_user, p_anonymous)
    on conflict(user_id) do update set is_anonymous = excluded.is_anonymous,
      last_seen_at = now();
  if p_device is null then return; end if;
  insert into billing_private.devices(device_id, user_id) values(p_device, p_user)
    on conflict(device_id) do update set user_id = excluded.user_id, last_seen_at = now();
  if p_anonymous or exists(select 1 from billing_private.grants
      where transaction_key = 'free:' || p_user) then
    return;
  end if;
  select free_credit_claimed_at into claimed from billing_private.devices
    where device_id = p_device for update;
  if claimed is not null then return; end if;
  select one_time_credit into amount from billing_private.plans where plan = 'free';
  insert into billing_private.grants(transaction_key, user_id, allowance, remaining, expires_at)
    values('free:' || p_user, p_user, amount, amount, now() + interval '1 month')
    on conflict do nothing;
  if found then
    update billing_private.devices
      set free_credit_user = p_user, free_credit_claimed_at = now()
      where device_id = p_device;
  end if;
end $$;
revoke all on function public.billing_touch(uuid,boolean,uuid) from public, anon, authenticated;
grant execute on function public.billing_touch(uuid,boolean,uuid) to service_role;
