-- Run in Supabase SQL Editor. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  a text := 'U00000000000000000000000000000001';
  b text := 'U00000000000000000000000000000002';
  result jsonb;
  baseline bigint;
begin
  select count(*) into baseline from public.users;
  result := public.process_line_events(jsonb_build_array(
    jsonb_build_object('type','follow','userId',a,'timestamp',1000,'webhookEventId','qa-follow-1'),
    jsonb_build_object('type','follow','userId',b,'timestamp',1000,'webhookEventId','qa-follow-2')));
  if (result->>'processed')::int <> 2 then raise exception 'multi-event failed'; end if;
  if (select count(*) from public.users) <> baseline + 2 then raise exception 'user creation failed'; end if;

  result := public.process_line_events(jsonb_build_array(
    jsonb_build_object('type','follow','userId',a,'timestamp',1000,'webhookEventId','qa-follow-1')));
  if (result->>'duplicates')::int <> 1 then raise exception 'dedupe failed'; end if;
  if (select count(*) from public.users) <> baseline + 2 then raise exception 'duplicate user'; end if;

  perform public.process_line_events(jsonb_build_array(
    jsonb_build_object('type','unfollow','userId',a,'timestamp',3000,'webhookEventId','qa-unfollow')));
  if (select oa_friend_status from public.users where line_user_id=a) <> 'blocked'
    then raise exception 'unfollow failed'; end if;
  if (select blocked_at from public.users where line_user_id=a) is null
    then raise exception 'missing blocked timestamp'; end if;

  perform public.process_line_events(jsonb_build_array(
    jsonb_build_object('type','follow','userId',a,'timestamp',2000,'webhookEventId','qa-old-follow')));
  if (select oa_friend_status from public.users where line_user_id=a) <> 'blocked'
    then raise exception 'old redelivery overwrote new state'; end if;

  perform public.process_line_events(jsonb_build_array(
    jsonb_build_object('type','follow','userId',a,'timestamp',4000,'webhookEventId','qa-refollow')));
  if (select oa_friend_status from public.users where line_user_id=a) <> 'active'
    or (select blocked_at from public.users where line_user_id=a) is not null
    then raise exception 'refollow failed'; end if;

  begin
    perform public.process_line_events(jsonb_build_array(
      jsonb_build_object('type','follow','userId',a,'timestamp',5000,'webhookEventId','qa-rollback'),
      jsonb_build_object('type','follow','userId','invalid','timestamp',5000,'webhookEventId','qa-bad')));
    raise exception 'invalid batch was accepted';
  exception when invalid_parameter_value then null;
  end;
  if exists(select 1 from public.line_webhook_events where webhook_event_id='qa-rollback')
    then raise exception 'batch was not rolled back'; end if;
end $$;
reset role;
do $$
declare tbl text; r text;
begin
  foreach tbl in array array['users','players','line_webhook_events'] loop
    if not (select relrowsecurity from pg_class where oid=('public.'||tbl)::regclass)
      then raise exception 'RLS missing on %', tbl; end if;
    foreach r in array array['anon','authenticated'] loop
      if has_table_privilege(r,'public.'||tbl,'SELECT,INSERT,UPDATE,DELETE')
        then raise exception 'private table exposed to %', r; end if;
      if has_function_privilege(r,'public.process_line_events(jsonb)','EXECUTE')
        then raise exception 'ingestion RPC exposed to %', r; end if;
    end loop;
  end loop;
end $$;
select 'PASS: multi-event, dedupe, block, refollow, out-of-order, rollback, RLS and privileges' as result;
rollback;
