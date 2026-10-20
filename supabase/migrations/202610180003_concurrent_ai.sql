-- Several AI requests per account may be in flight at once. Each holds only its
-- own worst-case cost (p_max, from the edge function), not the whole balance,
-- so the others still have credit to reserve. A request left pending (timeout,
-- failed settlement) keeps its hold for an administrator to settle, but after
-- ten minutes it no longer counts toward the concurrency limit.

drop function public.ai_reserve(uuid, uuid, text);

create function public.ai_reserve(p_user uuid, p_request uuid, p_model text,
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
  select remaining into balance from billing_private.grants where transaction_key = grant_key for update;
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

revoke all on function public.ai_reserve(uuid,uuid,text,bigint) from public, anon, authenticated;
grant execute on function public.ai_reserve(uuid,uuid,text,bigint) to service_role;
