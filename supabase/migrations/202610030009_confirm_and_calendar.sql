begin;

-- Store confirmation of a recruiting group, and the bookkeeping for writing the confirmed
-- session to the store's Google Calendar (written after the database commit; retryable).

alter table public.events add column google_event_id text unique;
alter table public.events add column calendar_synced_at timestamptz;

-- The confirmed script decides the session length. A longer script extends the held time
-- only when the extra time is free; a shorter one gives the rest back.
create or replace function public.admin_confirm_group_event(p_actor uuid, p_group_id uuid,
  p_venue text, p_dm_name text, p_game_id uuid default null, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; gm public.games%rowtype; s public.time_slots%rowtype; ev uuid; bk uuid; n integer;
  price integer; ends timestamptz;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='confirmed' then
    select id into ev from public.events where group_id=g.id;
    return jsonb_build_object('event_id',ev,'created',false);
  end if;
  if g.status='cancelled' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  select * into s from public.time_slots where id=g.slot_id and status='held' for update;
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode='P0001'; end if;
  if s.starts_at<=now() then raise exception 'INVALID_START_TIME' using errcode='P0001'; end if;
  select * into gm from public.games where id=coalesce(p_game_id,g.game_id) and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if g.capacity not between gm.min_players and gm.max_players then raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  if coalesce(length(trim(p_venue)),0) not between 1 and 200 then raise exception 'INVALID_VENUE' using errcode='P0001'; end if;
  if coalesce(length(trim(p_dm_name)),0) not between 1 and 100 then raise exception 'INVALID_DM' using errcode='P0001'; end if;
  price := public._sf_event_price(p_price_cents,gm.price_cents);

  ends := s.starts_at+make_interval(mins=>public._sf_session_minutes(gm.id));
  if ends>s.ends_at then
    -- The extension must not overlap another session or a busy period on the calendar.
    if exists(select 1 from public.calendar_busy b where tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(s.ends_at,ends,'[)'))
      then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
    begin
      update public.time_slots set ends_at=ends where id=s.id;
    exception when exclusion_violation then
      raise exception 'SLOT_UNAVAILABLE' using errcode='P0001';
    end;
  elsif ends<s.ends_at then
    update public.time_slots set ends_at=ends where id=s.id;
  end if;

  insert into public.events(group_id,game_id,starts_at,capacity,price_cents,venue,dm_name,visibility,slot_id)
    values (g.id,gm.id,s.starts_at,g.capacity,price,trim(p_venue),trim(p_dm_name),g.visibility,s.id)
    returning id into ev;
  update public.time_slots set status='booked',event_id=ev where id=s.id;
  insert into public.bookings(event_id,booker_user_id,request_id) values (ev,g.organizer_user_id,gen_random_uuid())
    returning id into bk;
  insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
    select bk,ev,player_id,price,status from public.group_members
    where group_id=g.id and status in ('reserved','joined') order by seat_number;
  get diagnostics n = row_count;
  update public.groups set status='confirmed',game_id=gm.id where id=g.id;
  perform public._sf_audit(p_actor,'group.confirm_event','event',ev,jsonb_build_object('group_id',g.id,'participants',n));
  return jsonb_build_object('event_id',ev,'booking_id',bk,'participants',n,'ends_at',ends,'created',true);
end $$;

-- What goes into the Google Calendar entry. Names stay in the store's own calendar.
create function public.event_calendar_payload(p_event_id uuid)
returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('event_id',e.id,'google_event_id',e.google_event_id,'title',gm.title,
    'starts_at',e.starts_at,'ends_at',s.ends_at,'venue',e.venue,'dm_name',e.dm_name,'price_cents',e.price_cents,
    'capacity',e.capacity,'status',e.status,'group_id',e.group_id,
    'organizer_name',(select u.display_name from public.groups g join public.users u on u.id=g.organizer_user_id where g.id=e.group_id),
    'players',(select coalesce(jsonb_agg(p.display_name order by bp.created_at),'[]') from public.booking_participants bp
      join public.players p on p.id=bp.player_id where bp.event_id=e.id and bp.status<>'cancelled'))
  from public.events e join public.games gm on gm.id=e.game_id left join public.time_slots s on s.id=e.slot_id
  where e.id=p_event_id
$$;

create function public.mark_event_calendar_synced(p_event_id uuid, p_google_event_id text)
returns jsonb language plpgsql set search_path='' as $$
begin
  if coalesce(p_google_event_id,'') !~ '^[a-v0-9]+$' or length(p_google_event_id) not between 5 and 1024 then raise exception 'INVALID_CALENDAR_ID' using errcode='P0001'; end if;
  update public.events set google_event_id=p_google_event_id,calendar_synced_at=now() where id=p_event_id;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode='P0001'; end if;
  return jsonb_build_object('synced',true);
end $$;

-- Upcoming groups for the store: recruiting ones to confirm, confirmed ones to review.
create function public.admin_list_groups(p_actor uuid)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return (select coalesce(jsonb_agg(public._sf_group_summary(g.id) order by g.desired_start_at),'[]')
    from public.groups g where g.status in ('recruiting','pending_confirmation','confirmed')
      and g.desired_start_at>now()-interval '1 day');
end $$;

-- Group summaries now carry the confirmed session's details (price, venue, DM, calendar).
create or replace function public._sf_group_summary(p_group_id uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'group_id',g.id,'status',g.status,'visibility',g.visibility,'capacity',g.capacity,
    'starts_at',coalesce(s.starts_at,g.desired_start_at),'ends_at',s.ends_at,
    'game_id',g.game_id,'game_title',gm.title,'game_min_players',gm.min_players,'game_max_players',gm.max_players,
    'preferences',to_jsonb(g.preferences),'note',g.note,
    'organizer_name',coalesce(u.display_name,'主揪'),
    'filled',(select count(*) from public.group_members m where m.group_id=g.id and m.status in ('reserved','joined')),
    'event',(select jsonb_build_object('event_id',e.id,'price_cents',e.price_cents,'venue',e.venue,'dm_name',e.dm_name,
      'calendar_synced',e.google_event_id is not null) from public.events e where e.group_id=g.id))
  from public.groups g
  join public.users u on u.id=g.organizer_user_id
  left join public.time_slots s on s.id=g.slot_id
  left join public.games gm on gm.id=g.game_id
  where g.id=p_group_id
$$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('admin_confirm_group_event','event_calendar_payload',
      'mark_event_calendar_synced','admin_list_groups','_sf_group_summary') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
