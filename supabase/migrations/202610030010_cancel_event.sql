begin;

-- Store cancellation of a confirmed session. The database cancels first; the Google
-- Calendar entry is removed afterwards (retryable), mirroring how it was written.

alter table public.events add column cancel_reason text check (length(cancel_reason)<=500);
alter table public.events add column cancelled_at timestamptz;
alter table public.events add column calendar_removed_at timestamptz;

create function public.admin_cancel_event(p_actor uuid, p_event_id uuid, p_reason text default null)
returns jsonb language plpgsql set search_path='' as $$
declare e public.events%rowtype; paid integer;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into e from public.events where id=p_event_id for update;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode='P0001'; end if;
  if e.status='cancelled' then
    return jsonb_build_object('cancelled',false,'event_id',e.id);
  end if;
  if e.status='completed' then raise exception 'EVENT_COMPLETED' using errcode='P0001'; end if;

  update public.events set status='cancelled',cancelled_at=now(),
    cancel_reason=nullif(left(trim(coalesce(p_reason,'')),500),'') where id=e.id;
  update public.time_slots set status='released' where event_id=e.id and status<>'released';
  update public.booking_participants set status='cancelled',cancelled_at=now()
    where event_id=e.id and status in ('reserved','joined');
  update public.bookings set status='cancelled' where event_id=e.id and status<>'cancelled';
  update public.payment_allocations pa set active=false from public.payments p
    where pa.payment_id=p.id and p.event_id=e.id and pa.active and p.status in ('unpaid','pending','failed','cancelled');
  select count(*) into paid from public.payment_allocations pa join public.payments p on p.id=pa.payment_id
    where p.event_id=e.id and pa.active;
  update public.invite_tokens set revoked_at=now() where revoked_at is null and used_at is null
    and participant_id in (select id from public.booking_participants where event_id=e.id);
  if e.group_id is not null then
    update public.groups set status='cancelled' where id=e.group_id;
    update public.group_members set status='cancelled' where group_id=e.group_id and status<>'cancelled';
    update public.invite_tokens set revoked_at=now() where group_id=e.group_id and used_at is null and revoked_at is null;
  end if;
  perform public._sf_audit(p_actor,'event.cancel','event',e.id,
    jsonb_build_object('group_id',e.group_id,'refund_required',paid>0,'reason',left(coalesce(p_reason,''),500)));
  return jsonb_build_object('cancelled',true,'event_id',e.id,'refund_required',paid>0);
end $$;

create function public.mark_event_calendar_removed(p_event_id uuid)
returns jsonb language plpgsql set search_path='' as $$
begin
  update public.events set calendar_removed_at=now() where id=p_event_id and status='cancelled';
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode='P0001'; end if;
  return jsonb_build_object('removed',true);
end $$;

create or replace function public.event_calendar_payload(p_event_id uuid)
returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('event_id',e.id,'google_event_id',e.google_event_id,'title',gm.title,
    'starts_at',e.starts_at,'ends_at',s.ends_at,'venue',e.venue,'dm_name',e.dm_name,'price_cents',e.price_cents,
    'capacity',e.capacity,'status',e.status,'group_id',e.group_id,'calendar_removed',e.calendar_removed_at is not null,
    'organizer_name',(select u.display_name from public.groups g join public.users u on u.id=g.organizer_user_id where g.id=e.group_id),
    'players',(select coalesce(jsonb_agg(p.display_name order by bp.created_at),'[]') from public.booking_participants bp
      join public.players p on p.id=bp.player_id where bp.event_id=e.id and bp.status<>'cancelled'))
  from public.events e join public.games gm on gm.id=e.game_id left join public.time_slots s on s.id=e.slot_id
  where e.id=p_event_id
$$;

-- Summaries show a cancelled session (and its reason) to members and the store.
create or replace function public._sf_group_summary(p_group_id uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'group_id',g.id,'status',g.status,'visibility',g.visibility,'capacity',g.capacity,
    'starts_at',coalesce(s.starts_at,g.desired_start_at),'ends_at',s.ends_at,
    'game_id',g.game_id,'game_title',gm.title,'game_min_players',gm.min_players,'game_max_players',gm.max_players,
    'preferences',to_jsonb(g.preferences),'note',g.note,
    'organizer_name',coalesce(u.display_name,'主揪'),
    'filled',(select count(*) from public.group_members m where m.group_id=g.id and m.status in ('reserved','joined')),
    'event',(select jsonb_build_object('event_id',e.id,'status',e.status,'price_cents',e.price_cents,'venue',e.venue,
      'dm_name',e.dm_name,'calendar_synced',e.google_event_id is not null,'cancel_reason',e.cancel_reason,
      'calendar_removed',e.calendar_removed_at is not null) from public.events e where e.group_id=g.id))
  from public.groups g
  join public.users u on u.id=g.organizer_user_id
  left join public.time_slots s on s.id=g.slot_id
  left join public.games gm on gm.id=g.game_id
  where g.id=p_group_id
$$;

-- Members still see a cancelled session (with its reason) in their list for a day.
create or replace function public.list_my_groups(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(public._sf_group_summary(x.id)||jsonb_build_object('is_organizer',x.organizer)
    order by x.starts_at),'[]')
  from (
    select distinct on (g.id) g.id,g.desired_start_at as starts_at,g.organizer_user_id=p_actor as organizer
    from public.groups g
    left join public.group_members m on m.group_id=g.id
    left join public.players p on p.id=m.player_id
    where g.desired_start_at>now()-interval '1 day'
      and (g.status<>'cancelled' or exists(select 1 from public.events e where e.group_id=g.id))
      and (g.organizer_user_id=p_actor or (p.user_id=p_actor and (m.status in ('reserved','joined') or g.status='cancelled')))
  ) x
$$;

-- A cancelled session's members can still open its page to read the cancellation.
create or replace function public.get_group(p_actor uuid, p_group_id uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare g public.groups%rowtype; pid uuid; member boolean; organizer boolean;
begin
  select * into g from public.groups where id=p_group_id;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  select id into pid from public.players where user_id=p_actor;
  organizer := g.organizer_user_id=p_actor;
  member := pid is not null and exists(select 1 from public.group_members
    where group_id=g.id and player_id=pid
      and (status in ('reserved','joined') or (status='cancelled' and g.status='cancelled')));
  if not (organizer or member or public._sf_is_admin(p_actor) or g.visibility='public') then
    raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  return public._sf_group_summary(g.id) || jsonb_build_object(
    'is_organizer',organizer,'is_member',member,
    'seats',case when organizer or member or public._sf_is_admin(p_actor) then (
      select coalesce(jsonb_agg(jsonb_build_object('seat_id',m.id,'seat_number',m.seat_number,'status',m.status,
        'name',case when m.status in ('reserved','joined') or g.status='cancelled' then p.display_name end,
        'is_me',m.player_id is not distinct from pid and pid is not null) order by m.seat_number),'[]')
      from public.group_members m left join public.players p on p.id=m.player_id
      where m.group_id=g.id and (m.status<>'cancelled' or (g.status='cancelled' and m.player_id is not null))) end);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('admin_cancel_event','mark_event_calendar_removed',
      'event_calendar_payload','_sf_group_summary','list_my_groups','get_group') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
