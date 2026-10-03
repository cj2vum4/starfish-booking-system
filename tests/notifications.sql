-- Run in Supabase SQL Editor after 202610030011_notifications.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; u2 uuid; u3 uuid; g uuid; gid uuid; gid2 uuid; ev uuid; r jsonb; msg text; sat date; n integer;
  base integer; first_id uuid;
  h_join text := encode(sha256(convert_to('qa-notify-join','UTF8')),'hex');
  h_seat text := encode(sha256(convert_to('qa-notify-seat','UTF8')),'hex');
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  select count(*) into base from public.notification_logs;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000e1ad','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000e1b1','主揪','active') returning id into org;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000e1b2','小華','active') returning id into u2;
  insert into public.users(line_user_id,display_name,oa_friend_status,blocked_at) values ('U0000000000000000000000000000e1b3','小美','blocked',now()) returning id into u3;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-notify','QA 通知本',2,6,240) returning id into g;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;

  -- 開團通知店家（主揪本人不收）。
  gid := (public.create_group(org,gen_random_uuid(),(sat+time '09:00') at time zone 'Asia/Taipei',3,g)->>'group_id')::uuid;
  set constraints all immediate;
  if not exists(select 1 from public.notification_logs where user_id=adm and notification_type='group_created' and group_id=gid
      and payload->>'game_title'='QA 通知本' and (payload->>'capacity')::int=3) then raise exception 'store not told about new group'; end if;

  -- 有人加入通知主揪；最後一席加入時再通知店家滿團。
  perform public.create_group_invite(org,gid,h_join,now()+interval '3 days');
  perform public.claim_invite(u2,h_join);
  if not exists(select 1 from public.notification_logs where user_id=org and notification_type='member_joined'
      and payload->>'joiner_name'='小華' and (payload->>'filled')::int=2) then raise exception 'organizer not told about join'; end if;
  if exists(select 1 from public.notification_logs where notification_type='group_full' and group_id=gid) then raise exception 'full too early'; end if;
  perform public.reserve_group_seat(org,gid,'涵涵',h_seat,now()+interval '3 days');
  perform public.claim_invite(u3,h_seat);
  if not exists(select 1 from public.notification_logs where user_id=adm and notification_type='group_full' and group_id=gid)
    then raise exception 'store not told the group is full'; end if;
  if (select count(*) from public.notification_logs where notification_type='group_full_members' and group_id=gid)<>2
    or exists(select 1 from public.notification_logs where user_id=org and notification_type='group_full_members')
    then raise exception 'members not told the group is full'; end if;

  -- 失敗的動作不產生任何通知。
  select count(*) into n from public.notification_logs;
  begin
    perform public.join_group(adm,gid,h_join);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_FULL' then raise exception 'unexpected: %', msg; end if;
  end;
  set constraints all immediate;
  if (select count(*) from public.notification_logs)<>n then raise exception 'failed join produced a notification'; end if;

  -- 成團通知全部成員，帶場地與價格。
  ev := (public.admin_confirm_group_event(adm,gid,'南港','海星',null,40000)->>'event_id')::uuid;
  set constraints all immediate;
  if (select count(*) from public.notification_logs where notification_type='group_confirmed' and group_id=gid)<>3
    or not exists(select 1 from public.notification_logs where user_id=u2 and notification_type='group_confirmed'
      and payload->>'venue'='南港' and (payload->>'price_cents')::int=40000) then raise exception 'confirmation not sent to members'; end if;

  -- 店家取消：成員收到含原因的取消通知（不是「解散」）。
  perform public.admin_cancel_event(adm,ev,'DM 生病');
  set constraints all immediate;
  if (select count(*) from public.notification_logs where notification_type='event_cancelled' and group_id=gid)<>3
    or not exists(select 1 from public.notification_logs where user_id=u2 and notification_type='event_cancelled' and payload->>'cancel_reason'='DM 生病')
    or exists(select 1 from public.notification_logs where notification_type='group_dissolved' and group_id=gid)
    then raise exception 'cancellation notifications wrong'; end if;

  -- 主揪解散：其他成員收到，主揪自己不收。
  gid2 := (public.create_group(org,gen_random_uuid(),(sat+time '14:00') at time zone 'Asia/Taipei',3,g)->>'group_id')::uuid;
  perform public.create_group_invite(org,gid2,encode(sha256(convert_to('qa-notify-join2','UTF8')),'hex'),now()+interval '3 days');
  perform public.claim_invite(u2,encode(sha256(convert_to('qa-notify-join2','UTF8')),'hex'));
  perform public.cancel_group(org,gid2);
  set constraints all immediate;
  if not exists(select 1 from public.notification_logs where user_id=u2 and notification_type='group_dissolved' and group_id=gid2)
    or exists(select 1 from public.notification_logs where user_id=org and notification_type='group_dissolved')
    then raise exception 'dissolve notifications wrong'; end if;

  -- 發送：領取一批、成功／失敗退避／超過次數放棄；被領走的不會重複領。
  r := public.claim_notifications(100);
  if jsonb_array_length(r)<>(select count(*) from public.notification_logs)-base then raise exception 'claim count wrong'; end if;
  if not exists(select 1 from jsonb_array_elements(r) x where x->>'friend_status'='blocked') then raise exception 'friend status missing'; end if;
  if jsonb_array_length(public.claim_notifications(100))<>0 then raise exception 'claimed rows handed out twice'; end if;
  -- Self-test players (synthetic LINE IDs) never generate messages.
  insert into public.users(line_user_id) values ('Ufeedfacefeedface0000000000000001') returning id into u3;
  gid2 := (public.create_group(u3,gen_random_uuid(),(sat+time '18:00') at time zone 'Asia/Taipei',2,g)->>'group_id')::uuid;
  set constraints all immediate;
  if exists(select 1 from public.notification_logs where group_id=gid2) then raise exception 'self-test group notified the store'; end if;
  insert into public.notification_logs(user_id,notification_type,payload,dedupe_key,created_at)
    values (u2,'group_confirmed','{}','qa-stale',now()-interval '2 days');
  perform public.claim_notifications(100);
  if (select status||':'||error_code from public.notification_logs where dedupe_key='qa-stale')<>'skipped:STALE'
    then raise exception 'stale notification not dropped'; end if;
  first_id := (r->0->>'id')::uuid;
  perform public.complete_notification(first_id,'failed','HTTP_500');
  if (select status from public.notification_logs where id=first_id)<>'failed'
    or (select next_attempt_at from public.notification_logs where id=first_id)<=now() then raise exception 'no backoff'; end if;
  update public.notification_logs set attempts=5 where id=first_id;
  perform public.complete_notification(first_id,'failed','HTTP_500');
  if (select status from public.notification_logs where id=first_id)<>'skipped' then raise exception 'retries not capped'; end if;
  perform public.complete_notification((r->1->>'id')::uuid,'sent');
  if (select sent_at from public.notification_logs where id=(r->1->>'id')::uuid) is null then raise exception 'sent not recorded'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.claim_notifications(integer)','EXECUTE')
      or has_function_privilege(r,'public.complete_notification(uuid,text,text)','EXECUTE')
      then raise exception 'notification RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: new group, join, full, no notice on failure, confirmed, store cancel with reason, dissolve, claim, backoff, cap' as result;
rollback;
