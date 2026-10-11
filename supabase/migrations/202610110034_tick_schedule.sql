begin;

-- 定時排程：每 5 分鐘由資料庫的 pg_cron 叫醒 api（POST /hooks/tick），
-- 重送待送／失敗的 LINE 通知、取消開場時間已過的揪團，不再等下一位玩家按按鈕。
-- 叫醒時附一次性的通行碼：由資料庫產生、只存 SHA-256、10 分鐘內有效、用過即刪，
-- 所以不需要另外保管或輪替任何密碼；外人呼叫 /hooks/tick 只會得到 401。

create table public.tick_tokens (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
alter table public.tick_tokens enable row level security;
revoke all on public.tick_tokens from public,anon,authenticated;
grant select,insert,update,delete on public.tick_tokens to service_role;

-- One wake-up token: 2 x 122 random bits from gen_random_uuid() (pg_strong_random), 64 hex characters.
-- Only its hash is stored; leftovers from failed deliveries are removed after an hour.
create function public._sf_new_tick_token()
returns text language plpgsql set search_path='' as $$
declare tok text := replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
begin
  delete from public.tick_tokens where created_at<now()-interval '1 hour';
  insert into public.tick_tokens(token_hash) values (encode(sha256(convert_to(tok,'UTF8')),'hex'));
  return tok;
end $$;

-- The api spends a token exactly once. Tokens older than 10 minutes are refused.
create function public.consume_tick_token(p_token_hash text)
returns boolean language plpgsql set search_path='' as $$
declare n integer;
begin
  delete from public.tick_tokens where token_hash=p_token_hash and created_at>now()-interval '10 minutes';
  get diagnostics n = row_count;
  return n=1;
end $$;

-- Run by pg_cron. pg_net queues the request and sends it after this transaction commits.
-- The api answers 202 at once and does the work in the background, so a short timeout is enough.
create function public._sf_tick()
returns bigint language plpgsql set search_path='' as $$
begin
  return net.http_post(
    url := 'https://qrcpmxejhqrvvpnjehri.supabase.co/functions/v1/api/hooks/tick',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type','application/json','X-Tick-Token',public._sf_new_tick_token()),
    timeout_milliseconds := 10000);
end $$;

-- Only the owner (postgres, the role pg_cron runs the job as) issues tokens; the api only spends them.
revoke all on function public._sf_new_tick_token() from public,anon,authenticated,service_role;
revoke all on function public._sf_tick() from public,anon,authenticated,service_role;
revoke all on function public.consume_tick_token(text) from public,anon,authenticated;
grant execute on function public.consume_tick_token(text) to service_role;

-- The schedule itself. Supabase ships pg_cron and pg_net; the local test database (PGlite) has neither,
-- so there the job is skipped and tests/tick_schedule.sql checks only the token functions.
-- Same name = same job: re-running cron.schedule updates it instead of adding a second one.
-- pg_cron keeps a row per run forever (cron.job_run_details); a daily job keeps a week of ours.
-- 停用：select cron.unschedule('starfish-tick'); select cron.unschedule('starfish-tick-cleanup');
do $$
begin
  if (select count(*) from pg_available_extensions where name in ('pg_cron','pg_net'))=2 then
    create extension if not exists pg_net with schema extensions;
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('starfish-tick','*/5 * * * *','select public._sf_tick()');
    perform cron.schedule('starfish-tick-cleanup','17 19 * * *',  -- 03:17 Asia/Taipei
      $c$delete from cron.job_run_details where end_time<now()-interval '7 days'
        and jobid in (select jobid from cron.job where jobname like 'starfish-%')$c$);
  else
    raise notice 'pg_cron/pg_net not available: starfish-tick not scheduled';
  end if;
end $$;

commit;
