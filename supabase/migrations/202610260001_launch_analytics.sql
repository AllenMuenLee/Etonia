-- Privacy-preserving product analytics for launch. Events are deliberately
-- categorical: never add note titles, filenames, prompts, responses or other
-- user-authored values to this schema.
create schema if not exists analytics_private;
revoke all on schema analytics_private from public, anon, authenticated;

create table analytics_private.events (
  id bigint generated always as identity primary key,
  event_id uuid not null unique,
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid,
  session_id uuid not null,
  event_name text not null check (event_name in (
    'app_open', 'sign_in', 'note_created', 'note_opened', 'note_imported',
    'note_exported', 'paywall_viewed', 'purchase_started', 'backup_enabled'
  )),
  -- Snapshot this because anonymous accounts can later be upgraded in place.
  is_anonymous boolean not null,
  platform text not null check (platform in (
    'android', 'ios', 'macos', 'windows', 'linux', 'web', 'unknown'
  )),
  app_version text check (
    app_version is null or
    (length(app_version) between 1 and 32 and app_version ~ '^[0-9A-Za-z.+_-]+$')
  ),
  -- Controlled dimension such as pdf, goodnotes, or pro1499_yearly.
  detail text check (
    detail is null or
    (length(detail) between 1 and 40 and detail ~ '^[a-z0-9][a-z0-9_.-]*$')
  ),
  constraint event_detail_allowed check (
    (event_name = 'note_imported' and detail is not null and detail in ('pdf', 'goodnotes')) or
    (event_name = 'note_exported' and detail is not null and detail in ('pdf', 'svg')) or
    (event_name = 'purchase_started' and detail is not null and detail in (
      'starter699_monthly', 'starter699_yearly',
      'pro1499_monthly', 'pro1499_yearly',
      'max2499_monthly', 'max2499_yearly'
    )) or
    (event_name not in ('note_imported', 'note_exported', 'purchase_started')
      and detail is null)
  ),
  occurred_at timestamptz not null default now()
);
create index events_user_time_idx
  on analytics_private.events(user_id, occurred_at desc);
create index events_name_time_idx
  on analytics_private.events(event_name, occurred_at desc);
create index events_device_time_idx
  on analytics_private.events(device_id, occurred_at desc)
  where device_id is not null;

alter table analytics_private.events enable row level security;
revoke all on analytics_private.events from public, anon, authenticated;

-- Called only by the authenticated analytics Edge Function with the service
-- role. Server time is authoritative and event_id makes retries idempotent.
create function public.analytics_ingest(
  p_user uuid,
  p_anonymous boolean,
  p_device uuid,
  p_event uuid,
  p_session uuid,
  p_name text,
  p_platform text,
  p_version text default null,
  p_detail text default null
) returns boolean
language plpgsql security definer set search_path = '' as $$
declare inserted_rows bigint;
begin
  if not exists(select 1 from auth.users where id = p_user) then
    raise exception 'unauthorized';
  end if;
  -- A compromised client can inflate only its own numbers; cap table growth.
  if (select count(*) from analytics_private.events
      where user_id = p_user and occurred_at >= now() - interval '24 hours') >= 500 then
    raise exception 'rate_limited';
  end if;
  -- Correlate only a device ID already registered to this account.
  if p_device is not null and not exists(
    select 1 from billing_private.devices
      where device_id = p_device and user_id = p_user
  ) then
    p_device := null;
  end if;
  insert into analytics_private.events(
    event_id, user_id, device_id, session_id, event_name, is_anonymous,
    platform, app_version, detail
  ) values (
    p_event, p_user, p_device, p_session, p_name, p_anonymous,
    p_platform, nullif(p_version, ''), nullif(p_detail, '')
  ) on conflict(event_id) do nothing;
  get diagnostics inserted_rows = row_count;
  return inserted_rows = 1;
end $$;

revoke all on function public.analytics_ingest(
  uuid,boolean,uuid,uuid,uuid,text,text,text,text
) from public, anon, authenticated;
grant execute on function public.analytics_ingest(
  uuid,boolean,uuid,uuid,uuid,text,text,text,text
) to service_role;

-- UTC day-by-day operating sheet. Costs are micro-USD, so divide by 1,000,000
-- for dollars. Charged is customer credit; provider_cost is estimated cost.
create view analytics_private.daily_kpis with (security_invoker = true) as
with event_daily as (
  select occurred_at::date as metric_date,
    count(distinct user_id) filter (where event_name = 'app_open') as active_users,
    count(distinct device_id) filter (where event_name = 'app_open') as active_devices,
    count(*) filter (where event_name = 'app_open') as sessions,
    count(distinct user_id) filter (where event_name = 'sign_in') as sign_ins,
    count(*) filter (where event_name = 'note_created') as notes_created,
    count(*) filter (where event_name = 'note_imported') as notes_imported,
    count(*) filter (where event_name = 'note_opened') as notes_opened,
    count(*) filter (where event_name = 'note_exported') as notes_exported,
    count(*) filter (where event_name = 'paywall_viewed') as paywall_views,
    count(*) filter (where event_name = 'purchase_started') as purchase_starts
  from analytics_private.events group by 1
), account_daily as (
  select created_at::date as metric_date,
    count(*) as new_accounts,
    count(*) filter (where not is_anonymous) as new_signed_in_accounts
  from billing_private.accounts group by 1
), ai_daily as (
  select created_at::date as metric_date,
    count(*) as ai_requests,
    count(distinct user_id) as ai_users,
    count(*) filter (where status = 'settled') as ai_settled,
    count(*) filter (where status = 'released') as ai_released,
    count(*) filter (where status = 'pending') as ai_pending,
    coalesce(sum(input_tokens), 0) as input_tokens,
    coalesce(sum(output_tokens), 0) as output_tokens,
    coalesce(sum(provider_cost), 0) as provider_cost_micro_usd,
    coalesce(sum(charged), 0) as charged_micro_usd
  from billing_private.requests group by 1
), subscription_daily as (
  select observed_at::date as metric_date,
    count(*) filter (where active) as subscription_activations,
    count(distinct user_id) filter (where active) as subscribing_users,
    count(*) filter (where not active) as subscription_deactivations
  from billing_private.subscription_events group by 1
), gift_daily as (
  select redeemed_at::date as metric_date, count(*) as gift_redemptions
  from billing_private.gift_redemptions group by 1
), days as (
  select metric_date from event_daily union select metric_date from account_daily
  union select metric_date from ai_daily union select metric_date from subscription_daily
  union select metric_date from gift_daily
)
select d.metric_date,
  coalesce(e.active_users, 0) as active_users,
  coalesce(e.active_devices, 0) as active_devices,
  coalesce(e.sessions, 0) as sessions,
  coalesce(a.new_accounts, 0) as new_accounts,
  coalesce(a.new_signed_in_accounts, 0) as new_signed_in_accounts,
  coalesce(e.sign_ins, 0) as sign_ins,
  coalesce(e.notes_created, 0) as notes_created,
  coalesce(e.notes_imported, 0) as notes_imported,
  coalesce(e.notes_opened, 0) as notes_opened,
  coalesce(e.notes_exported, 0) as notes_exported,
  coalesce(e.paywall_views, 0) as paywall_views,
  coalesce(e.purchase_starts, 0) as purchase_starts,
  coalesce(s.subscription_activations, 0) as subscription_activations,
  coalesce(s.subscribing_users, 0) as subscribing_users,
  coalesce(s.subscription_deactivations, 0) as subscription_deactivations,
  coalesce(g.gift_redemptions, 0) as gift_redemptions,
  coalesce(ai.ai_requests, 0) as ai_requests,
  coalesce(ai.ai_users, 0) as ai_users,
  coalesce(ai.ai_settled, 0) as ai_settled,
  coalesce(ai.ai_released, 0) as ai_released,
  coalesce(ai.ai_pending, 0) as ai_pending,
  coalesce(ai.input_tokens, 0) as input_tokens,
  coalesce(ai.output_tokens, 0) as output_tokens,
  coalesce(ai.provider_cost_micro_usd, 0) as provider_cost_micro_usd,
  coalesce(ai.charged_micro_usd, 0) as charged_micro_usd
from days d
left join event_daily e using(metric_date)
left join account_daily a using(metric_date)
left join ai_daily ai using(metric_date)
left join subscription_daily s using(metric_date)
left join gift_daily g using(metric_date);

-- One-row founder dashboard. Activity means a recorded app_open.
create view analytics_private.launch_overview with (security_invoker = true) as
select
  (select count(*) from billing_private.accounts) as total_accounts,
  (select count(*) from billing_private.accounts where not is_anonymous) as signed_in_accounts,
  (select count(*) from billing_private.accounts where is_anonymous) as anonymous_accounts,
  (select count(*) from billing_private.devices) as total_devices,
  (select count(*) from billing_private.accounts
    where created_at >= now() - interval '30 days') as new_accounts_30d,
  (select count(distinct user_id) from analytics_private.events
    where event_name = 'app_open' and occurred_at >= current_date) as dau,
  (select count(distinct user_id) from analytics_private.events
    where event_name = 'app_open' and occurred_at >= now() - interval '7 days') as wau,
  (select count(distinct user_id) from analytics_private.events
    where event_name = 'app_open' and occurred_at >= now() - interval '30 days') as mau,
  (select count(distinct device_id) from analytics_private.events
    where event_name = 'app_open' and occurred_at >= now() - interval '30 days')
    as active_devices_30d,
  (select count(*) from billing_private.account_plans where plan <> 'free') as paying_accounts,
  (select count(distinct user_id) from analytics_private.events
    where event_name in ('note_created', 'note_imported')) as activated_accounts,
  (select count(distinct user_id) from analytics_private.events
    where event_name = 'paywall_viewed' and occurred_at >= now() - interval '30 days')
    as paywall_accounts_30d,
  (select count(distinct user_id) from analytics_private.events
    where event_name = 'purchase_started' and occurred_at >= now() - interval '30 days')
    as purchase_intent_accounts_30d,
  (select count(distinct user_id) from billing_private.requests) as ai_accounts,
  (select count(*) from billing_private.requests) as ai_requests,
  (select coalesce(sum(input_tokens), 0) from billing_private.requests) as input_tokens,
  (select coalesce(sum(output_tokens), 0) from billing_private.requests) as output_tokens,
  (select coalesce(sum(provider_cost), 0) from billing_private.requests) as provider_cost_micro_usd,
  (select count(*) from billing_private.requests where status = 'pending'
    and created_at < now() - interval '2 minutes') as stale_ai_requests;

create view analytics_private.model_usage with (security_invoker = true) as
select model, count(*) as requests, count(distinct user_id) as users,
  count(*) filter (where status = 'settled') as settled,
  count(*) filter (where status = 'released') as released,
  count(*) filter (where status = 'pending') as pending,
  coalesce(sum(input_tokens), 0) as input_tokens,
  coalesce(sum(output_tokens), 0) as output_tokens,
  coalesce(sum(provider_cost), 0) as provider_cost_micro_usd,
  coalesce(sum(charged), 0) as charged_micro_usd
from billing_private.requests group by model;

create view analytics_private.client_mix_30d with (security_invoker = true) as
select platform, coalesce(app_version, 'unknown') as app_version,
  count(*) filter (where event_name = 'app_open') as sessions,
  count(distinct user_id) filter (where event_name = 'app_open') as active_users,
  count(distinct device_id) filter (where event_name = 'app_open') as active_devices,
  max(occurred_at) as last_seen_at
from analytics_private.events
where occurred_at >= now() - interval '30 days'
group by platform, coalesce(app_version, 'unknown');

create view analytics_private.plan_health with (security_invoker = true) as
select ap.plan, count(*) as accounts,
  count(*) filter (where ap.last_seen_at >= now() - interval '30 days') as seen_30d,
  count(*) filter (where s.auto_renew = false and s.active) as not_renewing,
  count(*) filter (where s.active and s.expires_at between now() and now() + interval '7 days')
    as expiring_7d
from billing_private.account_plans ap
left join lateral (
  select active, auto_renew, expires_at from billing_private.subscriptions s
  where s.user_id = ap.user_id and s.active and s.expires_at > now()
  order by s.expires_at desc limit 1
) s on true
group by ap.plan;

-- D1/D7/D30 retention by account-creation week. Eligibility is explicit so
-- incomplete recent cohorts do not look like churn.
create view analytics_private.weekly_retention with (security_invoker = true) as
with activity as (
  select distinct user_id, occurred_at::date as active_date
  from analytics_private.events where event_name = 'app_open'
), per_account as (
  select a.user_id, a.created_at::date as created_date,
    coalesce(bool_or(x.active_date = a.created_at::date), false) as d0,
    coalesce(bool_or(x.active_date = a.created_at::date + 1), false) as d1,
    coalesce(bool_or(x.active_date = a.created_at::date + 7), false) as d7,
    coalesce(bool_or(x.active_date = a.created_at::date + 30), false) as d30
  from billing_private.accounts a
  left join activity x on x.user_id = a.user_id
  group by a.user_id, a.created_at::date
)
select date_trunc('week', created_date)::date as cohort_week,
  count(*) as accounts,
  count(*) filter (where d0) as opened_d0,
  count(*) filter (where current_date >= created_date + 1) as eligible_d1,
  count(*) filter (where d1) as retained_d1,
  count(*) filter (where current_date >= created_date + 7) as eligible_d7,
  count(*) filter (where d7) as retained_d7,
  count(*) filter (where current_date >= created_date + 30) as eligible_d30,
  count(*) filter (where d30) as retained_d30
from per_account group by 1;

-- Aggregate customer health for support and early-customer interviews.
create view analytics_private.customer_health with (security_invoker = true) as
with event_rollup as (
  select user_id, max(occurred_at) as last_active_at,
    count(distinct occurred_at::date) as active_days,
    count(*) filter (where event_name = 'app_open') as sessions,
    count(*) filter (where event_name = 'note_created') as notes_created,
    count(*) filter (where event_name = 'note_imported') as notes_imported,
    count(*) filter (where event_name = 'note_exported') as notes_exported,
    count(*) filter (where event_name = 'paywall_viewed') as paywall_views
  from analytics_private.events group by user_id
), ai_rollup as (
  select user_id, count(*) as ai_requests,
    coalesce(sum(input_tokens), 0) as input_tokens,
    coalesce(sum(output_tokens), 0) as output_tokens,
    coalesce(sum(provider_cost), 0) as provider_cost_micro_usd,
    max(created_at) as last_ai_at
  from billing_private.requests group by user_id
)
select ap.user_id, ap.is_anonymous, ap.plan, ap.created_at,
  coalesce(e.last_active_at, ap.last_seen_at) as last_active_at,
  coalesce(e.active_days, 0) as active_days,
  coalesce(e.sessions, 0) as sessions,
  coalesce(e.notes_created, 0) as notes_created,
  coalesce(e.notes_imported, 0) as notes_imported,
  coalesce(e.notes_exported, 0) as notes_exported,
  coalesce(e.paywall_views, 0) as paywall_views,
  coalesce(ai.ai_requests, 0) as ai_requests,
  coalesce(ai.input_tokens, 0) as input_tokens,
  coalesce(ai.output_tokens, 0) as output_tokens,
  coalesce(ai.provider_cost_micro_usd, 0) as provider_cost_micro_usd,
  ai.last_ai_at, ap.devices
from billing_private.account_plans ap
left join event_rollup e using(user_id)
left join ai_rollup ai using(user_id);

revoke all on all tables in schema analytics_private from public, anon, authenticated;

-- Run monthly from Supabase Cron or manually to keep raw behavior bounded.
create function public.analytics_prune(p_before timestamptz default now() - interval '400 days')
returns bigint
language plpgsql security definer set search_path = '' as $$
declare removed bigint;
begin
  delete from analytics_private.events where occurred_at < p_before;
  get diagnostics removed = row_count;
  return removed;
end $$;
revoke all on function public.analytics_prune(timestamptz) from public, anon, authenticated;
grant execute on function public.analytics_prune(timestamptz) to service_role;
