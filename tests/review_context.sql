-- Run in Supabase SQL Editor after 202610030016_play_history.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; u2 uuid; u3 uuid; g uuid; g2 uuid; ev uuid; gid uuid; r jsonb; msg text;
  p_org uuid; p_u3 uuid; sat date;
begin
  delete from public.calendar_busy;  -- isolation from real data; rolled back
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000a9ad','店長') returning id into adm;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000a9b1','主揪') returning id into org;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000a9b2','小華') returning id into u2;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000a9b3','小美') returning id into u3;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-hist-1','QA 歷史一',2,6,240) returning id into g;
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-hist-2','QA 歷史二',2,6,240) returning id into g2;

  -- A public session: organizer books self + friend placeholder, two others join.
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '2 days',6,40000,'南港','海星') returning id into ev;
  perform public.create_booking(org,ev,gen_random_uuid(),'[{"self":true},{"display_name":"朋友A"}]');
  perform public.join_event(u2,ev,gen_random_uuid());
  perform public.join_event(u3,ev,gen_random_uuid());

  -- 開始前不能結束；只有店家能記錄出席。
  begin
    perform public.admin_complete_event(adm,ev);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'EVENT_NOT_STARTED' then raise exception 'completed before start: %', msg; end if;
  end;
  update public.events set starts_at=now()-interval '5 hours' where id=ev;
  begin
    perform public.admin_complete_event(org,ev);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'organizer completed: %', msg; end if;
  end;

  r := public.admin_event_participants(adm,ev);
  if jsonb_array_length(r)<>4 then raise exception 'attendance sheet wrong: %', r; end if;
  select bp.id into p_u3 from public.booking_participants bp join public.players p on p.id=bp.player_id where bp.event_id=ev and p.user_id=u3;

  -- 小美缺席：其餘 3 人（含沒有 LINE 的朋友A）寫入紀錄。
  r := public.admin_complete_event(adm,ev,array[p_u3]);
  if (r->>'attended')::int<>3 or (r->>'absent')::int<>1 then raise exception 'complete counts wrong: %', r; end if;
  if (select status from public.events where id=ev)<>'completed' then raise exception 'event not completed'; end if;
  if (select status||'/'||attendance from public.booking_participants where id=p_u3)<>'no_show/absent' then raise exception 'absence not recorded'; end if;
  if (public.admin_complete_event(adm,ev)->>'completed')::boolean then raise exception 'complete not idempotent'; end if;

  -- 玩後問卷改由店家現場給 QR code，記錄出席不再發 LINE 提醒。
  if exists(select 1 from public.notification_logs where event_id=ev and notification_type='review_reminder')
    then raise exception 'review reminder still queued'; end if;
  -- 既有的 LINE 歸戶名仍擋住別人用同一名字綁定。
  insert into public.line_record_accounts(user_id,record_name) values(u2,'QA LINE記錄');
  if public.my_record_account(u2)<>'QA LINE記錄' or public.my_record_account(u3) is not null then raise exception 'record account scope failed'; end if;
  if not(public.bound_record_names() ? 'QA LINE記錄') then raise exception 'record account claimable'; end if;
  begin
    insert into public.player_bindings(user_id,record_name,status) values(u3,'QA LINE記錄','approved');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NAME_TAKEN' then raise exception 'record identity stolen: %',msg; end if;
  end;
  if to_regclass('public.record_submissions') is not null or to_regprocedure('public.my_review_context(uuid,uuid)') is not null
    or to_regprocedure('public.save_record_account(uuid,text)') is not null then raise exception 'LINE review flow not removed'; end if;
  -- A group session awaiting attendance stays on the store list after it starts.
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;
  gid := (public.create_group(org,gen_random_uuid(),(sat+time '14:00') at time zone 'Asia/Taipei',2,g)->>'group_id')::uuid;
  perform public.admin_confirm_group_event(adm,gid,'南港','海星',null,40000);
  update public.groups set desired_start_at=now()-interval '3 days' where id=gid;
  if not exists(select 1 from jsonb_array_elements(public.admin_list_groups(adm)) x where (x->>'group_id')::uuid=gid)
    then raise exception 'pending attendance dropped from store list'; end if;

  r := public.list_my_history(u2);
  if jsonb_array_length(r)<>1 or r->0->>'title'<>'QA 歷史一' or r->0->>'venue'<>'南港' then raise exception 'history wrong: %', r; end if;
  if jsonb_array_length(public.list_my_history(u3))<>0 then raise exception 'absent player got history'; end if;
  if not (public.my_played_games(org) ? g::text) or (public.my_played_games(u3) ? g::text) then raise exception 'played set wrong'; end if;

  -- 下一團：店家與主揪看得到團內誰玩過哪本；陌生人看不到。
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;
  gid := (public.create_group(org,gen_random_uuid(),(sat+time '09:00') at time zone 'Asia/Taipei',4,null,'{}','','public')->>'group_id')::uuid;
  perform public.join_group(u2,gid);
  perform public.join_group(u3,gid);
  r := public.group_played_games(adm,gid);
  if jsonb_array_length(r->(g::text))<>2 or r ? g2::text then raise exception 'group played map wrong: %', r; end if;
  if jsonb_array_length(public.group_played_games(org,gid)->(g::text))<>2 then raise exception 'organizer cannot see played map'; end if;
  begin
    perform public.group_played_games(u3,gid);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_NOT_FOUND' then raise exception 'member saw played map: %', msg; end if;
  end;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_table_privilege(r,'public.line_record_accounts','SELECT') or
      has_function_privilege(r,'public.my_record_account(uuid)','EXECUTE') then raise exception 'record identity exposed to %',r; end if;
    if has_function_privilege(r,'public.admin_complete_event(uuid,uuid,uuid[])','EXECUTE')
      or has_function_privilege(r,'public.list_my_history(uuid)','EXECUTE')
      or has_function_privilege(r,'public.group_played_games(uuid,uuid)','EXECUTE')
      then raise exception 'history RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: attendance sheet, not before start, admin only, absent excluded, idempotent, my history, played sets' as result;
rollback;
