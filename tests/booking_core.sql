-- Run in Supabase SQL Editor after 202610020002_booking_core.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  u1 uuid; u2 uuid; p1 uuid; p2 uuid; p3 uuid; g uuid; ev uuid; bk uuid;
  grp uuid; part uuid; pay uuid; msg text;
begin
  insert into public.users(line_user_id) values ('U0000000000000000000000000000a001') returning id into u1;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000a002') returning id into u2;
  insert into public.players(user_id,display_name) values (u1,'QA 一') returning id into p1;
  insert into public.players(user_id,display_name) values (u2,'QA 二') returning id into p2;
  insert into public.players(display_name,created_by_user_id) values ('QA 代報',u1) returning id into p3;
  insert into public.games(slug,title,min_players,max_players,price_cents)
    values ('qa-game','QA 劇本',2,6,60000) returning id into g;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '7 days',2,60000,'QA 場館','QA DM') returning id into ev;
  insert into public.bookings(event_id,booker_user_id,request_id)
    values (ev,u1,gen_random_uuid()) returning id into bk;

  -- One booker may reserve several seats, including a proxy player without LINE.
  insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
    values (bk,ev,p1,60000,'reserved') returning id into part;
  insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
    values (bk,ev,p3,60000,'reserved');

  begin
    insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
      values (bk,ev,p2,60000,'reserved');
    raise exception 'oversell accepted';
  exception when check_violation then
    get stacked diagnostics msg = message_text;
    if msg <> 'SOLD_OUT' then raise exception 'unexpected oversell error: %', msg; end if;
  end;

  begin
    update public.events set capacity=1 where id=ev;
    raise exception 'capacity reduced below occupancy';
  exception when check_violation then null;
  end;

  -- Cancelling releases the seat; the same player cannot hold two active seats.
  update public.booking_participants set status='cancelled',cancelled_at=now()
    where event_id=ev and player_id=p3;
  begin
    insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
      values (bk,ev,p1,60000,'reserved');
    raise exception 'duplicate player accepted';
  exception when unique_violation then null;
  end;
  insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
    values (bk,ev,p2,60000,'reserved');

  -- Re-activating a cancelled seat is still subject to capacity.
  begin
    update public.booking_participants set status='reserved',cancelled_at=null
      where event_id=ev and player_id=p3;
    raise exception 'reactivation oversold';
  exception when check_violation then null;
  end;

  update public.events set status='cancelled' where id=ev;
  update public.booking_participants set status='cancelled' where event_id=ev and player_id=p2;
  begin
    update public.booking_participants set status='reserved' where event_id=ev and player_id=p2;
    raise exception 'booking accepted on closed event';
  exception when check_violation then
    get stacked diagnostics msg = message_text;
    if msg <> 'EVENT_CLOSED' then raise exception 'unexpected closed error: %', msg; end if;
  end;

  -- Group seats are bounded by group capacity; reserved seats need a player.
  insert into public.groups(organizer_user_id,game_id,desired_start_at,capacity,request_id)
    values (u1,g,now()+interval '3 days',2,gen_random_uuid()) returning id into grp;
  insert into public.group_members(group_id,seat_number,player_id,status) values (grp,1,p1,'joined');
  begin
    insert into public.group_members(group_id,seat_number,status) values (grp,3,'open');
    raise exception 'group seat beyond capacity accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.group_members(group_id,seat_number,status) values (grp,2,'reserved');
    raise exception 'reserved seat without player accepted';
  exception when check_violation then null;
  end;
  begin
    insert into public.group_members(group_id,seat_number,player_id,status) values (grp,2,p1,'joined');
    raise exception 'player joined group twice';
  exception when unique_violation then null;
  end;

  -- A participant can carry only one active payment allocation.
  insert into public.payments(payer_user_id,event_id,method,amount_cents,request_id)
    values (u1,ev,'cash',60000,gen_random_uuid()) returning id into pay;
  insert into public.payment_allocations(payment_id,participant_id,amount_cents) values (pay,part,60000);
  insert into public.payments(payer_user_id,event_id,method,amount_cents,request_id)
    values (u1,ev,'bank_transfer',60000,gen_random_uuid()) returning id into pay;
  begin
    insert into public.payment_allocations(payment_id,participant_id,amount_cents) values (pay,part,60000);
    raise exception 'double allocation accepted';
  exception when unique_violation then null;
  end;

  begin
    insert into public.invite_tokens(token_hash,purpose,participant_id,group_id,created_by_user_id,expires_at)
      values (repeat('a',64),'claim_participant',part,grp,u1,now()+interval '1 day');
    raise exception 'ambiguous invite accepted';
  exception when check_violation then null;
  end;

  insert into public.audit_logs(actor_user_id,action,entity_type,entity_id) values (u1,'qa','event',ev);
  begin
    update public.audit_logs set action='tampered';
    raise exception 'audit log is mutable';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$
declare tbl text; r text;
begin
  foreach tbl in array array['games','groups','group_members','events','bookings','booking_participants',
    'payments','payment_allocations','player_game_history','invite_tokens','notification_logs',
    'app_sessions','admin_users','audit_logs'] loop
    if not (select relrowsecurity from pg_class where oid=('public.'||tbl)::regclass)
      then raise exception 'RLS missing on %', tbl; end if;
    foreach r in array array['anon','authenticated'] loop
      if has_table_privilege(r,'public.'||tbl,'SELECT,INSERT,UPDATE,DELETE')
        then raise exception '% exposed to %', tbl, r; end if;
    end loop;
  end loop;
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.enforce_event_capacity()','EXECUTE')
      or has_function_privilege(r,'public.enforce_group_capacity()','EXECUTE')
      or has_function_privilege(r,'public.prevent_capacity_reduction()','EXECUTE')
      then raise exception 'trigger function exposed to %', r; end if;
    if has_sequence_privilege(r,'public.audit_logs_id_seq','USAGE,SELECT,UPDATE')
      then raise exception 'audit sequence exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: capacity, sold out, cancellation, closed event, groups, payments, invites, audit, RLS and privileges' as result;
rollback;
