-- Run in Supabase SQL Editor after 202610030010_cancel_event.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; u2 uuid; g uuid; gid uuid; ev uuid; r jsonb; msg text; sat date; t1 timestamptz;
  p_org uuid; p_u2 uuid; unpaid uuid; paid uuid;
  h_join text := encode(sha256(convert_to('qa-cancel-join','UTF8')),'hex');
  h_seat text := encode(sha256(convert_to('qa-cancel-seat','UTF8')),'hex');
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d0ad','店長') returning id into adm;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d0b1','主揪') returning id into org;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d0b2','小華') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-cancel','QA 取消本',2,6,240) returning id into g;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;
  t1 := (sat+time '14:00') at time zone 'Asia/Taipei';

  gid := (public.create_group(org,gen_random_uuid(),t1,4,g)->>'group_id')::uuid;
  perform public.create_group_invite(org,gid,h_join,now()+interval '3 days');
  perform public.claim_invite(u2,h_join);
  perform public.reserve_group_seat(org,gid,'涵涵',h_seat,now()+interval '3 days');
  ev := (public.admin_confirm_group_event(adm,gid,'南港','海星',null,40000)->>'event_id')::uuid;
  perform public.mark_event_calendar_synced(ev,replace(ev::text,'-',''));

  -- One unpaid and one paid allocation, to see what cancellation does with money.
  select bp.id into p_org from public.booking_participants bp join public.players p on p.id=bp.player_id where bp.event_id=ev and p.user_id=org;
  select bp.id into p_u2 from public.booking_participants bp join public.players p on p.id=bp.player_id where bp.event_id=ev and p.user_id=u2;
  insert into public.payments(payer_user_id,event_id,method,amount_cents,request_id) values (org,ev,'cash',40000,gen_random_uuid()) returning id into unpaid;
  insert into public.payment_allocations(payment_id,participant_id,amount_cents) values (unpaid,p_org,40000);
  insert into public.payments(payer_user_id,event_id,method,status,amount_cents,request_id,paid_at)
    values (u2,ev,'bank_transfer','paid',40000,gen_random_uuid(),now()) returning id into paid;
  insert into public.payment_allocations(payment_id,participant_id,amount_cents) values (paid,p_u2,40000);

  -- 只有店家能取消。
  begin
    perform public.admin_cancel_event(org,ev,'主揪想取消');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'organizer cancelled: %', msg; end if;
  end;

  r := public.admin_cancel_event(adm,ev,'  DM 臨時生病  ');
  if not (r->>'cancelled')::boolean or not (r->>'refund_required')::boolean then raise exception 'cancel result wrong: %', r; end if;
  if (select status||'|'||cancel_reason from public.events where id=ev)<>'cancelled|DM 臨時生病' then raise exception 'event not cancelled'; end if;
  if (select status from public.time_slots where event_id=ev)<>'released' then raise exception 'time not released'; end if;
  if exists(select 1 from public.booking_participants where event_id=ev and status<>'cancelled')
    or exists(select 1 from public.bookings where event_id=ev and status<>'cancelled') then raise exception 'bookings still active'; end if;
  if (select active from public.payment_allocations where payment_id=unpaid) or not (select active from public.payment_allocations where payment_id=paid)
    then raise exception 'unpaid should be released, paid kept for refund'; end if;
  if (select status from public.groups where id=gid)<>'cancelled'
    or exists(select 1 from public.group_members where group_id=gid and status<>'cancelled')
    or exists(select 1 from public.invite_tokens where group_id=gid and used_at is null and revoked_at is null)
    then raise exception 'group, seats or invites still open'; end if;

  -- 重複取消不出錯；時段可以重新被預約。
  if (public.admin_cancel_event(adm,ev)->>'cancelled')::boolean then raise exception 'second cancel not idempotent'; end if;
  if not exists(select 1 from jsonb_array_elements(public.list_available_starts(t1-interval '1 hour',t1+interval '1 hour')) x
      where (x->>'starts_at')::timestamptz=t1) then raise exception 'released time not offered again'; end if;
  perform public.create_group(u2,gen_random_uuid(),t1,4,g);

  -- 成員仍看得到取消與原因。
  r := public.get_group(u2,gid);
  if r->>'status'<>'cancelled' or r->'event'->>'status'<>'cancelled' or r->'event'->>'cancel_reason'<>'DM 臨時生病'
    then raise exception 'member cannot see cancellation: %', r; end if;
  if not exists(select 1 from jsonb_array_elements(public.list_my_groups(u2)) x where (x->>'group_id')::uuid=gid)
    then raise exception 'cancelled session missing from my groups'; end if;

  -- Google 日曆：只有已取消的場次能標記為已移除。
  r := public.event_calendar_payload(ev);
  if r->>'status'<>'cancelled' or (r->>'calendar_removed')::boolean or r->>'google_event_id' is null then raise exception 'payload wrong: %', r; end if;
  perform public.mark_event_calendar_removed(ev);
  if not (public.event_calendar_payload(ev)->>'calendar_removed')::boolean then raise exception 'removal not recorded'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.admin_cancel_event(uuid,uuid,text)','EXECUTE')
      or has_function_privilege(r,'public.mark_event_calendar_removed(uuid)','EXECUTE')
      then raise exception 'cancel RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: admin only, cancel cascades, money handling, idempotent, time released, members see reason, calendar removal' as result;
rollback;
