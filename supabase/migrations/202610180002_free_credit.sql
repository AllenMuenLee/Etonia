-- A one-time $0.50 AI credit for free accounts. It is granted to a Google
-- (non-anonymous) account seen on a device, at most once per account and once
-- per device, never refills, and is used only while no paid plan is active.

alter table billing_private.plans add column one_time_credit bigint not null default 0
  check (one_time_credit >= 0);
update billing_private.plans set one_time_credit = 500000 where plan = 'free';

-- The account that claimed this device's free credit, if any.
alter table billing_private.devices add column free_credit_user uuid
  references billing_private.accounts on delete set null;

create or replace function public.billing_touch(p_user uuid, p_anonymous boolean, p_device uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare amount bigint; claimed uuid;
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
  select free_credit_user into claimed from billing_private.devices
    where device_id = p_device for update;
  if claimed is not null then return; end if;
  select one_time_credit into amount from billing_private.plans where plan = 'free';
  insert into billing_private.grants(transaction_key, user_id, allowance, remaining)
    values('free:' || p_user, p_user, amount, amount) on conflict do nothing;
  if found then
    update billing_private.devices set free_credit_user = p_user where device_id = p_device;
  end if;
end $$;

-- `activePlan` names a paid plan only. Without one, `plan` is `free` and the
-- balance is the free credit, if this account was granted it.
create or replace function public.billing_state(p_user uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object(
    'plan', p.plan, 'activePlan', p.plan, 'remainingCreditsMicroUsd', g.remaining,
    'expiresAt', s.expires_at, 'status', s.status, 'autoRenew', s.auto_renew,
    'grantedPurchaseId', s.transaction_key
  ) from billing_private.subscriptions s
    join billing_private.products p using(platform, product_id)
    join billing_private.grants g on g.transaction_key = s.transaction_key
    where s.user_id = p_user and s.active and s.expires_at > now()
    order by p.rank desc, s.expires_at desc, s.chain_key limit 1),
    (select jsonb_build_object('plan', 'free', 'activePlan', null,
      'remainingCreditsMicroUsd', g.remaining, 'freeCreditMicroUsd', g.allowance,
      'grantedPurchaseId', g.transaction_key)
     from billing_private.grants g where g.transaction_key = 'free:' || p_user),
    '{"plan":"free","activePlan":null,"remainingCreditsMicroUsd":0}'::jsonb)
$$;

create or replace function public.ai_reserve(p_user uuid, p_request uuid, p_model text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; balance bigint; held bigint; n int; free boolean;
begin
  perform public.billing_lock(p_user);
  if exists(select 1 from billing_private.requests where request_id = p_request) then
    raise exception 'request_in_progress';
  end if;
  if exists(select 1 from billing_private.requests where user_id = p_user and status = 'pending') then
    raise exception 'request_in_progress';
  end if;
  select count(*) into n from billing_private.requests
    where user_id = p_user and created_at > now() - interval '24 hours';
  if n >= 300 then raise exception 'rate_limited'; end if;
  if p_model not in ('haiku','luna','sonnet','sol','opus','argon','astra') then raise exception 'rejected'; end if;
  state := public.billing_state(p_user);
  free := state->>'activePlan' is null;
  if free and state->>'grantedPurchaseId' is null then raise exception 'plan_required'; end if;
  if (free or state->>'activePlan' = 'starter499') and p_model in ('opus','argon','astra') then
    raise exception 'plan_required';
  end if;
  grant_key := state->>'grantedPurchaseId';
  select remaining into balance from billing_private.grants where transaction_key = grant_key for update;
  -- Haiku and Luna are unlimited on paid plans; the free credit pays for them.
  held := case when not free and p_model in ('haiku', 'luna') then 0 else balance end;
  if held = 0 and (free or p_model not in ('haiku', 'luna')) then
    raise exception 'insufficient_credits';
  end if;
  update billing_private.grants set remaining = remaining - held where transaction_key = grant_key;
  insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,status)
    values(p_request,p_user,grant_key,p_model,held,'pending');
  return jsonb_build_object('reserved', held, 'unlimited', held = 0);
end $$;

revoke all on function public.billing_touch(uuid,boolean,uuid) from public, anon, authenticated;
revoke all on function public.billing_state(uuid) from public, anon, authenticated;
revoke all on function public.ai_reserve(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.billing_touch(uuid,boolean,uuid), public.billing_state(uuid),
  public.ai_reserve(uuid,uuid,text) to service_role;
