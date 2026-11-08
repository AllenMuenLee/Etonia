-- Permit content-free metering for the lightweight visual-description stage.
create or replace function public.ai_settle_usage(p_user uuid, p_request uuid, p_cost bigint,
  p_input int, p_output int, p_release boolean, p_task text, p_turn uuid,
  p_effort text, p_passes jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare r billing_private.requests; pass jsonb;
  total_in bigint := 0; total_out bigint := 0; total_cost bigint := 0;
begin
  perform public.billing_lock(p_user);
  select * into strict r from billing_private.requests
    where request_id = p_request and user_id = p_user for update;
  if r.status <> 'pending' then return; end if;
  if p_task not in ('study.answer','study.plan','study.describe','study.suggestions','study.practice',
      'editor.answer','editor.notation','test.grading')
    or p_task is null or p_turn is null or p_effort not in ('low','medium','high')
    or p_effort is null or jsonb_typeof(p_passes) is distinct from 'array'
    or jsonb_array_length(p_passes) > 4 then raise exception 'rejected'; end if;
  for pass in select value from jsonb_array_elements(p_passes) loop
    -- Reject extra fields: note titles, prompts, and responses have no place here.
    if jsonb_typeof(pass) is distinct from 'object' or
      (select count(*) from jsonb_object_keys(pass)) <> 19 or exists(
        select 1 from jsonb_object_keys(pass) k where k not in (
          'model','providerModel','provider','effort','kind','inputTokens','outputTokens',
          'cachedTokens','cacheWriteTokens','reasoningTokens','imageTokens','inputCostMicro',
          'outputCostMicro','roundingCostMicro','costMicro','inputRate','cachedRate','writeRate','outputRate'))
      then raise exception 'rejected'; end if;
    if exists(select 1 from unnest(array['inputTokens','outputTokens','cachedTokens',
        'cacheWriteTokens','costMicro','inputRate','cachedRate','writeRate','outputRate',
        'inputCostMicro','outputCostMicro','roundingCostMicro']) k
      where jsonb_typeof(pass->k) is distinct from 'number' or (pass->>k)::numeric < 0)
      or exists(select 1 from unnest(array['model','providerModel','provider','effort','kind']) k
      where jsonb_typeof(pass->k) is distinct from 'string') then raise exception 'rejected'; end if;
    if pass->>'model' not in ('haiku','luna','sonnet','sol','opus','argon','astra')
      or pass->>'provider' not in ('openai','claude','gemini')
      or pass->>'effort' not in ('low','medium','high')
      or pass->>'kind' not in ('answer','notation')
      or pass->>'providerModel' !~ '^[a-zA-Z0-9._-]{1,128}$'
      or (pass->>'inputTokens')::bigint < 0 or (pass->>'outputTokens')::bigint < 0
      or (pass->>'cachedTokens')::bigint < 0 or (pass->>'cacheWriteTokens')::bigint < 0
      or (pass->>'cachedTokens')::bigint + (pass->>'cacheWriteTokens')::bigint > (pass->>'inputTokens')::bigint
      or (pass->>'costMicro')::bigint < 0 or (pass->>'inputCostMicro')::numeric < 0
      or (pass->>'outputCostMicro')::numeric < 0 or (pass->>'roundingCostMicro')::numeric < 0
      or (pass->>'reasoningTokens')::numeric < 0
      or (pass->>'reasoningTokens')::numeric > (pass->>'outputTokens')::numeric
      or (pass->>'imageTokens')::numeric < 0
      or (pass->>'imageTokens')::numeric > (pass->>'inputTokens')::numeric
      or abs((pass->>'inputCostMicro')::numeric + (pass->>'outputCostMicro')::numeric +
        (pass->>'roundingCostMicro')::numeric - (pass->>'costMicro')::numeric) > 0.000001
      then raise exception 'rejected'; end if;
    total_in := total_in + (pass->>'inputTokens')::bigint;
    total_out := total_out + (pass->>'outputTokens')::bigint;
    total_cost := total_cost + (pass->>'costMicro')::bigint;
  end loop;
  if total_in <> p_input or total_out <> p_output or total_cost <> p_cost then
    raise exception 'rejected'; end if;
  perform public.ai_settle(p_user,p_request,p_cost,p_input,p_output,p_release);
  update billing_private.requests set task = p_task, turn_id = p_turn, effort = p_effort,
    usage_details = jsonb_build_object('pricingVersion','token-v2','passes',p_passes)
    where request_id = p_request;
end $$;

revoke all on function public.ai_settle_usage(uuid,uuid,bigint,int,int,boolean,text,uuid,text,jsonb)
  from public, anon, authenticated;
grant execute on function public.ai_settle_usage(uuid,uuid,bigint,int,int,boolean,text,uuid,text,jsonb)
  to service_role;

