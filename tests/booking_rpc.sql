-- Run in Supabase SQL Editor after 202610020003_booking_rpc.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  org uuid; u2 uuid; u3 uuid; u4 uuid; u5 uuid; u6 uuid; u7 uuid; adm uuid;
  g uuid; gid uuid; ev uuid; ev2 uuid; grp2 uuid; slot1 timestamptz; slot2 timestamptz; sat date; req uuid := gen_random_uuid();
  r jsonb; msg text; seat6 uuid; hanhan uuid; part uuid; bk uuid; n integer;
  h_join text := encode(sha256(convert_to('qa-join','UTF8')),'hex');
  h_seat text := encode(sha256(convert_to('qa-seat','UTF8')),'hex');
  h_part text := encode(sha256(convert_to('qa-part','UTF8')),'hex');
  h_dead text := encode(sha256(convert_to('qa-dead','UTF8')),'hex');
begin
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c001','QA 主揪') returning id into org;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c002') returning id into u2;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c003') returning id into u3;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c004') returning id into u4;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c005') returning id into u5;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c006') returning id into u6;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c007') returning id into u7;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c0ad') returning id into adm;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,price_cents)
    values ('qa-rpc-game','QA 劇本',2,6,60000) returning id into g;
  -- Saturday 09:00 and 14:00 (Taipei) next week are inside the store's opening window.
  sat := (now() at time zone 'Asia/Taipei')::date+1;
  sat := sat+((6-extract(dow from sat)::int+7)%7);
  slot1 := (sat+time '09:00') at time zone 'Asia/Taipei';
  slot2 := (sat+time '14:00') at time zone 'Asia/Taipei';

  -- P4: 主揪開 6 人私人團；主揪自動坐 1 號位；同一 request 重送不會開第二團。
  r := public.create_group(org,req,slot1,6,g,'{推理}','','private');
  gid := (r->>'group_id')::uuid;
  if not (r->>'created')::boolean then raise exception 'group not created'; end if;
  r := public.create_group(org,req,slot1,6,g,'{推理}','','private');
  if (r->>'group_id')::uuid<>gid or (r->>'created')::boolean then raise exception 'group request not idempotent'; end if;
  if (select count(*) from public.groups where organizer_user_id=org)<>1 then raise exception 'duplicate group'; end if;
  if (select count(*) from public.group_members where group_id=gid)<>6
    or (select count(*) from public.group_members where group_id=gid and status='joined')<>1
    then raise exception 'seats not created'; end if;
  begin
    perform public.create_group(org,gen_random_uuid(),slot1,6,g,'{}','','secret');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_VISIBILITY' then raise exception 'visibility: %', msg; end if;
  end;
  begin
    perform public.create_group(org,gen_random_uuid(),slot1,8,g);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_CAPACITY' then raise exception 'capacity vs game: %', msg; end if;
  end;

  -- 私人團沒有邀請 token 不能加入。
  begin
    perform public.join_group(u2,gid);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVITE_INVALID' then raise exception 'private join without token: %', msg; end if;
  end;
  begin
    perform public.create_group_invite(u2,gid,h_join,now()+interval '3 days');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_NOT_FOUND' then raise exception 'non-organizer invite: %', msg; end if;
  end;
  perform public.create_group_invite(org,gid,h_join,now()+interval '3 days');
  r := public.claim_invite(u2,h_join);
  if not (r->>'joined')::boolean then raise exception 'second player could not join'; end if;
  r := public.claim_invite(u2,h_join);
  if (r->>'joined')::boolean then raise exception 'join link added the same player twice'; end if;

  -- 主揪替「涵涵」預留席位；涵涵（尚無玩家檔）認領後 placeholder 綁到她的 LINE。
  r := public.reserve_group_seat(org,gid,'涵涵',h_seat,now()+interval '3 days');
  hanhan := (r->>'player_id')::uuid;
  if (select user_id from public.players where id=hanhan) is not null then raise exception 'placeholder bound early'; end if;
  r := public.claim_invite(u3,h_seat);
  if not (r->>'claimed')::boolean or (select user_id from public.players where id=hanhan)<>u3
    then raise exception 'claim did not bind placeholder'; end if;
  if (select status from public.group_members where player_id=hanhan and group_id=gid)<>'joined'
    then raise exception 'claimed seat not joined'; end if;
  r := public.claim_invite(u3,h_seat);
  if (r->>'claimed')::boolean then raise exception 'claim replay not idempotent'; end if;
  begin
    perform public.claim_invite(u4,h_seat);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVITE_USED' then raise exception 'token reuse by another user: %', msg; end if;
  end;
  if (select count(*) from public.group_members where group_id=gid and status='joined')<>3
    then raise exception 'claim created extra members'; end if;

  -- 第 7 人加入 6 人團被阻止；退出後空位可再加入。
  perform public.join_group(u4,gid,h_join);
  perform public.join_group(u5,gid,h_join);
  perform public.join_group(u6,gid,h_join);
  begin
    perform public.join_group(u7,gid,h_join);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_FULL' then raise exception '7th player: %', msg; end if;
  end;
  select gm.id into seat6 from public.group_members gm join public.players p on p.id=gm.player_id
    where gm.group_id=gid and p.user_id=u6;
  begin
    perform public.leave_group_seat(u7,seat6);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SEAT_NOT_FOUND' then raise exception 'stranger released seat: %', msg; end if;
  end;
  begin
    perform public.leave_group_seat(org,(select id from public.group_members where group_id=gid and seat_number=1));
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'ORGANIZER_CANNOT_LEAVE' then raise exception 'organizer left: %', msg; end if;
  end;
  perform public.leave_group_seat(u6,seat6);
  perform public.join_group(u7,gid,h_join);
  if (select count(*) from public.group_members where group_id=gid and status='joined')<>6
    then raise exception 'seat was not reusable'; end if;

  -- P2: group 轉 event；只有管理員可確認，重送不會建立第二場。
  begin
    perform public.admin_confirm_group_event(org,gid,'QA 場館','QA DM');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'non-admin confirm: %', msg; end if;
  end;
  r := public.admin_confirm_group_event(adm,gid,'QA 場館','QA DM');
  ev := (r->>'event_id')::uuid;
  if (r->>'participants')::int<>6 or (select status from public.groups where id=gid)<>'confirmed'
    or (select status from public.time_slots where group_id=gid)<>'booked'
    or (select starts_at from public.events where id=ev)<>slot1
    then raise exception 'group to event failed'; end if;
  r := public.admin_confirm_group_event(adm,gid,'QA 場館','QA DM');
  if (r->>'event_id')::uuid<>ev or (r->>'created')::boolean then raise exception 'confirm not idempotent'; end if;
  begin
    perform public.join_event(u2,ev,gen_random_uuid());
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'EVENT_NOT_FOUND' then raise exception 'private event visible: %', msg; end if;
  end;

  -- P6: 一人替 5 位朋友報名 6 人公開場；第 7 席售完且整筆回滾。
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '10 days',6,60000,'QA 場館','QA DM') returning id into ev2;
  req := gen_random_uuid();
  r := public.create_booking(u2,ev2,req,
    '[{"self":true},{"display_name":"朋友A"},{"display_name":"朋友B"},{"display_name":"朋友C"},{"display_name":"朋友D"},{"display_name":"朋友E"}]');
  bk := (r->>'booking_id')::uuid;
  if jsonb_array_length(r->'participants')<>6 then raise exception 'group booking failed'; end if;
  r := public.create_booking(u2,ev2,req,'[{"self":true}]');
  if (r->>'booking_id')::uuid<>bk or (r->>'created')::boolean then raise exception 'booking request not idempotent'; end if;
  begin
    perform public.join_event(u3,ev2,gen_random_uuid());
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SOLD_OUT' then raise exception 'oversold: %', msg; end if;
  end;
  if exists(select 1 from public.bookings where event_id=ev2 and booker_user_id=u3)
    then raise exception 'sold-out booking left an orphan'; end if;

  -- 同一 booking 部分取消；只有 booker／本人可取消；釋出的席位可再被預約。
  select bp.id into part from public.booking_participants bp join public.players p on p.id=bp.player_id
    where bp.booking_id=bk and p.display_name='朋友E';
  begin
    perform public.cancel_participant(u3,part);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'PARTICIPANT_NOT_FOUND' then raise exception 'stranger cancelled: %', msg; end if;
  end;
  r := public.cancel_participant(u2,part);
  if not (r->>'cancelled')::boolean then raise exception 'partial cancel failed'; end if;
  r := public.cancel_participant(u2,part);
  if (r->>'cancelled')::boolean then raise exception 'cancel not idempotent'; end if;
  if (select status from public.bookings where id=bk)<>'active'
    or (select count(*) from public.booking_participants where booking_id=bk and status<>'cancelled')<>5
    then raise exception 'partial cancel affected whole booking'; end if;
  perform public.join_event(u3,ev2,gen_random_uuid());

  -- 同一玩家不能重複加入同場；不可替別人的玩家檔報名。
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '12 days',6,60000,'QA 場館','QA DM') returning id into ev2;
  perform public.join_event(u4,ev2,gen_random_uuid());
  begin
    perform public.join_event(u4,ev2,gen_random_uuid());
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'ALREADY_BOOKED' then raise exception 'double join: %', msg; end if;
  end;
  begin
    perform public.create_booking(u5,ev2,gen_random_uuid(),jsonb_build_array(jsonb_build_object('player_id',hanhan)));
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'PLAYER_NOT_ALLOWED' then raise exception 'booked someone else''s player: %', msg; end if;
  end;

  -- 代報朋友用一次性 token 認領；已有玩家檔的認領者會取代 placeholder。
  r := public.create_booking(u5,ev2,gen_random_uuid(),'[{"display_name":"朋友F"}]');
  part := (r->'participants'->0->>'participant_id')::uuid;
  perform public.create_participant_claim(u5,part,h_part,now()+interval '3 days');
  r := public.claim_invite(u6,h_part);
  if (select pl.user_id from public.booking_participants bp join public.players pl on pl.id=bp.player_id
      where bp.id=part)<>u6 or (select status from public.booking_participants where id=part)<>'joined'
    then raise exception 'participant claim failed'; end if;
  if (select count(*) from public.players where user_id=u6)<>1 then raise exception 'claimer has two players'; end if;

  -- 解散揪團後所有邀請失效。
  r := public.create_group(u7,gen_random_uuid(),slot2,4);
  grp2 := (r->>'group_id')::uuid;
  perform public.reserve_group_seat(u7,grp2,'朋友G',h_dead,now()+interval '3 days');
  perform public.cancel_group(u7,grp2);
  if (select status from public.time_slots where group_id=grp2)<>'released' then raise exception 'cancel did not free slot'; end if;
  begin
    perform public.claim_invite(u2,h_dead);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVITE_INVALID' then raise exception 'invite survived cancel: %', msg; end if;
  end;

  select count(*) into n from public.audit_logs where actor_user_id in (org,u2,u5,u7,adm);
  if n<10 then raise exception 'operations not audited (% rows)', n; end if;
end $$;
reset role;
do $$
declare r text; f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_actor_player','_sf_is_admin','_sf_audit','_sf_token_expiry',
      '_sf_valid_hash','create_group','create_group_invite','reserve_group_seat','join_group','claim_invite',
      'leave_group_seat','cancel_group','admin_confirm_group_event','create_booking','join_event',
      'create_participant_claim','cancel_participant','list_available_starts','sync_calendar_busy',
      'admin_create_event','_sf_time_free','_sf_reserve_time','_sf_session_minutes') loop
    foreach r in array array['anon','authenticated'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
    if not has_function_privilege('service_role',f,'EXECUTE') then raise exception '% not granted to service_role', f; end if;
  end loop;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
      and p.proname in ('create_group','create_group_invite','reserve_group_seat','join_group','claim_invite',
      'leave_group_seat','cancel_group','admin_confirm_group_event','create_booking','join_event',
      'create_participant_claim','cancel_participant'))<>12 then raise exception 'RPC set incomplete'; end if;
end $$;
select 'PASS: group create, invite, join, claim, full, leave, confirm event, multi booking, sold out, cancel, privileges' as result;
rollback;
