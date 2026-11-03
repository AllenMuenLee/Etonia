-- Public waitlist signups from the GitHub website. Stored in analytics_private
-- so anonymous callers can submit via public.join_waitlist without ever being
-- able to list or read existing email addresses.
create table if not exists analytics_private.waitlist (
  id bigint generated always as identity primary key,
  email text not null unique check (
    length(email) between 3 and 254 and
    email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  ),
  platform text not null default 'ipad' check (
    platform in ('ipad', 'android', 'iphone', 'all')
  ),
  referral_source text check (
    referral_source is null or length(referral_source) <= 64
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table analytics_private.waitlist enable row level security;
revoke all on analytics_private.waitlist from public, anon, authenticated;

create or replace function public.join_waitlist(
  p_email text,
  p_platform text default 'ipad',
  p_source text default 'github_website'
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_platform text := lower(trim(coalesce(nullif(p_platform, ''), 'ipad')));
  v_source text := left(trim(coalesce(nullif(p_source, ''), 'github_website')), 64);
begin
  if length(v_email) < 3 or length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;
  if v_platform not in ('ipad', 'android', 'iphone', 'all') then
    v_platform := 'ipad';
  end if;
  if (select count(*) from analytics_private.waitlist
      where created_at >= now() - interval '1 hour') >= 2000 then
    raise exception 'rate_limited';
  end if;

  insert into analytics_private.waitlist (email, platform, referral_source)
  values (v_email, v_platform, v_source)
  on conflict (email) do update
    set platform = excluded.platform,
        referral_source = excluded.referral_source,
        updated_at = now();

  return jsonb_build_object('ok', true, 'platform', v_platform);
end $$;

revoke all on function public.join_waitlist(text, text, text) from public;
grant execute on function public.join_waitlist(text, text, text) to anon, authenticated, service_role;
