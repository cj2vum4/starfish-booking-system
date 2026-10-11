-- Run in Supabase SQL Editor after 202610110034_tick_schedule.sql. All synthetic records are rolled back.
-- On Supabase it also checks that the 5-minute pg_cron job exists; the local test database has no pg_cron.
begin;
do $$
declare
  t1 text; t2 text; h1 text; h2 text; n integer; r text; f text;
begin
  -- Tokens are 64 hex characters, distinct, and only their hash is kept.
  t1 := public._sf_new_tick_token();
  t2 := public._sf_new_tick_token();
  if t1 !~ '^[0-9a-f]{64}$' or t2 !~ '^[0-9a-f]{64}$' or t1=t2 then raise exception 'bad token %', t1; end if;
  h1 := encode(sha256(convert_to(t1,'UTF8')),'hex');
  h2 := encode(sha256(convert_to(t2,'UTF8')),'hex');
  if exists(select 1 from public.tick_tokens where token_hash in (t1,t2)) then raise exception 'raw token stored'; end if;
  if (select count(*) from public.tick_tokens where token_hash in (h1,h2))<>2 then raise exception 'token hash not stored'; end if;

  -- The api spends each token once (as service_role); unknown or reused tokens are refused.
  set local role service_role;
  if not public.consume_tick_token(h1) then raise exception 'fresh token refused'; end if;
  if public.consume_tick_token(h1) then raise exception 'token accepted twice'; end if;
  if public.consume_tick_token(repeat('0',64)) then raise exception 'unknown token accepted'; end if;
  reset role;

  -- A token older than 10 minutes is refused; anything older than an hour is cleared on the next issue.
  update public.tick_tokens set created_at=now()-interval '11 minutes' where token_hash=h2;
  set local role service_role;
  if public.consume_tick_token(h2) then raise exception 'expired token accepted'; end if;
  reset role;
  update public.tick_tokens set created_at=now()-interval '2 hours' where token_hash=h2;
  perform public._sf_new_tick_token();
  if exists(select 1 from public.tick_tokens where token_hash=h2) then raise exception 'old token not cleared'; end if;

  -- Players and the api keys can neither read tokens nor issue them.
  foreach r in array array['anon','authenticated'] loop
    if has_table_privilege(r,'public.tick_tokens','SELECT') or has_table_privilege(r,'public.tick_tokens','INSERT') then
      raise exception 'tick_tokens exposed to %', r; end if;
    if has_function_privilege(r,'public.consume_tick_token(text)','EXECUTE') then raise exception 'consume exposed to %', r; end if;
  end loop;
  foreach r in array array['anon','authenticated','service_role'] loop
    foreach f in array array['public._sf_new_tick_token()','public._sf_tick()'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
  end loop;
  if not (select relrowsecurity from pg_class where oid='public.tick_tokens'::regclass) then raise exception 'RLS off'; end if;

  -- Supabase: the job runs every 5 minutes and calls _sf_tick.
  if exists(select 1 from pg_extension where extname='pg_cron') then
    execute $q$select count(*) from cron.job where jobname='starfish-tick' and schedule='*/5 * * * *'
      and command='select public._sf_tick()' and active$q$ into n;
    if n<>1 then raise exception 'starfish-tick job missing or changed'; end if;
    execute $q$select count(*) from cron.job where jobname='starfish-tick-cleanup' and active
      and command like 'delete from cron.job_run_details%'$q$ into n;
    if n<>1 then raise exception 'starfish-tick-cleanup job missing'; end if;
    if not exists(select 1 from pg_extension where extname='pg_net') then raise exception 'pg_net not enabled'; end if;
  elsif exists(select 1 from pg_available_extensions where name='pg_cron') then
    raise exception 'pg_cron is available but not enabled: the migration did not schedule the job';
  end if;
end $$;
select 'PASS: tick tokens are one-time, hashed, expire after 10 minutes, owner-only; cron job scheduled where pg_cron exists' as result;
rollback;
