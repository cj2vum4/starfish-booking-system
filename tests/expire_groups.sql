-- Run in Supabase SQL Editor after 202610060029_expire_groups.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; u2 uuid; g uuid; past uuid; future uuid; manual uuid; sat date; n integer;
  h text := encode(sha256(convert_to('qa-expire-join','UTF8')),'hex');
begin
  delete from public.calendar_busy;  -- isolation from real data; rolled back
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000e7ad','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000e7b1','主揪','active') returning id into org;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000e7b2','小華','active') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-expire','QA 過期本',2,6,240) returning id into g;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;
  set constraints all immediate;  -- fire the deferred notification triggers inside this test

  -- 主揪自己解散：照舊通知成員。
  manual := (public.create_group(org,gen_random_uuid(),(sat+time '09:00') at time zone 'Asia/Taipei',3,g)->>'group_id')::uuid;
  perform public.create_group_invite(org,manual,h,now()+interval '3 days');
  perform public.claim_invite(u2,h);
  perform public.cancel_group(org,manual);
  if not exists(select 1 from public.notification_logs where group_id=manual and notification_type='group_dissolved' and user_id=u2)
    then raise exception 'manual dissolve no longer notifies'; end if;

  -- 開場時間已過、還沒成團：直接取消，不發通知。未到時間的不動。
  past := (public.create_group(org,gen_random_uuid(),(sat+time '14:00') at time zone 'Asia/Taipei',3,g)->>'group_id')::uuid;
  future := (public.create_group(org,gen_random_uuid(),(sat+time '19:00') at time zone 'Asia/Taipei',3,g)->>'group_id')::uuid;
  update public.groups set desired_start_at=now()-interval '1 minute' where id=past;
  n := public.expire_stale_groups();
  if n<1 then raise exception 'nothing expired'; end if;
  if (select status from public.groups where id=past)<>'cancelled' then raise exception 'expired group still open'; end if;
  if exists(select 1 from public.group_members where group_id=past and status<>'cancelled') then raise exception 'seats not released'; end if;
  if exists(select 1 from public.time_slots where group_id=past and status='held') then raise exception 'slot still held'; end if;
  if (select status from public.groups where id=future)<>'recruiting' then raise exception 'future group touched'; end if;
  if exists(select 1 from public.notification_logs where group_id=past and notification_type in ('group_dissolved','event_cancelled'))
    then raise exception 'expiry sent a message'; end if;
  if not exists(select 1 from public.audit_logs where entity_id=past and action='group.expire') then raise exception 'expiry not audited'; end if;
  if public.expire_stale_groups()<>0 then raise exception 'expiry not idempotent'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.expire_stale_groups()','EXECUTE') then raise exception 'expiry exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: expired unconfirmed groups cancelled quietly, seats and slot released, future and manual dissolve unchanged, privileges' as result;
rollback;
