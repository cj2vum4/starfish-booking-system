-- Run in Supabase SQL Editor after 202610030009_confirm_and_calendar.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; g4 uuid; g6 uuid; g35 uuid; g7 uuid; ga uuid; gb uuid; gc uuid; gd uuid; r jsonb; msg text;
  sat date; sun date; ev uuid;
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c0ad','店長') returning id into adm;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c0b1','主揪阿明') returning id into org;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values
    ('qa-c-4h','QA 四小時',4,6,240) returning id into g4;
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values
    ('qa-c-6h','QA 六小時',4,6,360) returning id into g6;
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values
    ('qa-c-35h','QA 三個半',4,6,210) returning id into g35;
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values
    ('qa-c-7p','QA 七人本',7,7,240) returning id into g7;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released'
    and (starts_at at time zone 'Asia/Taipei')::date in (sat,sat+1)) loop sat:=sat+7; end loop;
  sun := sat+1;

  -- 店家推薦團保留 4 小時；確認 6 小時的本時，後面空著就延長。
  ga := (public.create_group(org,gen_random_uuid(),(sat+time '13:00') at time zone 'Asia/Taipei',5)->>'group_id')::uuid;
  begin
    perform public.admin_list_groups(org);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'non-admin list: %', msg; end if;
  end;
  if not exists(select 1 from jsonb_array_elements(public.admin_list_groups(adm)) x where (x->>'group_id')::uuid=ga)
    then raise exception 'admin list missing group'; end if;
  r := public.admin_confirm_group_event(adm,ga,'海星劇本殺','店長',g6,60000);
  ev := (r->>'event_id')::uuid;
  if (select ends_at from public.time_slots where event_id=ev)<>(sat+time '19:00') at time zone 'Asia/Taipei'
    then raise exception 'slot not extended for longer script'; end if;
  if exists(select 1 from jsonb_array_elements(public.list_available_starts(sat::timestamp at time zone 'Asia/Taipei',
      (sat+1)::timestamp at time zone 'Asia/Taipei')) x where (x->>'starts_at')::timestamptz between
      ((sat+time '10:00') at time zone 'Asia/Taipei') and ((sat+time '18:00') at time zone 'Asia/Taipei'))
    then raise exception 'extended time still offered'; end if;

  -- 延長會撞到下一團，或撞到 Google 日曆的行程時，不准成團，原團保持招募中。
  gb := (public.create_group(org,gen_random_uuid(),(sat+time '09:00') at time zone 'Asia/Taipei',5)->>'group_id')::uuid;
  begin
    perform public.admin_confirm_group_event(adm,gb,'海星劇本殺','店長',g6,60000);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'extension over next group: %', msg; end if;
  end;
  if (select status from public.groups where id=gb)<>'recruiting'
    or (select ends_at from public.time_slots where group_id=gb)<>(sat+time '13:00') at time zone 'Asia/Taipei'
    then raise exception 'failed confirm changed the group'; end if;
  gc := (public.create_group(org,gen_random_uuid(),(sun+time '13:00') at time zone 'Asia/Taipei',5)->>'group_id')::uuid;
  perform public.sync_calendar_busy(now(),now()+interval '40 days',jsonb_build_array(jsonb_build_object(
    'start',(sun+time '17:30') at time zone 'Asia/Taipei','end',(sun+time '18:00') at time zone 'Asia/Taipei')));
  begin
    perform public.admin_confirm_group_event(adm,gc,'海星劇本殺','店長',g6,60000);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'extension over calendar busy: %', msg; end if;
  end;

  -- 較短的本會釋出多保留的時間。
  r := public.admin_confirm_group_event(adm,gc,'海星劇本殺','店長',g35,55000);
  if (select ends_at from public.time_slots where event_id=(r->>'event_id')::uuid)<>(sun+time '16:30') at time zone 'Asia/Taipei'
    then raise exception 'slot not shortened'; end if;

  -- 人數不合劇本、缺場地或 DM 都擋下。
  gd := (public.create_group(org,gen_random_uuid(),(sun+time '18:00') at time zone 'Asia/Taipei',4)->>'group_id')::uuid;
  begin
    perform public.admin_confirm_group_event(adm,gd,'海星劇本殺','店長',g7,60000);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_CAPACITY' then raise exception 'capacity mismatch: %', msg; end if;
  end;
  begin
    perform public.admin_confirm_group_event(adm,gd,' ','店長',g4,60000);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_VENUE' then raise exception 'blank venue: %', msg; end if;
  end;

  -- 寫入 Google 日曆需要的資料；寫入後標記，摘要顯示已同步。
  r := public.event_calendar_payload(ev);
  if r->>'title'<>'QA 六小時' or r->>'organizer_name'<>'主揪阿明' or (r->>'ends_at')::timestamptz<>(sat+time '19:00') at time zone 'Asia/Taipei'
    or jsonb_array_length(r->'players')<>1 or (r->>'price_cents')::int<>60000 then raise exception 'payload wrong: %', r; end if;
  begin
    perform public.mark_event_calendar_synced(ev,'BAD-ID!');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_CALENDAR_ID' then raise exception 'bad calendar id: %', msg; end if;
  end;
  perform public.mark_event_calendar_synced(ev,replace(ev::text,'-',''));
  r := public.get_group(adm,ga);
  if r->>'status'<>'confirmed' or not (r->'event'->>'calendar_synced')::boolean or r->'event'->>'venue'<>'海星劇本殺'
    then raise exception 'confirmed summary wrong: %', r; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.event_calendar_payload(uuid)','EXECUTE')
      or has_function_privilege(r,'public.mark_event_calendar_synced(uuid,text)','EXECUTE')
      or has_function_privilege(r,'public.admin_list_groups(uuid)','EXECUTE')
      then raise exception 'confirm RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: admin list, extend for longer script, blocked by next group or calendar, shorten, validation, calendar payload' as result;
rollback;
