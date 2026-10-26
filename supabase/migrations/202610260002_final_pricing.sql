-- Final pricing. Starter, Pro and Max are $6.99, $14.99 and $24.99 a month,
-- or $69.99, $149.99 and $249.99 a year, with $2.45, $5.25 and $8.75 of AI
-- credit a month (twelve times that a year). Plans and store products are
-- renamed for the new prices. The old products stay, on their renamed tiers
-- and with their old allowances, for any subscription already on them.

-- The new plans go in at spare ranks, products move onto them, and the old
-- plans go; only then can the new ones take the old ranks.
insert into billing_private.plans(plan, rank, title, monthly_price_cents) values
 ('starter699', 101, 'Starter', 699),
 ('pro1499', 102, 'Pro', 1499),
 ('max2499', 103, 'Max', 2499);
update billing_private.products set plan = case plan
    when 'starter499' then 'starter699'
    when 'pro1299' then 'pro1499'
    when 'max2999' then 'max2499'
  end
  where plan in ('starter499', 'pro1299', 'max2999');
delete from billing_private.plans where plan in ('starter499', 'pro1299', 'max2999');
update billing_private.plans set rank = rank - 100 where rank > 100;

insert into billing_private.products (platform, product_id, plan, rank, allowance) values
 ('app_store', 'com.etonia.app.plan.699.monthly', 'starter699', 1, 2450000),
 ('app_store', 'com.etonia.app.plan.1499.monthly', 'pro1499', 2, 5250000),
 ('app_store', 'com.etonia.app.plan.2499.monthly', 'max2499', 3, 8750000),
 ('app_store', 'com.etonia.app.plan.699.yearly', 'starter699', 1, 29400000),
 ('app_store', 'com.etonia.app.plan.1499.yearly', 'pro1499', 2, 63000000),
 ('app_store', 'com.etonia.app.plan.2499.yearly', 'max2499', 3, 105000000),
 ('google_play', 'etonia_plan_699_monthly', 'starter699', 1, 2450000),
 ('google_play', 'etonia_plan_1499_monthly', 'pro1499', 2, 5250000),
 ('google_play', 'etonia_plan_2499_monthly', 'max2499', 3, 8750000),
 ('google_play', 'etonia_plan_699_yearly', 'starter699', 1, 29400000),
 ('google_play', 'etonia_plan_1499_yearly', 'pro1499', 2, 63000000),
 ('google_play', 'etonia_plan_2499_yearly', 'max2499', 3, 105000000)
on conflict (platform, product_id) do update set
  plan = excluded.plan,
  rank = excluded.rank,
  allowance = excluded.allowance;

-- As before, with Starter's new name: it still has no frontier models.
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
  if (free or state->>'activePlan' = 'starter699') and p_model in ('opus','argon','astra') then
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
