-- Billing metadata only. No note, PDF, prompt, response or conversation columns.
create schema if not exists billing_private;
revoke all on schema billing_private from public, anon, authenticated;

create table billing_private.accounts (
  user_id uuid primary key references auth.users(id) on delete cascade
);
create table billing_private.products (
  platform text not null check (platform in ('app_store', 'google_play')),
  product_id text not null,
  plan text not null check (plan in ('starter499', 'pro1299', 'max2999')),
  rank int not null,
  allowance bigint not null check (allowance > 0),
  primary key(platform, product_id)
);
insert into billing_private.products values
 ('app_store', 'com.etonia.app.plan.499.monthly', 'starter499', 1, 1200000),
 ('app_store', 'com.etonia.app.plan.1299.monthly', 'pro1299', 2, 5000000),
 ('app_store', 'com.etonia.app.plan.2999.monthly', 'max2999', 3, 15000000),
 ('app_store', 'com.etonia.app.plan.499.yearly', 'starter499', 1, 14400000),
 ('app_store', 'com.etonia.app.plan.1299.yearly', 'pro1299', 2, 60000000),
 ('app_store', 'com.etonia.app.plan.2999.yearly', 'max2999', 3, 180000000),
 ('google_play', 'etonia_plan_499_monthly', 'starter499', 1, 1200000),
 ('google_play', 'etonia_plan_1299_monthly', 'pro1299', 2, 5000000),
 ('google_play', 'etonia_plan_2999_monthly', 'max2999', 3, 15000000),
 ('google_play', 'etonia_plan_499_yearly', 'starter499', 1, 14400000),
 ('google_play', 'etonia_plan_1299_yearly', 'pro1299', 2, 60000000),
 ('google_play', 'etonia_plan_2999_yearly', 'max2999', 3, 180000000);

create table billing_private.subscriptions (
  chain_key text primary key,
  user_id uuid not null references billing_private.accounts on delete cascade,
  platform text not null,
  product_id text not null,
  locator_ciphertext text not null,
  transaction_key text not null,
  expires_at timestamptz not null,
  active boolean not null,
  status text not null,
  auto_renew boolean not null,
  verified_at timestamptz not null,
  foreign key(platform, product_id) references billing_private.products
);
create index on billing_private.subscriptions(user_id);
create table billing_private.subscription_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references billing_private.accounts on delete cascade,
  chain_key text not null,
  transaction_key text not null,
  platform text not null,
  product_id text not null,
  status text not null,
  active boolean not null,
  auto_renew boolean not null,
  expires_at timestamptz not null,
  observed_at timestamptz not null
);
create index on billing_private.subscription_events(user_id, observed_at);
create table billing_private.grants (
  transaction_key text primary key,
  user_id uuid not null references billing_private.accounts on delete cascade,
  allowance bigint not null check(allowance >= 0),
  remaining bigint not null check(remaining >= 0),
  created_at timestamptz not null default now()
);
create table billing_private.requests (
  request_id uuid primary key,
  user_id uuid not null references billing_private.accounts on delete cascade,
  transaction_key text not null references billing_private.grants,
  model text not null,
  reserved bigint not null check(reserved >= 0),
  charged bigint,
  provider_cost bigint,
  input_tokens int,
  output_tokens int,
  status text not null check(status in ('pending', 'settled', 'released')),
  created_at timestamptz not null default now()
);
create index on billing_private.requests(user_id, created_at);
create table billing_private.rate_buckets (
  user_id uuid not null references auth.users(id) on delete cascade,
  bucket timestamptz not null,
  hits int not null,
  primary key(user_id, bucket)
);

-- Defense in depth: private schema is not exposed through the Data API, and no
-- client role has table privileges or RLS policies granting access.
alter table billing_private.accounts enable row level security;
alter table billing_private.products enable row level security;
alter table billing_private.subscriptions enable row level security;
alter table billing_private.subscription_events enable row level security;
alter table billing_private.grants enable row level security;
alter table billing_private.requests enable row level security;
alter table billing_private.rate_buckets enable row level security;
revoke all on all tables in schema billing_private from public, anon, authenticated;

create function public.billing_lock(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into billing_private.accounts values(p_user) on conflict do nothing;
  perform 1 from billing_private.accounts where user_id = p_user for update;
end $$;

create function public.billing_rate_limit(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into billing_private.rate_buckets values(p_user, date_trunc('minute', now()), 1)
    on conflict(user_id, bucket) do update set hits = billing_private.rate_buckets.hits + 1
    returning hits into n;
  if n > 30 then raise exception 'rate_limited'; end if;
  delete from billing_private.rate_buckets where user_id = p_user and bucket < now() - interval '1 hour';
end $$;

create function public.billing_apply(p_user uuid, p_snapshot jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare product billing_private.products; owner uuid; changed int; previous billing_private.subscriptions;
begin
  perform public.billing_lock(p_user);
  select * into strict product from billing_private.products
    where platform = p_snapshot->>'platform' and product_id = p_snapshot->>'productId';
  select user_id into owner from billing_private.subscriptions where chain_key = p_snapshot->>'chainKey';
  if owner is not null and owner <> p_user then raise exception 'purchase_owner'; end if;
  select * into previous from billing_private.subscriptions where chain_key = p_snapshot->>'chainKey';
  select user_id into owner from billing_private.grants where transaction_key = p_snapshot->>'transactionKey';
  if owner is not null and owner <> p_user then raise exception 'purchase_owner'; end if;
  insert into billing_private.subscriptions values(
    p_snapshot->>'chainKey', p_user, product.platform, product.product_id,
    p_snapshot->>'locatorCiphertext', p_snapshot->>'transactionKey',
    (p_snapshot->>'expiresAt')::timestamptz, (p_snapshot->>'active')::boolean,
    p_snapshot->>'status', (p_snapshot->>'autoRenew')::boolean,
    (p_snapshot->>'observedAt')::timestamptz
  ) on conflict(chain_key) do update set
    product_id = excluded.product_id, locator_ciphertext = excluded.locator_ciphertext,
    transaction_key = excluded.transaction_key, expires_at = excluded.expires_at,
    active = excluded.active, status = excluded.status, auto_renew = excluded.auto_renew,
    verified_at = excluded.verified_at
    where billing_private.subscriptions.user_id = p_user
      and billing_private.subscriptions.verified_at <= excluded.verified_at;
  get diagnostics changed = row_count;
  if changed > 0 and (previous.chain_key is null or
      row(previous.transaction_key, previous.product_id, previous.status, previous.active,
          previous.auto_renew, previous.expires_at) is distinct from
      row(p_snapshot->>'transactionKey', product.product_id, p_snapshot->>'status',
          (p_snapshot->>'active')::boolean, (p_snapshot->>'autoRenew')::boolean,
          (p_snapshot->>'expiresAt')::timestamptz)) then
    insert into billing_private.subscription_events(user_id, chain_key, transaction_key,
      platform, product_id, status, active, auto_renew, expires_at, observed_at)
    values(p_user, p_snapshot->>'chainKey', p_snapshot->>'transactionKey', product.platform,
      product.product_id, p_snapshot->>'status', (p_snapshot->>'active')::boolean,
      (p_snapshot->>'autoRenew')::boolean, (p_snapshot->>'expiresAt')::timestamptz,
      (p_snapshot->>'observedAt')::timestamptz);
  end if;
  if changed > 0 and (p_snapshot->>'active')::boolean and
      (p_snapshot->>'expiresAt')::timestamptz > now() then
    insert into billing_private.grants(transaction_key, user_id, allowance, remaining)
      values(p_snapshot->>'transactionKey', p_user, product.allowance, product.allowance)
      on conflict do nothing; -- A renewal transaction can grant credits only once.
  end if;
end $$;

create function public.billing_state(p_user uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object(
    'activePlan', p.plan, 'remainingCreditsMicroUsd', g.remaining,
    'expiresAt', s.expires_at, 'status', s.status, 'autoRenew', s.auto_renew,
    'grantedPurchaseId', s.transaction_key
  ) from billing_private.subscriptions s
    join billing_private.products p using(platform, product_id)
    join billing_private.grants g on g.transaction_key = s.transaction_key
    where s.user_id = p_user and s.active and s.expires_at > now()
    order by p.rank desc, s.expires_at desc, s.chain_key limit 1),
    '{"activePlan":null,"remainingCreditsMicroUsd":0}'::jsonb)
$$;

create function public.billing_locators(p_user uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('platform', platform,
    'locatorCiphertext', locator_ciphertext)), '[]'::jsonb)
  from billing_private.subscriptions where user_id = p_user
    and expires_at > now() - interval '55 days'
$$;

create function public.billing_owner(p_chain text) returns uuid
language sql security definer set search_path = '' as $$
  select user_id from billing_private.subscriptions where chain_key = p_chain
$$;

create function public.ai_reserve(p_user uuid, p_request uuid, p_model text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; balance bigint; held bigint; n int;
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
  state := public.billing_state(p_user);
  if state->>'activePlan' is null then raise exception 'plan_required'; end if;
  if p_model not in ('haiku','luna','sonnet','sol','opus','argon','astra') then raise exception 'rejected'; end if;
  if state->>'activePlan' = 'starter499' and p_model in ('opus','argon','astra') then
    raise exception 'plan_required';
  end if;
  grant_key := state->>'grantedPurchaseId';
  select remaining into balance from billing_private.grants where transaction_key = grant_key for update;
  held := case when p_model in ('haiku', 'luna') then 0 else balance end;
  if held = 0 and p_model not in ('haiku', 'luna') then raise exception 'insufficient_credits'; end if;
  update billing_private.grants set remaining = remaining - held where transaction_key = grant_key;
  insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,status)
    values(p_request,p_user,grant_key,p_model,held,'pending');
  return jsonb_build_object('reserved', held, 'unlimited', p_model in ('haiku','luna'));
end $$;

create function public.ai_settle(p_user uuid, p_request uuid, p_cost bigint,
  p_input int, p_output int, p_release boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare r billing_private.requests; charge_amount bigint;
begin
  perform public.billing_lock(p_user);
  select * into strict r from billing_private.requests
    where request_id = p_request and user_id = p_user for update;
  if r.status <> 'pending' then return; end if;
  if p_cost < 0 or p_input < 0 or p_output < 0 then raise exception 'rejected'; end if;
  charge_amount := case when p_release then 0 else least(p_cost, r.reserved) end;
  update billing_private.grants set remaining = remaining + r.reserved - charge_amount
    where transaction_key = r.transaction_key;
  update billing_private.requests set charged = charge_amount, provider_cost = p_cost, input_tokens = p_input,
    output_tokens = p_output, status = case when p_release then 'released' else 'settled' end
    where request_id = p_request;
end $$;

-- PostgreSQL grants EXECUTE to PUBLIC by default: explicitly close every RPC.
revoke all on function public.billing_lock(uuid) from public, anon, authenticated;
revoke all on function public.billing_rate_limit(uuid) from public, anon, authenticated;
revoke all on function public.billing_apply(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.billing_state(uuid) from public, anon, authenticated;
revoke all on function public.billing_locators(uuid) from public, anon, authenticated;
revoke all on function public.billing_owner(text) from public, anon, authenticated;
revoke all on function public.ai_reserve(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.ai_settle(uuid,uuid,bigint,int,int,boolean) from public, anon, authenticated;
grant execute on function public.billing_lock(uuid), public.billing_rate_limit(uuid),
  public.billing_apply(uuid,jsonb), public.billing_state(uuid), public.billing_locators(uuid),
  public.billing_owner(text), public.ai_reserve(uuid,uuid,text),
  public.ai_settle(uuid,uuid,bigint,int,int,boolean) to service_role;
