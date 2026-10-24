-- Gift codes, and a one-month life for all free credit. A code is redeemed by a
-- Google (non-anonymous) account, at most once per account per code, and adds
-- its credit (default $3) to the account's free credit. Free credit is used
-- only while no paid plan is active, and every grant of it, the one-time $0.50
-- or a gift, expires one month after it is granted. Redeeming a gift while
-- earlier free credit remains restarts the month for the whole balance.

alter table billing_private.grants add column expires_at timestamptz;
update billing_private.grants set expires_at = created_at + interval '1 month'
  where transaction_key like 'free:%';

create table billing_private.gift_codes (
  code text primary key check (code = upper(btrim(code)) and length(code) >= 6),
  credit bigint not null default 3000000 check (credit > 0),
  max_redemptions int check (max_redemptions > 0),
  expires_at timestamptz,
  created_at timestamptz not null default now()
);
create table billing_private.gift_redemptions (
  code text not null references billing_private.gift_codes on delete cascade,
  user_id uuid not null references billing_private.accounts on delete cascade,
  redeemed_at timestamptz not null default now(),
  primary key(code, user_id)
);
alter table billing_private.gift_codes enable row level security;
alter table billing_private.gift_redemptions enable row level security;
revoke all on billing_private.gift_codes, billing_private.gift_redemptions
  from public, anon, authenticated;

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
  insert into billing_private.grants(transaction_key, user_id, allowance, remaining, expires_at)
    values('free:' || p_user, p_user, amount, amount, now() + interval '1 month')
    on conflict do nothing;
  if found then
    update billing_private.devices set free_credit_user = p_user where device_id = p_device;
  end if;
end $$;

-- Free credit past its month counts as none; `freeCreditExpiresAt` tells the
-- app when it ends.
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
      'remainingCreditsMicroUsd',
        case when g.expires_at is null or g.expires_at > now() then g.remaining else 0 end,
      'freeCreditMicroUsd', g.allowance, 'freeCreditExpiresAt', g.expires_at,
      'grantedPurchaseId', g.transaction_key)
     from billing_private.grants g where g.transaction_key = 'free:' || p_user),
    '{"plan":"free","activePlan":null,"remainingCreditsMicroUsd":0}'::jsonb)
$$;

create or replace function public.ai_reserve(p_user uuid, p_request uuid, p_model text,
  p_max bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; balance bigint; held bigint; n int; free boolean;
begin
  perform public.billing_lock(p_user);
  if exists(select 1 from billing_private.requests where request_id = p_request) then
    raise exception 'request_in_progress';
  end if;
  select count(*) into n from billing_private.requests
    where user_id = p_user and status = 'pending' and created_at > now() - interval '10 minutes';
  if n >= 4 then raise exception 'request_in_progress'; end if;
  select count(*) into n from billing_private.requests
    where user_id = p_user and created_at > now() - interval '24 hours';
  if n >= 300 then raise exception 'rate_limited'; end if;
  if p_model not in ('haiku','luna','sonnet','sol','opus','argon','astra') then raise exception 'rejected'; end if;
  if p_max is not null and p_max <= 0 then raise exception 'rejected'; end if;
  state := public.billing_state(p_user);
  free := state->>'activePlan' is null;
  if free and state->>'grantedPurchaseId' is null then raise exception 'plan_required'; end if;
  if (free or state->>'activePlan' = 'starter499') and p_model in ('opus','argon','astra') then
    raise exception 'plan_required';
  end if;
  grant_key := state->>'grantedPurchaseId';
  select case when expires_at is not null and expires_at <= now() then 0 else remaining end
    into balance from billing_private.grants where transaction_key = grant_key for update;
  -- Haiku and Luna are unlimited on paid plans; the free credit pays for them.
  held := case when not free and p_model in ('haiku', 'luna') then 0
    else least(balance, coalesce(p_max, balance)) end;
  if held = 0 and (free or p_model not in ('haiku', 'luna')) then
    raise exception 'insufficient_credits';
  end if;
  update billing_private.grants set remaining = remaining - held where transaction_key = grant_key;
  insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,status)
    values(p_request,p_user,grant_key,p_model,held,'pending');
  return jsonb_build_object('reserved', held, 'unlimited', held = 0);
end $$;

-- Adds a gift code's credit to the account's free credit and returns its new
-- state. Raises invalid_code, code_redeemed, code_exhausted or unauthorized.
create function public.billing_redeem_gift(p_user uuid, p_anonymous boolean, p_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare gift billing_private.gift_codes; normalized text := upper(btrim(coalesce(p_code, '')));
begin
  if p_anonymous then raise exception 'unauthorized'; end if;
  perform public.billing_lock(p_user);
  select * into gift from billing_private.gift_codes where code = normalized for update;
  if not found or (gift.expires_at is not null and gift.expires_at <= now()) then
    raise exception 'invalid_code';
  end if;
  if exists(select 1 from billing_private.gift_redemptions
      where code = gift.code and user_id = p_user) then
    raise exception 'code_redeemed';
  end if;
  if gift.max_redemptions is not null and
      (select count(*) from billing_private.gift_redemptions where code = gift.code)
        >= gift.max_redemptions then
    raise exception 'code_exhausted';
  end if;
  insert into billing_private.gift_redemptions(code, user_id) values(gift.code, p_user);
  -- The right-hand sides read the row as it was, so "expired" is judged before
  -- the new month is written.
  update billing_private.grants set
    allowance = case when expires_at is not null and expires_at <= now()
      then gift.credit else allowance + gift.credit end,
    remaining = case when expires_at is not null and expires_at <= now()
      then 0 else remaining end + gift.credit,
    expires_at = now() + interval '1 month'
    where transaction_key = 'free:' || p_user;
  if not found then
    insert into billing_private.grants(transaction_key, user_id, allowance, remaining, expires_at)
      values('free:' || p_user, p_user, gift.credit, gift.credit, now() + interval '1 month');
  end if;
  return public.billing_state(p_user);
end $$;

revoke all on function public.billing_touch(uuid,boolean,uuid) from public, anon, authenticated;
revoke all on function public.billing_state(uuid) from public, anon, authenticated;
revoke all on function public.ai_reserve(uuid,uuid,text,bigint) from public, anon, authenticated;
revoke all on function public.billing_redeem_gift(uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.billing_touch(uuid,boolean,uuid), public.billing_state(uuid),
  public.ai_reserve(uuid,uuid,text,bigint), public.billing_redeem_gift(uuid,boolean,text)
  to service_role;
