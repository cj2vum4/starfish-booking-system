begin;

-- P9 play history. After a session, the store records attendance; attendees get a
-- player_game_history row. Players see their history, and script lists can mark
-- scripts someone has already played.

-- Participants of an event with their player's name, for the attendance sheet.
create function public.admin_event_participants(p_actor uuid, p_event_id uuid)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('participant_id',bp.id,'name',p.display_name,
      'status',bp.status,'attendance',bp.attendance) order by bp.created_at),'[]')
    from public.booking_participants bp join public.players p on p.id=bp.player_id
    where bp.event_id=p_event_id and bp.status<>'cancelled');
end $$;

create function public.admin_complete_event(p_actor uuid, p_event_id uuid, p_absent uuid[] default '{}')
returns jsonb language plpgsql set search_path='' as $$
declare e public.events%rowtype; attended integer; absent integer;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into e from public.events where id=p_event_id for update;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode='P0001'; end if;
  if e.status='completed' then return jsonb_build_object('completed',false); end if;
  if e.status not in ('open','confirmed') then raise exception 'EVENT_CLOSED' using errcode='P0001'; end if;
  if e.starts_at>now() then raise exception 'EVENT_NOT_STARTED' using errcode='P0001'; end if;
  if exists(select 1 from unnest(coalesce(p_absent,'{}')) a where a not in
      (select id from public.booking_participants where event_id=e.id and status<>'cancelled'))
    then raise exception 'PARTICIPANT_NOT_FOUND' using errcode='P0001'; end if;

  update public.booking_participants set
    status=case when id=any(coalesce(p_absent,'{}')) then 'no_show' else 'completed' end,
    attendance=case when id=any(coalesce(p_absent,'{}')) then 'absent' else 'attended' end
    where event_id=e.id and status in ('reserved','joined');
  insert into public.player_game_history(player_id,game_id,event_id,played_at)
    select player_id,e.game_id,e.id,e.starts_at from public.booking_participants
    where event_id=e.id and attendance='attended'
    on conflict do nothing;
  get diagnostics attended = row_count;
  select count(*) into absent from public.booking_participants where event_id=e.id and attendance='absent';
  update public.events set status='completed' where id=e.id;
  perform public._sf_audit(p_actor,'event.complete','event',e.id,jsonb_build_object('attended',attended,'absent',absent));
  return jsonb_build_object('completed',true,'attended',attended,'absent',absent);
end $$;

create function public.list_my_history(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('game_id',gm.id,'title',gm.title,'image_url',gm.image_url,
      'played_at',h.played_at,'venue',e.venue,'dm_name',e.dm_name) order by h.played_at desc),'[]')
  from public.player_game_history h
  join public.players p on p.id=h.player_id and p.user_id=p_actor
  join public.games gm on gm.id=h.game_id
  join public.events e on e.id=h.event_id
$$;

create function public.my_played_games(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(distinct h.game_id),'[]')
  from public.player_game_history h join public.players p on p.id=h.player_id
  where p.user_id=p_actor
$$;

-- For a group: which scripts its current members have already played (store and organizer).
create function public.group_played_games(p_actor uuid, p_group_id uuid)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not (public._sf_is_admin(p_actor) or exists(select 1 from public.groups where id=p_group_id and organizer_user_id=p_actor)) then
    raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  return (select coalesce(jsonb_object_agg(x.game_id,x.names),'{}') from (
    select h.game_id, jsonb_agg(distinct p.display_name) as names
    from public.group_members m join public.players p on p.id=m.player_id
    join public.player_game_history h on h.player_id=p.id
    where m.group_id=p_group_id and m.status in ('reserved','joined')
    group by h.game_id) x);
end $$;

-- Sessions waiting for attendance stay on the store's list for two weeks after they start.
create or replace function public.admin_list_groups(p_actor uuid)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return (select coalesce(jsonb_agg(public._sf_group_summary(g.id) order by g.desired_start_at),'[]')
    from public.groups g where (g.status in ('recruiting','pending_confirmation') and g.desired_start_at>now()-interval '1 day')
      or (g.status='confirmed' and g.desired_start_at>now()-interval '14 days'
          and not exists(select 1 from public.events e where e.group_id=g.id and e.status='completed'))
      or (g.status='confirmed' and g.desired_start_at>now()-interval '1 day'));
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('admin_event_participants','admin_complete_event','list_my_history',
      'my_played_games','group_played_games','admin_list_groups') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
