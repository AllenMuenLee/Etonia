-- Embeddings for Study Desk search. The app sends the text or picture of a
-- chunk of the user's notes, gets a vector back, and keeps it on the device;
-- nothing is stored here but what the request cost.
--
-- An embedding is never unlimited: it draws credits on any plan that has them.
-- Its rows share billing_private.requests with AI answers, so the answer limits
-- (4 at a time, 300 a day) must not count them, or indexing a note would starve
-- chat. Embeddings have limits of their own.

create or replace function public.ai_reserve(p_user uuid, p_request uuid, p_model text,
  p_max bigint default null, p_effort text default 'high') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; balance bigint; n int; free boolean; unlimited boolean;
begin
  perform public.billing_lock(p_user);
  if exists(select 1 from billing_private.requests where request_id = p_request) then
    raise exception 'request_in_progress';
  end if;
  select count(*) into n from billing_private.requests
    where user_id = p_user and status = 'pending' and model <> 'embed'
      and created_at > now() - interval '10 minutes';
  if n >= 4 then raise exception 'request_in_progress'; end if;
  select count(*) into n from billing_private.requests
    where user_id = p_user and model <> 'embed' and created_at > now() - interval '24 hours';
  if n >= 300 then raise exception 'rate_limited'; end if;
  if p_model not in ('haiku','luna','sonnet','sol','opus','argon','astra') then raise exception 'rejected'; end if;
  if p_effort not in ('low','medium','high') then raise exception 'rejected'; end if;
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

  unlimited := not free and p_model in ('haiku', 'luna') and p_effort in ('low', 'medium');

  if not unlimited and coalesce(balance, 0) <= 0 then
    raise exception 'insufficient_credits';
  end if;

  insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,status,unlimited)
    values(p_request,p_user,grant_key,p_model,0,'pending',unlimited);
  return jsonb_build_object('reserved', 0, 'unlimited', unlimited);
end $$;

-- Whether this account may have something embedded now. Raises plan_required
-- (no credit was ever granted), insufficient_credits (nothing left) or
-- rate_limited. Nothing is held: the cost is taken once it is known.
create function public.embed_admit(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; balance bigint; n int;
begin
  perform public.billing_lock(p_user);
  select count(*) into n from billing_private.requests
    where user_id = p_user and model = 'embed' and created_at > now() - interval '1 minute';
  if n >= 40 then raise exception 'rate_limited'; end if;
  select count(*) into n from billing_private.requests
    where user_id = p_user and model = 'embed' and created_at > now() - interval '24 hours';
  if n >= 5000 then raise exception 'rate_limited'; end if;
  state := public.billing_state(p_user);
  grant_key := state->>'grantedPurchaseId';
  if state->>'activePlan' is null and grant_key is null then raise exception 'plan_required'; end if;
  select case when expires_at is not null and expires_at <= now() then 0 else remaining end
    into balance from billing_private.grants where transaction_key = grant_key;
  if coalesce(balance, 0) <= 0 then raise exception 'insufficient_credits'; end if;
end $$;

-- Takes what an embedding cost, once, however often the call is retried: the
-- request id is the key. p_input is the tokens, or pictures counted as tokens.
create function public.embed_settle(p_user uuid, p_request uuid, p_cost bigint, p_input int)
returns void
language plpgsql security definer set search_path = '' as $$
declare state jsonb; grant_key text; charge_amount bigint;
begin
  perform public.billing_lock(p_user);
  if p_cost < 0 or p_input < 0 then raise exception 'rejected'; end if;
  if exists(select 1 from billing_private.requests where request_id = p_request) then return; end if;
  state := public.billing_state(p_user);
  grant_key := state->>'grantedPurchaseId';
  if grant_key is null then return; end if;
  update billing_private.grants
    set remaining = greatest(0, remaining - p_cost)
    where transaction_key = grant_key
    returning p_cost into charge_amount;
  insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,charged,
      provider_cost,input_tokens,output_tokens,status,unlimited)
    values(p_request,p_user,grant_key,'embed',0,charge_amount,p_cost,p_input,0,'settled',false);
end $$;

revoke all on function public.ai_reserve(uuid,uuid,text,bigint,text) from public, anon, authenticated;
grant execute on function public.ai_reserve(uuid,uuid,text,bigint,text) to service_role;
revoke all on function public.embed_admit(uuid) from public, anon, authenticated;
grant execute on function public.embed_admit(uuid) to service_role;
revoke all on function public.embed_settle(uuid,uuid,bigint,int) from public, anon, authenticated;
grant execute on function public.embed_settle(uuid,uuid,bigint,int) to service_role;
