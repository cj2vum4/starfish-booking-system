-- Run in Supabase SQL Editor after 202610210043_role_survey_match.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; pl uuid; r jsonb; ids uuid[] := '{}'; rid uuid; i integer; f text; d date := (now() at time zone 'Asia/Taipei')::date+7;
  day text := to_char((now() at time zone 'Asia/Taipei')::date+7,'YYYY-MM-DD');
begin
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000005b01','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000005b02','玩家','active') returning id into pl;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes,review_key,active)
    values ('qa-match','QA群星',3,3,300,'QA群星',false);

  -- 遊玩日期：標題含「日期」的第一題；各種寫法都認得，讀不懂就不分場次。
  if public._sf_survey_play_date('[{"label":"名字","value":"a"},{"label":"遊玩日期","value":"2026-10-25"}]')<>date '2026-10-25'
    or public._sf_survey_play_date('[{"label":"你預約玩本的日期","value":"2026/1/5"}]')<>date '2026-01-05'
    or public._sf_survey_play_date('[{"label":"預約日期","value":"2026年10月25日 晚上"}]')<>date '2026-10-25'
    or public._sf_survey_play_date('[{"label":"預約日期","value":""},{"label":"日期2","value":"2026-11-01"}]')<>date '2026-11-01'
    or public._sf_survey_play_date('[{"label":"預約日期","value":"下週六"}]') is not null
    or public._sf_survey_play_date('[{"label":"預約日期","value":"2026-02-31"}]') is not null
    or public._sf_survey_play_date('[{"label":"名字","value":"2026-10-25"}]') is not null then
    raise exception 'play date parsing wrong';
  end if;

  -- 三人本：第 3 份網站回覆到齊才通知店家，且只通知一次；同一天別本、沒填日期、過去的場次、匯入的列都不算。
  for i in 1..2 loop
    r := public.submit_role_survey('QA群星', jsonb_build_array(jsonb_build_object('label','名字','value','玩家'||i),
      jsonb_build_object('label','遊玩日期','value',day)), gen_random_uuid());
    ids := ids || (r->>'id')::uuid;
  end loop;
  perform public.submit_role_survey('QA群星','[{"label":"名字","value":"沒填日期"}]', gen_random_uuid());
  insert into public.role_survey_responses(script,fields,source,import_key)
    values ('QA群星', jsonb_build_array(jsonb_build_object('label','遊玩日期','value','2020-01-01')),'sheet',repeat('a',64));
  if (select play_date from public.role_survey_responses where id=ids[1])<>d then raise exception 'play date not stored'; end if;
  if exists(select 1 from public.notification_logs where notification_type='role_survey_complete') then
    raise exception 'notified before the session was full'; end if;
  r := public.submit_role_survey('QA群星', jsonb_build_array(jsonb_build_object('label','名字','value','玩家3'),
    jsonb_build_object('label','遊玩日期','value',day)), gen_random_uuid());
  ids := ids || (r->>'id')::uuid;
  select payload into r from public.notification_logs where notification_type='role_survey_complete' and user_id=adm;
  if r is null or r->>'script'<>'QA群星' or (r->>'play_date')::date<>d or (r->>'count')::int<>3 or (r->>'players')::int<>3 then
    raise exception 'store not told the session is complete: %', r; end if;
  if exists(select 1 from public.notification_logs where notification_type='role_survey_complete' and user_id=pl) then
    raise exception 'a player was notified'; end if;
  perform public.submit_role_survey('QA群星', jsonb_build_array(jsonb_build_object('label','遊玩日期','value',day)), gen_random_uuid());
  if (select count(*) from public.notification_logs where notification_type='role_survey_complete')<>1 then
    raise exception 'a 4th answer notified again'; end if;
  insert into public.role_survey_responses(script,fields,submitted_at)
    select 'QA群星', jsonb_build_array(jsonb_build_object('label','遊玩日期','value','2020-01-01')), now() from generate_series(1,3);
  if (select count(*) from public.notification_logs where notification_type='role_survey_complete')<>1 then
    raise exception 'a past session notified'; end if;
  -- 改了答案（日期）會重算場次。
  update public.role_survey_responses set fields='[{"label":"遊玩日期","value":"2027-01-02"}]' where id=ids[3];
  if (select play_date from public.role_survey_responses where id=ids[3])<>date '2027-01-02' then raise exception 'date not recomputed'; end if;
  update public.role_survey_responses set fields=jsonb_build_array(jsonb_build_object('label','名字','value','玩家3'),
    jsonb_build_object('label','遊玩日期','value',day)) where id=ids[3];

  -- 場次清單與挑出要配對的回覆：只有店家。
  begin perform public.admin_role_survey_sessions(pl,'QA群星'); raise exception 'player listed sessions';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_role_survey_pick(pl,'QA群星',d); raise exception 'player picked answers';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_assign_role_surveys(pl,jsonb_build_array(jsonb_build_object('id',ids[1],'role','x'))); raise exception 'player assigned';
  exception when raise_exception then if sqlerrm<>'NOT_ADMIN' then raise; end if; end;

  -- 同一個交易裡 now() 都一樣：給每份不同的填寫時間，「先填的在前」才看得出來。
  for i in 1..3 loop
    update public.role_survey_responses set submitted_at=now()-make_interval(hours=>10-i) where id=ids[i];
  end loop;
  r := public.admin_role_survey_sessions(adm,'QA群星');
  if (r->>'players')::int<>3 or jsonb_array_length(r->'sessions')<>1 or (r->'sessions'->0->>'play_date')::date<>d
     or (r->'sessions'->0->>'total')::int<>4 then raise exception 'sessions wrong: %', r; end if;
  r := public.admin_role_survey_pick(adm,'QA群星',d);
  if jsonb_array_length(r)<>4 or (r->0->>'id')::uuid<>ids[1] or (r->0->>'play_date')::date<>d then raise exception 'pick by date wrong: %', r; end if;
  r := public.admin_role_survey_pick(adm,'QA群星',null,array[ids[2],ids[1],gen_random_uuid()]);
  if jsonb_array_length(r)<>2 or (r->0->>'id')::uuid<>ids[1] then raise exception 'pick by ids wrong: %', r; end if;
  if jsonb_array_length(public.admin_role_survey_pick(adm,'別本',null,ids))<>0 then raise exception 'picked another script'; end if;
  foreach f in array array['both','neither'] loop
    begin
      if f='both' then perform public.admin_role_survey_pick(adm,'QA群星',d,ids); else perform public.admin_role_survey_pick(adm,'QA群星'); end if;
      raise exception 'accepted % filters', f;
    exception when raise_exception then if sqlerrm<>'INVALID_SURVEY' then raise; end if; end;
  end loop;

  -- 套用配對：一次寫好每份的角色，備註不動；有一份找不到就整批不套用。
  update public.role_survey_responses set store_note='早到' where id=ids[1];
  r := public.admin_assign_role_surveys(adm, jsonb_build_array(jsonb_build_object('id',ids[1],'role',' 張北斗 '),
    jsonb_build_object('id',ids[2],'role','貝斯')));
  if (r->>'updated')::int<>2 or (select assigned_role||'/'||store_note from public.role_survey_responses where id=ids[1])<>'張北斗/早到'
     or (select assigned_role from public.role_survey_responses where id=ids[2])<>'貝斯' then raise exception 'assign wrong: %', r; end if;
  begin
    perform public.admin_assign_role_surveys(adm, jsonb_build_array(jsonb_build_object('id',ids[3],'role','伊萬'),
      jsonb_build_object('id',gen_random_uuid(),'role','x')));
    raise exception 'assigned with a missing answer';
  exception when raise_exception then if sqlerrm<>'SURVEY_NOT_FOUND' then raise; end if; end;
  if (select assigned_role from public.role_survey_responses where id=ids[3])<>'' then raise exception 'half-applied batch'; end if;
  foreach f in array array['[]','{}','[{"id":"x","role":"a"}]'] loop
    begin perform public.admin_assign_role_surveys(adm, f::jsonb); raise exception 'accepted %', f;
    exception when raise_exception then if sqlerrm<>'INVALID_SURVEY' then raise; end if; end;
  end loop;
  if (select (x->>'unassigned')::int from jsonb_array_elements(public.admin_role_survey_sessions(adm,'QA群星')->'sessions') x)<>2 then
    raise exception 'unassigned count wrong'; end if;
end $$;

do $$
declare r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    foreach f in array array['public._sf_survey_play_date(jsonb)','public.admin_role_survey_sessions(uuid,text)',
        'public.admin_role_survey_pick(uuid,text,date,uuid[])','public.admin_assign_role_surveys(uuid,jsonb)'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
  end loop;
end $$;
select 'PASS: play dates parsed from answers, store told once when a session fills, sessions and picks store-only, all-or-nothing role assignment, privileges' as result;
rollback;
