-- Run in Supabase SQL Editor after 202610020005_time_slots.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; u2 uuid; g uuid; r jsonb; msg text; gid uuid; raw_group uuid;
  d0 date := (now() at time zone 'Asia/Taipei')::date+1;
  sat date; mon date; wed date;
  sat_from timestamptz; sat_to timestamptz; mon_from timestamptz; mon_to timestamptz;
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000e0ad') returning id into adm;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000e001') returning id into org;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000e002') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,price_cents)
    values ('qa-slot-game','QA 劇本',2,6,60000) returning id into g;

  -- Upcoming Saturday, Monday and Wednesday (Taipei dates, always in the future).
  sat := d0+((6-extract(dow from d0)::int+7)%7);
  mon := d0+((1-extract(dow from d0)::int+7)%7);
  wed := d0+((3-extract(dow from d0)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date in (sat,mon,wed)) loop sat:=sat+7; mon:=mon+7; wed:=wed+7; end loop;
  sat_from := sat::timestamp at time zone 'Asia/Taipei'; sat_to := sat_from+interval '1 day';
  mon_from := mon::timestamp at time zone 'Asia/Taipei'; mon_to := mon_from+interval '1 day';

  -- 開放區間：週一二四五 19–24、週六 9–24、週日 13–24；每場 4 小時，整點開場且 24:00 前結束。
  if (select count(*) from public.slot_rules where active)<>6 or exists(select 1 from public.slot_rules where weekday=3)
    then raise exception 'store opening rules not seeded'; end if;
  r := public.list_available_starts(sat_from,sat_to);
  if jsonb_array_length(r)<>12
    or ((r->0->>'starts_at')::timestamptz at time zone 'Asia/Taipei')::time<>'09:00'
    or ((r->11->>'starts_at')::timestamptz at time zone 'Asia/Taipei')::time<>'20:00'
    or (r->11->>'ends_at')::timestamptz<>sat_to
    then raise exception 'Saturday starts wrong: %', r; end if;
  if jsonb_array_length(public.list_available_starts(mon_from,mon_to))<>2 then raise exception 'Monday should offer 19:00 and 20:00'; end if;
  if jsonb_array_length(public.list_available_starts(wed::timestamp at time zone 'Asia/Taipei',
      (wed+1)::timestamp at time zone 'Asia/Taipei'))<>0 then raise exception 'Wednesday must be closed'; end if;

  -- Outside the window, past midnight, off the hour or on a closed day is never bookable.
  begin
    perform public.create_group(org,gen_random_uuid(),(sat+time '21:00') at time zone 'Asia/Taipei',4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'past-midnight session: %', msg; end if;
  end;
  begin
    perform public.create_group(org,gen_random_uuid(),(sat+time '09:30') at time zone 'Asia/Taipei',4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'off-hour start: %', msg; end if;
  end;
  begin
    perform public.create_group(org,gen_random_uuid(),(wed+time '19:00') at time zone 'Asia/Taipei',4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'closed weekday: %', msg; end if;
  end;

  -- Google 日曆有活動（例如週一 18:30–19:30 家庭聚餐）就不顯示有空。
  perform public.sync_calendar_busy(now(),now()+interval '30 days',jsonb_build_array(jsonb_build_object(
    'start',(mon+time '18:30') at time zone 'Asia/Taipei','end',(mon+time '19:30') at time zone 'Asia/Taipei')));
  r := public.list_available_starts(mon_from,mon_to);
  if jsonb_array_length(r)<>1 or ((r->0->>'starts_at')::timestamptz at time zone 'Asia/Taipei')::time<>'20:00'
    then raise exception 'busy period not respected: %', r; end if;
  perform public.sync_calendar_busy(now(),now()+interval '30 days',jsonb_build_array(
    jsonb_build_object('start',(mon+time '18:30') at time zone 'Asia/Taipei','end',(mon+time '19:30') at time zone 'Asia/Taipei'),
    jsonb_build_object('start',(mon+time '22:00') at time zone 'Asia/Taipei','end',(mon+time '23:00') at time zone 'Asia/Taipei')));
  if jsonb_array_length(public.list_available_starts(mon_from,mon_to))<>0 then raise exception 'Monday should be fully busy'; end if;
  begin
    perform public.create_group(org,gen_random_uuid(),(mon+time '20:00') at time zone 'Asia/Taipei',4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'busy time bookable: %', msg; end if;
  end;
  -- Re-syncing replaces the window: the dinner was removed from the calendar.
  perform public.sync_calendar_busy(now(),now()+interval '30 days','[]');
  if jsonb_array_length(public.list_available_starts(mon_from,mon_to))<>2 then raise exception 'busy sync did not replace window'; end if;
  -- Syncing a narrow window keeps the parts of longer busy periods outside it.
  perform public.sync_calendar_busy(sat_from,sat_to,jsonb_build_array(jsonb_build_object('start',sat_from,'end',sat_to)));
  perform public.sync_calendar_busy((sat+time '09:00') at time zone 'Asia/Taipei',(sat+time '13:00') at time zone 'Asia/Taipei','[]');
  if jsonb_array_length(public.list_available_starts(sat_from,sat_to))<>1 then raise exception 'partial sync lost busy time'; end if;
  perform public.sync_calendar_busy(sat_from,sat_to,'[]');

  -- 同一時間只能一場：週六 13:00 開團後，與 13–17 重疊的開場時間全部消失。
  r := public.create_group(org,gen_random_uuid(),(sat+time '13:00') at time zone 'Asia/Taipei',4,g);
  gid := (r->>'group_id')::uuid;
  if (select status from public.time_slots where group_id=gid)<>'held' then raise exception 'time not held'; end if;
  r := public.list_available_starts(sat_from,sat_to);
  if jsonb_array_length(r)<>5 then raise exception 'overlapping starts still listed: %', r; end if;
  begin
    perform public.create_group(u2,gen_random_uuid(),(sat+time '15:00') at time zone 'Asia/Taipei',4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'overlapping group: %', msg; end if;
  end;
  -- Even if two requests pass the check at once, the database rejects the overlap.
  insert into public.groups(organizer_user_id,desired_start_at,capacity,request_id)
    values (u2,(sat+time '14:00') at time zone 'Asia/Taipei',4,gen_random_uuid()) returning id into raw_group;
  begin
    perform public._sf_reserve_time((sat+time '14:00') at time zone 'Asia/Taipei',(sat+time '18:00') at time zone 'Asia/Taipei',
      'held',raw_group,null);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'race not blocked: %', msg; end if;
  end;

  -- 解散後時段釋出；成場後轉為 booked。
  perform public.cancel_group(org,gid);
  if (select status from public.time_slots where group_id=gid)<>'released'
    or jsonb_array_length(public.list_available_starts(sat_from,sat_to))<>12 then raise exception 'time not released'; end if;
  r := public.create_group(u2,gen_random_uuid(),(sat+time '13:00') at time zone 'Asia/Taipei',4,g);
  r := public.admin_confirm_group_event(adm,(r->>'group_id')::uuid,'QA 場館','QA DM');
  if (select status from public.time_slots where event_id=(r->>'event_id')::uuid)<>'booked'
    or (select starts_at from public.events where id=(r->>'event_id')::uuid)<>(sat+time '13:00') at time zone 'Asia/Taipei'
    then raise exception 'confirmed event not booked'; end if;

  -- 店家可在開放區間外開場，但仍不可撞到其他場次或日曆。
  r := public.admin_create_event(adm,(wed+time '19:00') at time zone 'Asia/Taipei',g,6,'QA 場館','QA DM');
  begin
    perform public.admin_create_event(adm,(wed+time '21:00') at time zone 'Asia/Taipei',g,6,'QA 場館','QA DM');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'admin overlap: %', msg; end if;
  end;
  begin
    perform public.admin_create_event(org,(wed+time '09:00') at time zone 'Asia/Taipei',g,6,'QA 場館','QA DM');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'non-admin event: %', msg; end if;
  end;
  begin
    perform public.admin_create_event(adm,now()-interval '1 day',g,6,'QA 場館','QA DM');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'past event: %', msg; end if;
  end;
end $$;
reset role;
do $$
declare t text; r text;
begin
  foreach t in array array['slot_rules','time_slots','calendar_busy'] loop
    if not (select relrowsecurity from pg_class where oid=('public.'||t)::regclass)
      then raise exception 'RLS missing on %', t; end if;
    foreach r in array array['anon','authenticated'] loop
      if has_table_privilege(r,'public.'||t,'SELECT,INSERT,UPDATE,DELETE') then raise exception '% exposed to %', t, r; end if;
      if has_function_privilege(r,'public.list_available_starts(timestamptz,timestamptz,integer)','EXECUTE')
        or has_function_privilege(r,'public.sync_calendar_busy(timestamptz,timestamptz,jsonb)','EXECUTE')
        then raise exception 'slot RPC exposed to %', r; end if;
    end loop;
  end loop;
end $$;
select 'PASS: opening windows, Taipei time, midnight limit, calendar busy, one session at a time, release, confirm, admin event' as result;
rollback;
