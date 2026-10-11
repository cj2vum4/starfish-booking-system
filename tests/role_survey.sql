-- Run in Supabase SQL Editor after 202610110035_role_survey.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; pl uuid; r jsonb; rid uuid; k text; c uuid := gen_random_uuid(); i integer;
begin
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000005a01','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000005a02','玩家','active') returning id into pl;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes,review_key,active)
    values ('qa-survey','QA王座',2,7,240,'QA王座',false);

  -- 送出：多選用「, 」串、數字轉文字、空白標題略過、前後空白去掉；與 Apps Script 相同的上限。
  r := public.submit_role_survey(' QA王座 ', jsonb_build_array(
    jsonb_build_object('label',' Line名稱 ','value','阿明'),
    jsonb_build_object('label','喜歡的類型','value',jsonb_build_array('推理','情感')),
    jsonb_build_object('label','邏輯','value',4),
    jsonb_build_object('label','  ','value','沒有標題'),
    jsonb_build_object('label','長答案','value',repeat('字',6000)),
    jsonb_build_object('label','公式','value','=HYPERLINK("x")')), c);
  rid := (r->>'id')::uuid;
  select fields into r from public.role_survey_responses where id=rid;
  if r <> jsonb_build_array(jsonb_build_object('label','Line名稱','value','阿明'),
      jsonb_build_object('label','喜歡的類型','value','推理, 情感'), jsonb_build_object('label','邏輯','value','4'),
      jsonb_build_object('label','長答案','value',repeat('字',5000)), jsonb_build_object('label','公式','value','=HYPERLINK("x")'))
    then raise exception 'fields not cleaned as expected: %', r; end if;
  if (select script from public.role_survey_responses where id=rid)<>'QA王座' then raise exception 'script not trimmed'; end if;

  -- 同一個送出編號再送一次（回應沒收到而重送）：不會存兩份。
  r := public.submit_role_survey('QA王座','[{"label":"Line名稱","value":"阿明"}]',c);
  if (r->>'id')::uuid<>rid or (r->>'duplicate')::boolean is not true then raise exception 'retry stored twice: %', r; end if;
  if (select count(*) from public.role_survey_responses where script='QA王座')<>1 then raise exception 'duplicate row'; end if;

  -- 不合格的送出整筆拒絕；不在劇本目錄裡的名稱也拒絕（擋垃圾分本）。
  foreach k in array array['null','{}','[]','[{"label":"","value":"x"}]','[1,2]'] loop
    begin
      perform public.submit_role_survey('QA王座', k::jsonb);
      raise exception 'accepted bad fields %', k;
    exception when raise_exception then
      if sqlerrm<>'INVALID_SURVEY' then raise; end if;
    end;
  end loop;
  foreach k in array array['', 'QA不存在的劇本'] loop
    begin perform public.submit_role_survey(k, '[{"label":"a","value":"b"}]'); raise exception 'accepted script %', k;
    exception when raise_exception then if sqlerrm<>'INVALID_SURVEY' then raise; end if; end;
  end loop;

  -- 只有店家能讀、改、刪、匯入。
  begin perform public.admin_role_survey_scripts(pl); raise exception 'player listed surveys';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_role_survey_responses(pl,'QA王座'); raise exception 'player read answers';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_update_role_survey(pl,rid,'雷神',''); raise exception 'player assigned a role';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_import_role_surveys(pl,'[]'); raise exception 'player imported';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;

  r := public.admin_role_survey_scripts(adm);
  if not exists(select 1 from jsonb_array_elements(r) x where x->>'script'='QA王座' and (x->>'total')::int=1 and (x->>'unassigned')::int=1)
    then raise exception 'script summary wrong: %', r; end if;
  r := public.admin_update_role_survey(adm,rid,' 雷神 ','先給雷神，洛基備選');
  if r->>'assigned_role'<>'雷神' or r->>'store_note'<>'先給雷神，洛基備選' then raise exception 'update wrong: %', r; end if;
  if (select (x->>'unassigned')::int from jsonb_array_elements(public.admin_role_survey_scripts(adm)) x where x->>'script'='QA王座')<>0
    then raise exception 'assigned answer still counted as unassigned'; end if;
  begin perform public.admin_update_role_survey(adm,gen_random_uuid(),'x',''); raise exception 'updated a missing answer';
  exception when raise_exception then if sqlerrm<>'SURVEY_NOT_FOUND' then raise; end if; end;

  -- 翻頁：新的在前；同一秒的回覆用 id 接續，不會漏。
  insert into public.role_survey_responses(script,fields,submitted_at)
    select 'QA王座','[{"label":"Line名稱","value":"同秒"}]'::jsonb, timestamptz '2026-10-01 12:00:00+08' from generate_series(1,3);
  update public.role_survey_responses set submitted_at=now()-interval '1 day' where id=rid;
  r := public.admin_role_survey_responses(adm,'QA王座',2);
  if jsonb_array_length(r)<>2 or (r->0->>'id')::uuid<>rid then raise exception 'newest first failed: %', r; end if;
  r := public.admin_role_survey_responses(adm,'QA王座',2,(r->1->>'submitted_at')::timestamptz,(r->1->>'id')::uuid);
  if jsonb_array_length(r)<>2 or exists(select 1 from jsonb_array_elements(r) x where (x->>'id')::uuid=rid) then
    raise exception 'same-second paging lost or repeated rows: %', r; end if;
  if (select count(distinct id) from public.role_survey_responses where script='QA王座')<>4 then raise exception 'setup'; end if;

  -- 匯入：同一列只進來一次；壞掉的列略過；網站已收到的同一份（送出編號相同）略過；帶入店家欄位。
  r := public.admin_import_role_surveys(adm, jsonb_build_array(
    jsonb_build_object('script','QA王座','submitted_at','2026-09-01T12:00:00+08:00','import_key',repeat('b',64),
      'fields','[{"label":"Line名稱","value":"舊玩家"}]'::jsonb,'assigned_role','洛基','store_note','舊備註'),
    jsonb_build_object('script','QA王座','submitted_at','not a date','import_key',repeat('c',64),'fields','[{"label":"a","value":"b"}]'::jsonb),
    jsonb_build_object('script','QA王座','submitted_at','2026-09-02T12:00:00+08:00','import_key','short','fields','[{"label":"a","value":"b"}]'::jsonb),
    jsonb_build_object('script','QA王座','submitted_at','2026-09-03T12:00:00+08:00','import_key',repeat('d',64),'fields','[]'::jsonb),
    jsonb_build_object('script','QA王座','submitted_at','2026-10-11T12:00:00+08:00','import_key',repeat('e',64),
      'client_id',c::text,'fields','[{"label":"Line名稱","value":"阿明"}]'::jsonb)));
  if r<>'{"imported":1,"skipped":4}'::jsonb then raise exception 'import counts wrong: %', r; end if;
  if (select assigned_role||'|'||store_note||'|'||source from public.role_survey_responses where import_key=repeat('b',64))<>'洛基|舊備註|sheet'
    then raise exception 'store columns not imported'; end if;
  r := public.system_import_role_surveys(jsonb_build_array(
    jsonb_build_object('script','QA王座','submitted_at','2026-09-01T12:00:00+08:00','import_key',repeat('b',64),
      'fields','[{"label":"Line名稱","value":"舊玩家"}]'::jsonb)));
  if r<>'{"imported":0,"skipped":1}'::jsonb then raise exception 'import not idempotent: %', r; end if;

  -- 刪除留下記號：重新匯入或同一送出編號重送都不會帶回來；稽核不含內容。
  select id into rid from public.role_survey_responses where import_key=repeat('b',64);
  perform public.admin_delete_role_survey(adm,rid);
  r := public.admin_import_role_surveys(adm, jsonb_build_array(
    jsonb_build_object('script','QA王座','submitted_at','2026-09-01T12:00:00+08:00','import_key',repeat('b',64),
      'fields','[{"label":"Line名稱","value":"舊玩家"}]'::jsonb)));
  if r<>'{"imported":0,"skipped":1}'::jsonb then raise exception 'deleted answer came back on import: %', r; end if;
  select id into rid from public.role_survey_responses where client_id=c;
  perform public.admin_delete_role_survey(adm,rid);
  r := public.submit_role_survey('QA王座','[{"label":"Line名稱","value":"阿明"}]',c);
  if exists(select 1 from public.role_survey_responses where client_id=c) then raise exception 'deleted answer came back on resend'; end if;
  if exists(select 1 from public.role_survey_tombstones where key like '%阿明%') or
     exists(select 1 from public.audit_logs where entity_type='role_survey_response' and details::text like '%先給雷神%')
    then raise exception 'deletion kept content'; end if;

  -- 排程工作一段時間只會被領一次。
  if not public.claim_scheduled_job('qa-job','6 hours') then raise exception 'first claim failed'; end if;
  if public.claim_scheduled_job('qa-job','6 hours') then raise exception 'claimed twice'; end if;
  update public.scheduled_jobs set last_run_at=now()-interval '7 hours' where name='qa-job';
  if not public.claim_scheduled_job('qa-job','6 hours') then raise exception 'not claimable after the interval'; end if;

  -- 灌爆防護：10 分鐘 30 份、一天 200 份或 5 MB。
  insert into public.role_survey_responses(script,fields) select 'QA王座','[{"label":"a","value":"b"}]'::jsonb from generate_series(1,30);
  begin perform public.submit_role_survey('QA王座','[{"label":"a","value":"b"}]'); raise exception 'flood not stopped';
  exception when raise_exception then if sqlerrm<>'TOO_MANY_REQUESTS' then raise; end if; end;
  update public.role_survey_responses set submitted_at=now()-interval '1 hour' where source='web';
  -- 150 rows (under the 200 count) of 10 × 5000-character answers: over 5 MB, so only the size cap stops this.
  if (select count(*) from public.role_survey_responses where source='web' and submitted_at>now()-interval '1 day')>=50 then
    raise exception 'setup: too many rows for a size-only test'; end if;
  insert into public.role_survey_responses(script,fields,submitted_at)
    select 'QA王座',(select jsonb_agg(jsonb_build_object('label','a'||n,'value',repeat('x',5000))) from generate_series(1,10) n),
      now()-interval '2 hours' from generate_series(1,150);
  begin perform public.submit_role_survey('QA王座','[{"label":"a","value":"b"}]'); raise exception 'daily size not stopped';
  exception when raise_exception then if sqlerrm<>'TOO_MANY_REQUESTS' then raise; end if; end;
end $$;
reset role;
do $$
declare r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    foreach f in array array['public.role_survey_responses','public.role_survey_tombstones','public.scheduled_jobs'] loop
      if has_table_privilege(r,f,'SELECT') or has_table_privilege(r,f,'INSERT') then raise exception '% exposed to %', f, r; end if;
    end loop;
    foreach f in array array['public.submit_role_survey(text,jsonb,uuid)','public.admin_role_survey_scripts(uuid)',
        'public.admin_role_survey_responses(uuid,text,integer,timestamptz,uuid)','public.admin_update_role_survey(uuid,uuid,text,text)',
        'public.admin_delete_role_survey(uuid,uuid)','public.admin_import_role_surveys(uuid,jsonb)',
        'public.system_import_role_surveys(jsonb)','public.claim_scheduled_job(text,interval)'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
  end loop;
  foreach f in array array['public.role_survey_responses','public.role_survey_tombstones','public.scheduled_jobs'] loop
    if not (select relrowsecurity from pg_class where oid=f::regclass) then raise exception 'RLS off on %', f; end if;
  end loop;
end $$;
select 'PASS: role survey answers cleaned like the Apps Script, catalog-only scripts, retry/delete-proof dedupe, keyset paging, store-only access, idempotent sheet import, flood and size guards, privileges' as result;
rollback;
