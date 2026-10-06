-- Run in Supabase SQL Editor after 202610060026_record_submissions.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare a uuid; b uuid; r jsonb; rid uuid := gen_random_uuid(); rid2 uuid := gen_random_uuid(); n int;
begin
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f2a1','甲') returning id into a;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f2a2','乙') returning id into b;
  -- Anything already waiting or picked by the real queue stays out of this test's way.
  update public.record_submissions set next_attempt_at=now()+interval '1 day' where status='pending';

  r := public.queue_record_submission(a,rid,null,'QA 劇本','QA 鍵','2026-09-01','角色',5,'好玩','','甲');
  if r->>'status'<>'pending' or (r->>'duplicate')::boolean then raise exception 'queue wrong: %', r; end if;
  r := public.queue_record_submission(a,rid,null,'QA 劇本','QA 鍵','2026-09-01','改過',4,'再送','','甲');
  if not (r->>'duplicate')::boolean then raise exception 'duplicate not detected'; end if;
  if (select character from public.record_submissions where user_id=a and record_id=rid)<>'角色' then raise exception 'duplicate overwrote'; end if;
  -- Same session id for another player is a separate submission.
  perform public.queue_record_submission(b,rid,null,'QA 劇本','QA 鍵','2026-09-01','乙角',3,'','','乙');

  r := public.claim_record_submissions(10);
  if jsonb_array_length(r)<>2 then raise exception 'claim wrong: %', r; end if;
  if jsonb_array_length(public.claim_record_submissions(10))<>0 then raise exception 'claimed twice'; end if;

  -- Temporary error: back to pending, but not before the backoff.
  perform public.complete_record_submission(a,rid,null,false,'TIMEOUT',false);
  if (select status from public.record_submissions where user_id=a and record_id=rid)<>'pending' then raise exception 'temporary error not retried'; end if;
  if jsonb_array_length(public.claim_record_submissions(10))<>0 then raise exception 'retried without backoff'; end if;
  update public.record_submissions set next_attempt_at=now()-interval '1 second' where user_id=a and record_id=rid;
  if jsonb_array_length(public.claim_record_submissions(10))<>1 then raise exception 'retry not claimable'; end if;
  perform public.complete_record_submission(a,rid,'甲的歸戶名',false,null,false);
  if (select status||'/'||saved_name from public.record_submissions where user_id=a and record_id=rid)<>'saved/甲的歸戶名' then raise exception 'save not recorded'; end if;

  -- Permanent error stops; the player may send it again.
  perform public.complete_record_submission(b,rid,null,false,'IDENTITY_MERGE_REQUIRED',true);
  if (select status from public.record_submissions where user_id=b and record_id=rid)<>'failed' then raise exception 'permanent error retried'; end if;
  r := public.queue_record_submission(b,rid,null,'QA 劇本','QA 鍵','2026-09-01','乙角',3,'第二次','','乙');
  if r->>'status'<>'pending' or (select attempts from public.record_submissions where user_id=b and record_id=rid)<>0 then raise exception 'resend after failure: %', r; end if;

  -- A stuck "sending" row is picked again after its lock expires.
  perform public.queue_record_submission(a,rid2,null,'QA 劇本','QA 鍵','2026-09-02','角色',5,'','','甲');
  update public.record_submissions set status='sending',locked_until=now()-interval '1 second' where user_id=a and record_id=rid2;
  update public.record_submissions set next_attempt_at=now()+interval '1 day' where user_id=b;
  if jsonb_array_length(public.claim_record_submissions(10))<>1 then raise exception 'stuck row not reclaimed'; end if;

  r := public.my_record_submissions(a);
  if jsonb_array_length(r)<>2 or exists(select 1 from jsonb_array_elements(r) x where x->>'title'<>'QA 劇本') then raise exception 'my list wrong: %', r; end if;
  if jsonb_array_length(public.my_record_submissions(b))<>1 then raise exception 'list leaks across players'; end if;

  begin
    perform public.queue_record_submission(a,gen_random_uuid(),null,'QA 劇本','QA 鍵','2026-09-01','角色',6,'','','甲');
    raise exception 'MISSING';
  exception when check_violation then null; end;
end $$;
reset role;
do $$
declare r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_table_privilege(r,'public.record_submissions','SELECT') then raise exception 'table exposed to %', r; end if;
    foreach f in array array['public.queue_record_submission(uuid,uuid,uuid,text,text,date,text,integer,text,text,text)',
      'public.claim_record_submissions(integer)','public.complete_record_submission(uuid,uuid,text,boolean,text,boolean)',
      'public.my_record_submissions(uuid)'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
  end loop;
end $$;
select 'PASS: queue, duplicate, per-player keys, claim once, backoff retry, save, permanent failure and resend, stuck lock, my list, privileges' as result;
rollback;
