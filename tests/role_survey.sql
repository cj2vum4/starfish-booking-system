-- Run in Supabase SQL Editor after 202610110035_role_survey.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; pl uuid; r jsonb; rid uuid; n integer; k text := repeat('a',64);
begin
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000005a01','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000005a02','玩家','active') returning id into pl;
  insert into public.admin_users(user_id) values (adm);

  -- 送出：多選用「, 」串、數字轉文字、空白標題略過、前後空白去掉；與 Apps Script 相同的上限。
  r := public.submit_role_survey(' QA王座 ', jsonb_build_array(
    jsonb_build_object('label',' Line名稱 ','value','阿明'),
    jsonb_build_object('label','喜歡的類型','value',jsonb_build_array('推理','情感')),
    jsonb_build_object('label','邏輯','value',4),
    jsonb_build_object('label','  ','value','沒有標題'),
    jsonb_build_object('label','長答案','value',repeat('字',6000)),
    jsonb_build_object('label','公式','value','=HYPERLINK("x")')));
  rid := (r->>'id')::uuid;
  select fields into r from public.role_survey_responses where id=rid;
  if r <> jsonb_build_array(jsonb_build_object('label','Line名稱','value','阿明'),
      jsonb_build_object('label','喜歡的類型','value','推理, 情感'), jsonb_build_object('label','邏輯','value','4'),
      jsonb_build_object('label','長答案','value',repeat('字',5000)), jsonb_build_object('label','公式','value','=HYPERLINK("x")'))
    then raise exception 'fields not cleaned as expected: %', r; end if;
  if (select script from public.role_survey_responses where id=rid)<>'QA王座' then raise exception 'script not trimmed'; end if;

  -- 不合格的送出整筆拒絕。
  foreach k in array array['null','{}','[]','[{"label":"","value":"x"}]','[1,2]'] loop
    begin
      perform public.submit_role_survey('QA王座', k::jsonb);
      raise exception 'accepted bad fields %', k;
    exception when raise_exception then
      if sqlerrm<>'INVALID_SURVEY' then raise; end if;
    end;
  end loop;
  begin perform public.submit_role_survey('', '[{"label":"a","value":"b"}]'); raise exception 'accepted empty script';
  exception when raise_exception then if sqlerrm<>'INVALID_SURVEY' then raise; end if; end;

  -- 只有店家能讀、改、刪、匯入。
  begin perform public.admin_role_survey_scripts(pl); raise exception 'player listed surveys';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_role_survey_responses(pl,'QA王座'); raise exception 'player read answers';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_update_role_survey(pl,rid,'雷神',''); raise exception 'player assigned a role';
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

  -- 分頁：新的在前，p_before 繼續往前翻。
  perform public.submit_role_survey('QA王座','[{"label":"Line名稱","value":"小華"}]');
  update public.role_survey_responses set submitted_at=now()-interval '1 day' where id=rid;
  r := public.admin_role_survey_responses(adm,'QA王座',1);
  if jsonb_array_length(r)<>1 or r->0->'fields'->0->>'value'<>'小華' then raise exception 'newest first failed: %', r; end if;
  r := public.admin_role_survey_responses(adm,'QA王座',1,(r->0->>'submitted_at')::timestamptz);
  if jsonb_array_length(r)<>1 or (r->0->>'id')::uuid<>rid then raise exception 'paging failed: %', r; end if;

  -- 匯入：同一列只進來一次；壞掉的列略過不擋其他列。
  r := public.admin_import_role_surveys(adm, jsonb_build_array(
    jsonb_build_object('script','QA王座','submitted_at','2026-09-01T12:00:00+08:00','import_key',repeat('b',64),
      'fields','[{"label":"Line名稱","value":"舊玩家"}]'::jsonb),
    jsonb_build_object('script','QA王座','submitted_at','not a date','import_key',repeat('c',64),'fields','[{"label":"a","value":"b"}]'::jsonb),
    jsonb_build_object('script','QA王座','submitted_at','2026-09-02T12:00:00+08:00','import_key','short','fields','[{"label":"a","value":"b"}]'::jsonb),
    jsonb_build_object('script','QA王座','submitted_at','2026-09-03T12:00:00+08:00','import_key',repeat('d',64),'fields','[]'::jsonb)));
  if r<>'{"imported":1,"skipped":3}'::jsonb then raise exception 'import counts wrong: %', r; end if;
  r := public.admin_import_role_surveys(adm, jsonb_build_array(
    jsonb_build_object('script','QA王座','submitted_at','2026-09-01T12:00:00+08:00','import_key',repeat('b',64),
      'fields','[{"label":"Line名稱","value":"舊玩家"}]'::jsonb)));
  if r<>'{"imported":0,"skipped":1}'::jsonb then raise exception 'import not idempotent: %', r; end if;
  if (select source from public.role_survey_responses where import_key=repeat('b',64))<>'sheet' then raise exception 'source not sheet'; end if;

  -- 刪除。
  perform public.admin_delete_role_survey(adm,rid);
  if exists(select 1 from public.role_survey_responses where id=rid) then raise exception 'not deleted'; end if;
  if exists(select 1 from public.audit_logs where entity_id=rid and details::text like '%先給雷神%') then raise exception 'audit kept content'; end if;

  -- 灌爆防護：10 分鐘內網站送出 200 份後暫停。
  insert into public.role_survey_responses(script,fields) select 'QA灌爆','[{"label":"a","value":"b"}]'::jsonb from generate_series(1,200);
  begin perform public.submit_role_survey('QA王座','[{"label":"a","value":"b"}]'); raise exception 'flood not stopped';
  exception when raise_exception then if sqlerrm<>'TOO_MANY_REQUESTS' then raise; end if; end;
end $$;
reset role;
do $$
declare r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_table_privilege(r,'public.role_survey_responses','SELECT') or has_table_privilege(r,'public.role_survey_responses','INSERT') then
      raise exception 'answers exposed to %', r; end if;
    foreach f in array array['public.submit_role_survey(text,jsonb)','public.admin_role_survey_scripts(uuid)',
        'public.admin_role_survey_responses(uuid,text,integer,timestamptz)','public.admin_update_role_survey(uuid,uuid,text,text)',
        'public.admin_delete_role_survey(uuid,uuid)','public.admin_import_role_surveys(uuid,jsonb)'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
  end loop;
  if not (select relrowsecurity from pg_class where oid='public.role_survey_responses'::regclass) then raise exception 'RLS off'; end if;
end $$;
select 'PASS: role survey answers cleaned like the Apps Script, store-only reads/edits/deletes, idempotent sheet import, flood guard, privileges' as result;
rollback;
