-- Every account is listed with a plan, including the free plan, and every
-- device that has called the API is remembered, even before Google sign-in.
-- Device rows hold only a random app-generated ID, never hardware identifiers.

create table billing_private.plans (
  plan text primary key,
  rank int not null unique,
  title text not null,
  monthly_price_cents int not null check (monthly_price_cents >= 0)
);
insert into billing_private.plans values
 ('free', 0, 'Free', 0),
 ('starter499', 1, 'Starter', 499),
 ('pro1299', 2, 'Pro', 1299),
 ('max2999', 3, 'Max', 2999);

-- Store products map to paid plans only; the free plan has no product.
alter table billing_private.products drop constraint products_plan_check;
alter table billing_private.products
  add constraint products_plan_fkey foreign key (plan) references billing_private.plans,
  add constraint products_paid_plan check (plan <> 'free');

alter table billing_private.accounts
  add column is_anonymous boolean not null default false,
  add column created_at timestamptz not null default now(),
  add column last_seen_at timestamptz not null default now();

create table billing_private.devices (
  device_id uuid primary key,
  -- The account last seen on this device: anonymous until Google sign-in.
  user_id uuid references billing_private.accounts on delete set null,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index on billing_private.devices(user_id);

alter table billing_private.plans enable row level security;
alter table billing_private.devices enable row level security;
revoke all on billing_private.plans, billing_private.devices from public, anon, authenticated;

create function public.billing_touch(p_user uuid, p_anonymous boolean, p_device uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into billing_private.accounts(user_id, is_anonymous) values(p_user, p_anonymous)
    on conflict(user_id) do update set is_anonymous = excluded.is_anonymous,
      last_seen_at = now();
  if p_device is not null then
    insert into billing_private.devices(device_id, user_id) values(p_device, p_user)
      on conflict(device_id) do update set user_id = excluded.user_id, last_seen_at = now();
  end if;
end $$;

-- Same entitlement as before, plus `plan`, which is `free` without an active
-- paid subscription. `activePlan` stays null then, so free never unlocks AI.
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
    '{"plan":"free","activePlan":null,"remainingCreditsMicroUsd":0}'::jsonb)
$$;

-- For the dashboard: every account with its current plan (free included).
create view billing_private.account_plans with (security_invoker = true) as
  select a.user_id, a.is_anonymous, coalesce(cur.plan, 'free') as plan,
    cur.expires_at, a.created_at, a.last_seen_at,
    (select count(*) from billing_private.devices d where d.user_id = a.user_id) as devices
  from billing_private.accounts a
  left join lateral (
    select p.plan, s.expires_at from billing_private.subscriptions s
      join billing_private.products p using(platform, product_id)
      where s.user_id = a.user_id and s.active and s.expires_at > now()
      order by p.rank desc, s.expires_at desc limit 1
  ) cur on true;
revoke all on billing_private.account_plans from public, anon, authenticated;

revoke all on function public.billing_touch(uuid,boolean,uuid) from public, anon, authenticated;
revoke all on function public.billing_state(uuid) from public, anon, authenticated;
grant execute on function public.billing_touch(uuid,boolean,uuid),
  public.billing_state(uuid) to service_role;
