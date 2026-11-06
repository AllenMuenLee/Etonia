-- Stop using reserve token thing: if remaining tokens/credits are above 0,
-- always accept the request. Balances are not held/deducted upfront, and actual
-- costs are deducted when settled.

create or replace function public.ai_reserve(p_user uuid, p_request uuid, p_model text,
  p_max bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; balance bigint; n int; free boolean; unlimited boolean;
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
  unlimited := not free and p_model in ('haiku', 'luna');

  -- If the user's remaining token/credit is above 0 (or unlimited), always accept!
  if not unlimited and coalesce(balance, 0) <= 0 then
    raise exception 'insufficient_credits';
  end if;

  -- Do not reserve or pre-deduct tokens out of remaining balance.
  insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,status)
    values(p_request,p_user,grant_key,p_model,0,'pending');
  return jsonb_build_object('reserved', 0, 'unlimited', unlimited);
end $$;

create or replace function public.ai_settle(p_user uuid, p_request uuid, p_cost bigint,
  p_input int, p_output int, p_release boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare r billing_private.requests; charge_amount bigint;
begin
  perform public.billing_lock(p_user);
  select * into strict r from billing_private.requests
    where request_id = p_request and user_id = p_user for update;
  if r.status <> 'pending' then return; end if;
  if p_cost < 0 or p_input < 0 or p_output < 0 then raise exception 'rejected'; end if;

  if p_release then
    charge_amount := 0;
    if r.reserved > 0 then
      update billing_private.grants set remaining = remaining + r.reserved
        where transaction_key = r.transaction_key;
    end if;
  else
    charge_amount := p_cost;
    update billing_private.grants
      set remaining = greatest(0, remaining + r.reserved - charge_amount)
      where transaction_key = r.transaction_key;
  end if;

  update billing_private.requests set charged = charge_amount, provider_cost = p_cost, input_tokens = p_input,
    output_tokens = p_output, status = case when p_release then 'released' else 'settled' end
    where request_id = p_request;
end $$;

revoke all on function public.ai_reserve(uuid,uuid,text,bigint) from public, anon, authenticated;
grant execute on function public.ai_reserve(uuid,uuid,text,bigint) to service_role;
revoke all on function public.ai_settle(uuid,uuid,bigint,int,int,boolean) from public, anon, authenticated;
grant execute on function public.ai_settle(uuid,uuid,bigint,int,int,boolean) to service_role;
