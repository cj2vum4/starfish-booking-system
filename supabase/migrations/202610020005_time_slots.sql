begin;

-- Bookable time = the store's weekly opening windows, minus sessions already held or
-- booked, minus anything busy on the owner's Google Calendar. Sessions start on the hour
-- and must end inside the window. The store runs one session at a time.

create table public.slot_rules (
  id uuid primary key default gen_random_uuid(),
  weekday integer not null check (weekday between 0 and 6),  -- 0 = Sunday, Asia/Taipei
  start_time time not null,
  end_time time not null,  -- '24:00' means midnight at the end of the day
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (end_time > start_time),
  unique (weekday,start_time)
);

-- Store opening windows (Asia/Taipei): Mon/Tue/Thu/Fri 19–24, Sat 9–24, Sun 13–24.
insert into public.slot_rules(weekday,start_time,end_time) values
  (1,'19:00','24:00'),(2,'19:00','24:00'),(4,'19:00','24:00'),(5,'19:00','24:00'),
  (6,'09:00','24:00'),(0,'13:00','24:00');

-- Reserved time ranges. A held range belongs to a recruiting group; a booked range to an
-- event. Released ranges stay as history and no longer block the calendar.
create table public.time_slots (
  id uuid primary key default gen_random_uuid(),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null check (status in ('held','booked','released')),
  group_id uuid unique references public.groups(id) on delete restrict,
  event_id uuid unique references public.events(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check (group_id is not null or event_id is not null),
  check (status<>'booked' or event_id is not null),
  exclude using gist (tstzrange(starts_at,ends_at,'[)') with &&) where (status <> 'released')
);

-- Busy periods mirrored from Google Calendar free/busy; event titles are never stored.
create table public.calendar_busy (
  id bigint generated always as identity primary key,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  synced_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index calendar_busy_range on public.calendar_busy using gist (tstzrange(starts_at,ends_at,'[)'));

alter table public.groups add column slot_id uuid references public.time_slots(id) on delete restrict;
alter table public.events add column slot_id uuid unique references public.time_slots(id) on delete restrict;

create function public._sf_session_minutes(p_game_id uuid) returns integer
language sql stable set search_path='' as $$
  select coalesce((select duration_minutes from public.games where id=p_game_id),240)
$$;

-- True when [p_starts, p_ends) is in the future, free of busy periods and live sessions,
-- and (unless p_any_time) starts on the hour inside an opening window it does not exceed.
create function public._sf_time_free(p_starts timestamptz, p_ends timestamptz, p_any_time boolean default false)
returns boolean language sql stable set search_path='' as $$
  select p_starts>now()
    and not exists(select 1 from public.calendar_busy b
      where tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_starts,p_ends,'[)'))
    and not exists(select 1 from public.time_slots s where s.status<>'released'
      and tstzrange(s.starts_at,s.ends_at,'[)') && tstzrange(p_starts,p_ends,'[)'))
    and (p_any_time or (
      date_trunc('hour',p_starts)=p_starts and exists(
        select 1 from public.slot_rules r,
          lateral (select (p_starts at time zone 'Asia/Taipei') as local_start) l
        where r.active and r.weekday=extract(dow from l.local_start)
          and l.local_start::time>=r.start_time
          and p_ends<=(l.local_start::date+r.end_time) at time zone 'Asia/Taipei')))
$$;

-- Candidate start times on the hour, for sessions of p_minutes, within [p_from, p_to).
create function public.list_available_starts(p_from timestamptz, p_to timestamptz, p_minutes integer default 240)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '62 days'
    or p_minutes is null or p_minutes not between 30 and 720 then
    raise exception 'INVALID_RANGE' using errcode='P0001'; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('starts_at',c.s,'ends_at',c.s+make_interval(mins=>p_minutes))
      order by c.s),'[]')
    from (
      -- Dates are Taipei wall-clock dates; timestamps are converted back at the end.
      select distinct (g.d::date+r.start_time+make_interval(hours=>h)) at time zone 'Asia/Taipei' as s
      from generate_series(date_trunc('day',p_from at time zone 'Asia/Taipei'),
             date_trunc('day',p_to at time zone 'Asia/Taipei'),interval '1 day') g(d)
      join public.slot_rules r on r.active and r.weekday=extract(dow from g.d)
      cross join generate_series(0,23) h
      where g.d::date+r.start_time+make_interval(hours=>h)+make_interval(mins=>p_minutes)<=g.d::date+r.end_time
    ) c
    where c.s>=p_from and c.s<p_to and public._sf_time_free(c.s,c.s+make_interval(mins=>p_minutes)));
end $$;

-- Replaces the mirrored busy periods inside [p_from, p_to) in one transaction.
-- p_busy is the Google free/busy list: [{"start": "...", "end": "..."}].
create function public.sync_calendar_busy(p_from timestamptz, p_to timestamptz, p_busy jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare n integer;
begin
  if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '62 days'
    or jsonb_typeof(p_busy) is distinct from 'array' or jsonb_array_length(p_busy)>2000 then
    raise exception 'INVALID_BUSY' using errcode='P0001'; end if;
  -- Busy periods that extend past the window keep their outside parts.
  with old as (delete from public.calendar_busy where starts_at<p_to and ends_at>p_from returning starts_at,ends_at)
  insert into public.calendar_busy(starts_at,ends_at)
    select starts_at,p_from from old where starts_at<p_from
    union all select p_to,ends_at from old where ends_at>p_to
    union all select (b->>'start')::timestamptz,(b->>'end')::timestamptz from jsonb_array_elements(p_busy) b;
  get diagnostics n = row_count;
  return jsonb_build_object('busy',n);
end $$;

-- Inserts the reservation; a concurrent overlapping reservation surfaces as SLOT_UNAVAILABLE.
create function public._sf_reserve_time(p_starts timestamptz, p_ends timestamptz, p_status text,
  p_group_id uuid, p_event_id uuid) returns uuid
language plpgsql set search_path='' as $$
declare sid uuid;
begin
  insert into public.time_slots(starts_at,ends_at,status,group_id,event_id)
    values (p_starts,p_ends,p_status,p_group_id,p_event_id) returning id into sid;
  return sid;
exception when exclusion_violation then
  raise exception 'SLOT_UNAVAILABLE' using errcode='P0001';
end $$;

-- 開團：選擇開場時間，開團當下即佔住該時段，其他人看不到也選不到。
drop function public.create_group(uuid,uuid,timestamptz,integer,uuid,text[],text,text);
create function public.create_group(p_actor uuid, p_request_id uuid, p_starts_at timestamptz,
  p_capacity integer, p_game_id uuid default null, p_preferences text[] default '{}',
  p_note text default '', p_visibility text default 'private')
returns jsonb language plpgsql set search_path='' as $$
declare gid uuid; pid uuid; gmin integer; gmax integer; ends timestamptz; sid uuid;
begin
  if p_request_id is null then raise exception 'INVALID_REQUEST' using errcode='P0001'; end if;
  select id into gid from public.groups where organizer_user_id=p_actor and request_id=p_request_id;
  if gid is not null then return jsonb_build_object('group_id',gid,'created',false); end if;

  if p_capacity is null or p_capacity not between 1 and 50 then
    raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  if p_visibility is null or p_visibility not in ('public','private') then
    raise exception 'INVALID_VISIBILITY' using errcode='P0001'; end if;
  if length(coalesce(p_note,''))>2000 then raise exception 'INVALID_NOTE' using errcode='P0001'; end if;
  if p_game_id is not null then
    select min_players,max_players into gmin,gmax from public.games where id=p_game_id and active;
    if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
    if p_capacity not between gmin and gmax then raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  end if;
  if p_starts_at is null then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  ends := p_starts_at+make_interval(mins=>public._sf_session_minutes(p_game_id));
  if not public._sf_time_free(p_starts_at,ends) then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;

  pid := public._sf_actor_player(p_actor);
  insert into public.groups(organizer_user_id,game_id,desired_start_at,capacity,preferences,note,visibility,request_id)
    values (p_actor,p_game_id,p_starts_at,p_capacity,coalesce(p_preferences,'{}'),coalesce(p_note,''),
            p_visibility,p_request_id)
    on conflict (organizer_user_id,request_id) do nothing returning id into gid;
  if gid is null then
    select id into gid from public.groups where organizer_user_id=p_actor and request_id=p_request_id;
    return jsonb_build_object('group_id',gid,'created',false);
  end if;
  sid := public._sf_reserve_time(p_starts_at,ends,'held',gid,null);
  update public.groups set slot_id=sid where id=gid;
  insert into public.group_members(group_id,seat_number,player_id,status,joined_at)
    select gid,n,case when n=1 then pid end,case when n=1 then 'joined' else 'open' end,case when n=1 then now() end
    from generate_series(1,p_capacity) n;
  perform public._sf_audit(p_actor,'group.create','group',gid,jsonb_build_object('capacity',p_capacity,'starts_at',p_starts_at));
  return jsonb_build_object('group_id',gid,'starts_at',p_starts_at,'ends_at',ends,'created',true);
end $$;

-- 解散揪團時釋出時段。
create or replace function public.cancel_group(p_actor uuid, p_group_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype;
begin
  select * into g from public.groups where id=p_group_id for update;
  if not found or (g.organizer_user_id<>p_actor and not public._sf_is_admin(p_actor)) then
    raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='cancelled' then return jsonb_build_object('cancelled',false); end if;
  if g.status='confirmed' then raise exception 'GROUP_CONFIRMED' using errcode='P0001'; end if;
  update public.groups set status='cancelled' where id=g.id;
  update public.group_members set status='cancelled' where group_id=g.id and status<>'cancelled';
  update public.invite_tokens set revoked_at=now() where group_id=g.id and used_at is null and revoked_at is null;
  update public.time_slots set status='released' where group_id=g.id and status='held';
  perform public._sf_audit(p_actor,'group.cancel','group',g.id);
  return jsonb_build_object('cancelled',true);
end $$;

-- 店家確認成場：場次時間取自該團佔住的時段，時段轉為已成場。
drop function public.admin_confirm_group_event(uuid,uuid,timestamptz,text,text,uuid,integer);
create function public.admin_confirm_group_event(p_actor uuid, p_group_id uuid,
  p_venue text, p_dm_name text, p_game_id uuid default null, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; gm public.games%rowtype; s public.time_slots%rowtype; ev uuid; bk uuid; n integer;
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
  if p_price_cents is not null and p_price_cents<0 then raise exception 'INVALID_PRICE' using errcode='P0001'; end if;

  insert into public.events(group_id,game_id,starts_at,capacity,price_cents,venue,dm_name,visibility,slot_id)
    values (g.id,gm.id,s.starts_at,g.capacity,coalesce(p_price_cents,gm.price_cents),p_venue,p_dm_name,g.visibility,s.id)
    returning id into ev;
  update public.time_slots set status='booked',event_id=ev where id=s.id;
  insert into public.bookings(event_id,booker_user_id,request_id) values (ev,g.organizer_user_id,gen_random_uuid())
    returning id into bk;
  insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
    select bk,ev,player_id,coalesce(p_price_cents,gm.price_cents),status from public.group_members
    where group_id=g.id and status in ('reserved','joined') order by seat_number;
  get diagnostics n = row_count;
  update public.groups set status='confirmed',game_id=gm.id where id=g.id;
  perform public._sf_audit(p_actor,'group.confirm_event','event',ev,jsonb_build_object('group_id',g.id,'participants',n));
  return jsonb_build_object('event_id',ev,'booking_id',bk,'participants',n,'created',true);
end $$;

-- 店家直接開公開場次（缺人場次）。店家可開在開放區間以外，但仍不可撞到日曆或其他場次。
create function public.admin_create_event(p_actor uuid, p_starts_at timestamptz, p_game_id uuid, p_capacity integer,
  p_venue text, p_dm_name text, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare gm public.games%rowtype; ends timestamptz; ev uuid; sid uuid;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into gm from public.games where id=p_game_id and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if p_capacity is null or p_capacity not between gm.min_players and gm.max_players then
    raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  if p_price_cents is not null and p_price_cents<0 then raise exception 'INVALID_PRICE' using errcode='P0001'; end if;
  if p_starts_at is null then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  ends := p_starts_at+make_interval(mins=>public._sf_session_minutes(gm.id));
  if not public._sf_time_free(p_starts_at,ends,true) then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name,visibility)
    values (gm.id,p_starts_at,p_capacity,coalesce(p_price_cents,gm.price_cents),p_venue,p_dm_name,'public')
    returning id into ev;
  sid := public._sf_reserve_time(p_starts_at,ends,'booked',null,ev);
  update public.events set slot_id=sid where id=ev;
  perform public._sf_audit(p_actor,'event.create','event',ev,jsonb_build_object('starts_at',p_starts_at));
  return jsonb_build_object('event_id',ev,'starts_at',p_starts_at,'ends_at',ends);
end $$;

do $$ declare t text; f regprocedure;
begin
  foreach t in array array['slot_rules','time_slots','calendar_busy'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select,insert,update,delete on public.%I to service_role',t);
  end loop;
  revoke all on sequence public.calendar_busy_id_seq from public,anon,authenticated;
  grant usage,select on sequence public.calendar_busy_id_seq to service_role;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_session_minutes','_sf_time_free','list_available_starts',
      'sync_calendar_busy','_sf_reserve_time','create_group','cancel_group','admin_confirm_group_event',
      'admin_create_event') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
