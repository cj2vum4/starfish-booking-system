-- Run in Supabase SQL Editor after 202610030007_game_catalog.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; r jsonb; msg text; long_id uuid; gid uuid; sat date; mon date;
  catalog jsonb := '[
    {"slug":"qa-wangzuo","title":"QA 王座","min_players":7,"max_players":7,"duration_minutes":270,"genres":["陣營","機制"],
     "difficulty":"2","players_label":"4男3女","image_url":"https://example.com/a.jpg","source_url":"https://example.com/a.html"},
    {"slug":"qa-gaoqian","title":"QA 搞錢","min_players":7,"max_players":10,"duration_minutes":300,"genres":["歡樂"],"difficulty":"1"},
    {"slug":"qa-long","title":"QA 長本","min_players":6,"max_players":6,"duration_minutes":360,"genres":["推理"],"difficulty":"4"}]';
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000a0ad') returning id into adm;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000a0b1') returning id into org;
  insert into public.admin_users(user_id) values (adm);
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  mon := (now() at time zone 'Asia/Taipei')::date+1; mon := mon+((1-extract(dow from mon)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date in (sat,mon)) loop sat:=sat+7; mon:=mon+7; end loop;

  -- 只有店家能同步；格式錯誤的資料整批拒絕。
  begin
    perform public.admin_sync_games(org,catalog);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'non-admin sync: %', msg; end if;
  end;
  begin
    perform public.admin_sync_games(adm,catalog||'[{"slug":"Bad Slug","title":"x","min_players":2,"max_players":2,"duration_minutes":240}]');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_CATALOG' then raise exception 'bad catalog accepted: %', msg; end if;
  end;
  if exists(select 1 from public.games where slug like 'qa-%') then raise exception 'partial sync left rows'; end if;

  r := public.admin_sync_games(adm,catalog);
  if (r->>'synced')::int<>3 then raise exception 'sync count wrong: %', r; end if;
  r := public.list_active_games();
  if not exists(select 1 from jsonb_array_elements(r) g where g->>'slug'='qa-gaoqian'
      and (g->>'min_players')::int=7 and (g->>'max_players')::int=10 and (g->>'duration_minutes')::int=300)
    then raise exception 'range game not listed correctly'; end if;
  if not exists(select 1 from jsonb_array_elements(r) g where g->>'slug'='qa-wangzuo'
      and g->>'image_url'='https://example.com/a.jpg' and g->'genres' ? '陣營') then raise exception 'details missing'; end if;

  -- GitHub 移除的劇本只停用不刪除；更名會更新。
  r := public.admin_sync_games(adm,jsonb_build_array(catalog->0 || '{"title":"QA 王座 新版"}'::jsonb, catalog->2));
  if (r->>'deactivated')::int<>1 or (select active from public.games where slug='qa-gaoqian')
    or (select title from public.games where slug='qa-wangzuo')<>'QA 王座 新版' then raise exception 'resync wrong: %', r; end if;

  -- 6 小時的劇本放不進平日 19–24，只能排週末。
  select id into long_id from public.games where slug='qa-long';
  if jsonb_array_length(public.list_available_starts(mon::timestamp at time zone 'Asia/Taipei',
      (mon+1)::timestamp at time zone 'Asia/Taipei',360))<>0 then raise exception 'long script offered on weekday'; end if;
  if jsonb_array_length(public.list_available_starts(sat::timestamp at time zone 'Asia/Taipei',
      (sat+1)::timestamp at time zone 'Asia/Taipei',360))<>10 then raise exception 'Saturday should offer 09:00-18:00 starts'; end if;
  begin
    perform public.create_group(org,gen_random_uuid(),(mon+time '19:00') at time zone 'Asia/Taipei',6,long_id);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'long script booked on weekday: %', msg; end if;
  end;
  r := public.create_group(org,gen_random_uuid(),(sat+time '10:00') at time zone 'Asia/Taipei',6,long_id);
  gid := (r->>'group_id')::uuid;
  if (r->>'ends_at')::timestamptz<>(sat+time '16:00') at time zone 'Asia/Taipei' then raise exception 'long session length wrong'; end if;

  -- 成團時必須有價格（GitHub 沒有價格）。
  begin
    perform public.admin_confirm_group_event(adm,gid,'QA 場館','QA DM');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'PRICE_REQUIRED' then raise exception 'missing price accepted: %', msg; end if;
  end;
  r := public.admin_confirm_group_event(adm,gid,'QA 場館','QA DM',null,65000);
  if (select price_cents from public.events where id=(r->>'event_id')::uuid)<>65000 then raise exception 'price not applied'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.admin_sync_games(uuid,jsonb)','EXECUTE') then raise exception 'sync exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: admin-only sync, atomic validation, ranges, resync deactivates, long scripts weekend only, price required' as result;
rollback;
