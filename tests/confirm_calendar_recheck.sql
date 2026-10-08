-- Run after migration 0032. Synthetic changes, including busy-mirror changes, roll back.
begin;
set local role service_role;
do $$
declare adm uuid; org uuid; game uuid; grp uuid; ev uuid; sat date; starts timestamptz;
  w jsonb; r jsonb; msg text; minutes integer; original_ends timestamptz;
begin
  delete from public.calendar_busy;
  insert into public.users(line_user_id,display_name) values ('U00000000000000000000000000c032ad','QA admin') returning id into adm;
  insert into public.users(line_user_id,display_name) values ('U00000000000000000000000000c03201','QA organizer') returning id into org;
  insert into public.admin_users(user_id) values(adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes,price_cents)
    values('qa-confirm-recheck','QA confirm recheck',4,6,240,40000) returning id into game;
  sat := (now() at time zone 'Asia/Taipei')::date+1;
  sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released'
    and (starts_at at time zone 'Asia/Taipei')::date=sat) loop sat:=sat+7; end loop;
  starts := (sat+time '09:00') at time zone 'Asia/Taipei';
  grp := (public.create_group(org,gen_random_uuid(),starts,5,game)->>'group_id')::uuid;
  select ends_at into original_ends from public.time_slots where group_id=grp;
  begin
    perform public.admin_group_confirmation_window(org,grp,game);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text;
    if msg<>'NOT_ADMIN' then raise exception 'window authorization: %',msg; end if;
  end;
  -- Added after opening the group, inside the original slot (not just its extension).
  insert into public.calendar_busy(starts_at,ends_at) values(starts+interval '30 minutes',starts+interval '1 hour');
  foreach minutes in array array[240,210,360] loop
    update public.games set duration_minutes=minutes where id=game;
    w := public.admin_group_confirmation_window(adm,grp,game);
    if (w->>'starts_at')::timestamptz<>starts or (w->>'ends_at')::timestamptz<>starts+make_interval(mins=>minutes)
      then raise exception 'wrong actual window: %',w; end if;
    begin
      perform public.admin_confirm_group_event_checked(adm,grp,'QA venue','QA DM',game,40000,
        (w->>'starts_at')::timestamptz,(w->>'ends_at')::timestamptz);
      raise exception 'MISSING';
    exception when others then get stacked diagnostics msg=message_text;
      if msg<>'SLOT_UNAVAILABLE' then raise exception 'full-window overlap (% minutes): %',minutes,msg; end if;
    end;
    if (select status from public.groups where id=grp)<>'recruiting'
      or (select ends_at from public.time_slots where group_id=grp)<>original_ends
      or exists(select 1 from public.events where group_id=grp)
      or exists(select 1 from public.notification_logs where payload->>'group_id'=grp::text and payload->>'kind'='group_confirmed')
      then raise exception 'failed confirmation had side effects'; end if;
  end loop;
  delete from public.calendar_busy;
  -- The catalog changes while the API is reading the calendar: old range must not commit.
  update public.games set duration_minutes=240 where id=game;
  w := public.admin_group_confirmation_window(adm,grp,game);
  update public.games set duration_minutes=360 where id=game;
  begin
    perform public.admin_confirm_group_event_checked(adm,grp,'QA venue','QA DM',game,40000,
      (w->>'starts_at')::timestamptz,(w->>'ends_at')::timestamptz);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'changed duration: %',msg; end if;
  end;
  -- Busy only in the released tail must not prevent a shorter actual session.
  update public.games set duration_minutes=210 where id=game;
  insert into public.calendar_busy(starts_at,ends_at) values(starts+interval '210 minutes',starts+interval '4 hours');
  w := public.admin_group_confirmation_window(adm,grp,game);
  r := public.admin_confirm_group_event_checked(adm,grp,'QA venue','QA DM',game,40000,
    (w->>'starts_at')::timestamptz,(w->>'ends_at')::timestamptz);
  ev := (r->>'event_id')::uuid;
  if not (r->>'created')::boolean or (select ends_at from public.time_slots where event_id=ev)<>starts+interval '210 minutes'
    then raise exception 'shortened non-overlapping session not confirmed'; end if;
  -- A confirmed retry is idempotent even with new conflicts and invalid supplied windows.
  insert into public.calendar_busy(starts_at,ends_at) values(starts,starts+interval '1 hour');
  w := public.admin_group_confirmation_window(adm,grp,null);
  if (w->>'event_id')::uuid<>ev then raise exception 'confirmed window missing event'; end if;
  r := public.admin_confirm_group_event_checked(adm,grp,'QA venue','QA DM',null,40000,null,null);
  if (r->>'created')::boolean or (r->>'event_id')::uuid<>ev
    or (select count(*) from public.events where group_id=grp)<>1 then raise exception 'retry duplicated event'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.admin_group_confirmation_window(uuid,uuid,uuid)','EXECUTE')
      or has_function_privilege(r,'public.admin_confirm_group_event_checked(uuid,uuid,text,text,uuid,integer,timestamptz,timestamptz)','EXECUTE')
      then raise exception 'confirmation RPC exposed to %',r; end if;
  end loop;
end $$;
select 'PASS: entire window recheck, same/shorter/longer conflict, duration change, no side effects, boundary, retry, permissions' as result;
rollback;
