-- Run in Supabase SQL Editor after 202610030017_admin_report.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare adm uuid; org uuid; u2 uuid; g uuid; ev uuid; ev2 uuid; r jsonb; s jsonb; msg text; absent uuid;
begin
  delete from public.calendar_busy;  -- isolation from real data; rolled back
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000b8ad','店長') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U0000000000000000000000000000b8b1','主揪','active') returning id into org;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000b8b2','小華') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-report','QA 報表本',2,6,240) returning id into g;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '1 day',4,40000,'南港','海星') returning id into ev;
  perform public.create_booking(org,ev,gen_random_uuid(),'[{"self":true},{"display_name":"朋友A"}]');
  perform public.join_event(u2,ev,gen_random_uuid());
  update public.events set starts_at=now()-interval '2 days' where id=ev;
  select bp.id into absent from public.booking_participants bp join public.players p on p.id=bp.player_id where bp.event_id=ev and p.user_id=u2;
  perform public.admin_complete_event(adm,ev,array[absent]);
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '10 days',6,40000,'北車','海星') returning id into ev2;

  begin
    perform public.admin_report(org,now()-interval '30 days',now()+interval '60 days');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'non-admin report: %', msg; end if;
  end;
  begin
    perform public.admin_report(adm,now(),now()-interval '1 day');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_RANGE' then raise exception 'bad range: %', msg; end if;
  end;

  r := public.admin_report(adm,now()-interval '30 days',now()+interval '60 days');
  select x into s from jsonb_array_elements(r->'sessions') x where (x->>'event_id')::uuid=ev;
  if s->>'title'<>'QA 報表本' or (s->>'booked')::int<>3 or (s->>'attended')::int<>2 or (s->>'absent')::int<>1
    or s->>'status'<>'completed' or s->>'source'<>'店家開場' then raise exception 'session row wrong: %', s; end if;
  if not exists(select 1 from jsonb_array_elements(r->'sessions') x where (x->>'event_id')::uuid=ev2) then raise exception 'upcoming session missing'; end if;
  if (select count(*) from jsonb_array_elements(r->'attendance') x where (x->>'event_id')::uuid=ev)<>3
    or not exists(select 1 from jsonb_array_elements(r->'attendance') x where x->>'player'='朋友A' and not (x->>'has_line')::boolean)
    then raise exception 'attendance rows wrong'; end if;
  if not exists(select 1 from jsonb_array_elements(r->'players') x where x->>'player'='主揪' and (x->>'played')::int=1 and x->>'oa_friend'='active')
    or not exists(select 1 from jsonb_array_elements(r->'players') x where x->>'player'='小華' and (x->>'played')::int=0)
    then raise exception 'player totals wrong'; end if;
  -- Out-of-range sessions are excluded.
  r := public.admin_report(adm,now()+interval '5 days',now()+interval '60 days');
  if exists(select 1 from jsonb_array_elements(r->'sessions') x where (x->>'event_id')::uuid=ev) then raise exception 'range filter wrong'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.admin_report(uuid,timestamptz,timestamptz)','EXECUTE') then raise exception 'report exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: admin only, range validation, session counts, attendance rows, player totals, range filter' as result;
rollback;
