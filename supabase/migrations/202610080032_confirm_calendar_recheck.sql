begin;

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
  -- Recheck the entire actual session, including equal-length and shortened sessions.
  if exists(select 1 from public.calendar_busy b where tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(s.starts_at,ends,'[)'))
    then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  if ends>s.ends_at then
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

create function public.admin_group_confirmation_window(p_actor uuid, p_group_id uuid, p_game_id uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; s public.time_slots%rowtype; gm public.games%rowtype; ev uuid;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='confirmed' then
    select id into ev from public.events where group_id=g.id;
    return jsonb_build_object('event_id',ev);
  end if;
  if g.status='cancelled' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  select * into s from public.time_slots where id=g.slot_id and status='held';
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode='P0001'; end if;
  if s.starts_at<=now() then raise exception 'INVALID_START_TIME' using errcode='P0001'; end if;
  select * into gm from public.games where id=coalesce(p_game_id,g.game_id) and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if g.capacity not between gm.min_players and gm.max_players then raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  return jsonb_build_object('starts_at',s.starts_at,'ends_at',s.starts_at+make_interval(mins=>gm.duration_minutes));
end $$;

-- Hold the group and catalog row while checking the synchronized range and committing.
-- If the script duration changed during the external read, require a fresh attempt.
create function public.admin_confirm_group_event_checked(p_actor uuid, p_group_id uuid,
  p_venue text, p_dm_name text, p_game_id uuid, p_price_cents integer,
  p_starts_at timestamptz, p_ends_at timestamptz)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; w jsonb;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status<>'confirmed' then
    perform 1 from public.games where id=coalesce(p_game_id,g.game_id) for share;
    w := public.admin_group_confirmation_window(p_actor,p_group_id,p_game_id);
    if p_starts_at is distinct from (w->>'starts_at')::timestamptz
      or p_ends_at is distinct from (w->>'ends_at')::timestamptz then
      raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  end if;
  return public.admin_confirm_group_event(p_actor,p_group_id,p_venue,p_dm_name,p_game_id,p_price_cents);
end $$;

revoke all on function public.admin_group_confirmation_window(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.admin_confirm_group_event_checked(uuid,uuid,text,text,uuid,integer,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.admin_group_confirmation_window(uuid,uuid,uuid) to service_role;
grant execute on function public.admin_confirm_group_event_checked(uuid,uuid,text,text,uuid,integer,timestamptz,timestamptz) to service_role;

commit;
