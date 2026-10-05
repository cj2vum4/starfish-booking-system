-- Run in Supabase SQL Editor after 202610050024_record_snapshot.sql. All changes are rolled back.
begin;
set local role service_role;
do $$
declare r jsonb; msg text;
begin
  perform public.put_record_snapshot('{"summary":[{"name":"阿明"}],"rewards":[]}');
  r := public.get_record_snapshot();
  if r->'payload'->'summary'->0->>'name'<>'阿明' or (r->>'fetched_at')::timestamptz < now()-interval '1 minute' then raise exception 'snapshot wrong: %', r; end if;
  perform public.put_record_snapshot('{"summary":[],"rewards":[]}');
  if (select count(*) from public.play_record_snapshot)<>1 then raise exception 'more than one row'; end if;
  perform public.expire_record_snapshot();
  if (public.get_record_snapshot()->>'fetched_at')<>'-infinity' then raise exception 'not expired'; end if;
  begin perform public.put_record_snapshot('{"rewards":[]}'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'INVALID_SNAPSHOT' then raise exception 'bad payload: %', msg; end if; end;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_table_privilege(r,'public.play_record_snapshot','SELECT') or has_function_privilege(r,'public.put_record_snapshot(jsonb)','EXECUTE')
      then raise exception 'snapshot exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: single-row snapshot, expiry, validation, privileges' as result;
rollback;
