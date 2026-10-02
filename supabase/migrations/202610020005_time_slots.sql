begin;

-- Bookable time comes from the store's weekly rules, minus anything busy on the owner's
-- Google Calendar (family dinners, other events). One slot can host only one session.

create table public.slot_rules (
  id uuid primary key default gen_random_uuid(),
  weekday integer not null check (weekday between 0 and 6),  -- 0 = Sunday, Asia/Taipei
  start_time time not null,
  duration_minutes integer not null default 240 check (duration_minutes between 30 and 720),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (weekday,start_time)
);

create table public.time_slots (
  id uuid primary key default gen_random_uuid(),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  status text not null default 'open' check (status in ('open','held','booked','closed')),
  group_id uuid unique references public.groups(id) on delete restrict,
  event_id uuid unique references public.events(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (ends_at > starts_at),
  check ((status='held') = (group_id is not null)),
  check ((status='booked') = (event_id is not null)),
  -- Never two live slots over the same time: the store runs one session at a time.
  exclude using gist (tstzrange(starts_at,ends_at,'[)') with &&) where (status <> 'closed')
);
create index time_slots_open on public.time_slots(starts_at) where status='open';

-- Busy periods mirrored from Google Calendar free/busy; contents of events are never stored.
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

-- A slot is available when it is open, in the future and not covered by a busy period.
create function public._sf_slot_free(p_starts timestamptz, p_ends timestamptz) returns boolean
language sql stable set search_path='' as $$
  select p_starts>now() and not exists(select 1 from public.calendar_busy b
    where tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(p_starts,p_ends,'[)'))
$$;

create function public.list_available_slots(p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('slot_id',s.id,'starts_at',s.starts_at,'ends_at',s.ends_at)
    order by s.starts_at),'[]')
  from public.time_slots s
  where s.status='open' and s.starts_at>=p_from and s.starts_at<p_to
    and p_to-p_from<=interval '120 days' and public._sf_slot_free(s.starts_at,s.ends_at)
$$;

-- Creates slots from the weekly rules for each Taipei date in range. Re-running is safe:
-- a slot that would overlap an existing live slot is skipped.
create function public.admin_generate_slots(p_actor uuid, p_from date, p_to date)
returns jsonb language plpgsql set search_path='' as $$
declare n integer;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if p_from is null or p_to is null or p_to<p_from or p_to-p_from>120 then
    raise exception 'INVALID_RANGE' using errcode='P0001'; end if;
  insert into public.time_slots(starts_at,ends_at)
    select (d+r.start_time) at time zone 'Asia/Taipei',
           (d+r.start_time) at time zone 'Asia/Taipei'+make_interval(mins=>r.duration_minutes)
    from generate_series(p_from,p_to,interval '1 day') d
    join public.slot_rules r on r.active and r.weekday=extract(dow from d)
    where (d+r.start_time) at time zone 'Asia/Taipei'>now()
    order by 1
    on conflict do nothing;
  get diagnostics n = row_count;
  perform public._sf_audit(p_actor,'slots.generate','time_slot',null,
    jsonb_build_object('from',p_from,'to',p_to,'created',n));
  return jsonb_build_object('created',n);
end $$;

create function public.admin_close_slot(p_actor uuid, p_slot_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare st text;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select status into st from public.time_slots where id=p_slot_id for update;
  if st is null then raise exception 'SLOT_NOT_FOUND' using errcode='P0001'; end if;
  if st='closed' then return jsonb_build_object('closed',false); end if;
  if st<>'open' then raise exception 'SLOT_IN_USE' using errcode='P0001'; end if;
  update public.time_slots set status='closed' where id=p_slot_id;
  perform public._sf_audit(p_actor,'slot.close','time_slot',p_slot_id);
  return jsonb_build_object('closed',true);
end $$;

-- Replaces the mirrored busy periods inside [p_from, p_to) in one transaction.
-- p_busy is the Google free/busy list: [{"start": "...", "end": "..."}].
create function public.sync_calendar_busy(p_from timestamptz, p_to timestamptz, p_busy jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare n integer;
begin
  if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '120 days'
    or jsonb_typeof(p_busy) is distinct from 'array' or jsonb_array_length(p_busy)>2000 then
    raise exception 'INVALID_BUSY' using errcode='P0001'; end if;
  delete from public.calendar_busy where starts_at<p_to and ends_at>p_from;
  insert into public.calendar_busy(starts_at,ends_at)
    select (b->>'start')::timestamptz,(b->>'end')::timestamptz from jsonb_array_elements(p_busy) b;
  get diagnostics n = row_count;
  return jsonb_build_object('busy',n);
end $$;

-- Locks a slot (slot rows are always locked before group rows) and returns it if bookable.
create function public._sf_lock_slot(p_slot_id uuid) returns public.time_slots
language plpgsql set search_path='' as $$
declare s public.time_slots%rowtype;
begin
  select * into s from public.time_slots where id=p_slot_id for update;
  if not found then raise exception 'SLOT_NOT_FOUND' using errcode='P0001'; end if;
  return s;
end $$;

-- 開團改為選擇時段：時段在開團當下即被此團佔住，其他人不能再選。
drop function public.create_group(uuid,uuid,timestamptz,integer,uuid,text[],text,text);
create function public.create_group(p_actor uuid, p_request_id uuid, p_slot_id uuid,
  p_capacity integer, p_game_id uuid default null, p_preferences text[] default '{}',
  p_note text default '', p_visibility text default 'private')
returns jsonb language plpgsql set search_path='' as $$
declare gid uuid; pid uuid; gmin integer; gmax integer; s public.time_slots%rowtype;
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

  s := public._sf_lock_slot(p_slot_id);
  -- A concurrent retry of the same request may have taken the slot while we waited for the lock.
  select id into gid from public.groups where organizer_user_id=p_actor and request_id=p_request_id;
  if gid is not null then return jsonb_build_object('group_id',gid,'created',false); end if;
  if s.status<>'open' or not public._sf_slot_free(s.starts_at,s.ends_at) then
    raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;

  pid := public._sf_actor_player(p_actor);
  gid := gen_random_uuid();
  insert into public.groups(id,organizer_user_id,game_id,desired_start_at,capacity,preferences,note,visibility,
      request_id,slot_id)
    values (gid,p_actor,p_game_id,s.starts_at,p_capacity,coalesce(p_preferences,'{}'),coalesce(p_note,''),
            p_visibility,p_request_id,s.id);
  update public.time_slots set status='held',group_id=gid where id=s.id;
  insert into public.group_members(group_id,seat_number,player_id,status,joined_at)
    select gid,n,case when n=1 then pid end,case when n=1 then 'joined' else 'open' end,case when n=1 then now() end
    from generate_series(1,p_capacity) n;
  perform public._sf_audit(p_actor,'group.create','group',gid,jsonb_build_object('capacity',p_capacity,'slot_id',s.id));
  return jsonb_build_object('group_id',gid,'slot_id',s.id,'starts_at',s.starts_at,'created',true);
end $$;

-- 解散揪團時釋出時段。
create or replace function public.cancel_group(p_actor uuid, p_group_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype;
begin
  perform 1 from public.time_slots where group_id=p_group_id for update;
  select * into g from public.groups where id=p_group_id for update;
  if not found or (g.organizer_user_id<>p_actor and not public._sf_is_admin(p_actor)) then
    raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='cancelled' then return jsonb_build_object('cancelled',false); end if;
  if g.status='confirmed' then raise exception 'GROUP_CONFIRMED' using errcode='P0001'; end if;
  update public.groups set status='cancelled' where id=g.id;
  update public.group_members set status='cancelled' where group_id=g.id and status<>'cancelled';
  update public.invite_tokens set revoked_at=now() where group_id=g.id and used_at is null and revoked_at is null;
  update public.time_slots set status='open',group_id=null where group_id=g.id and status='held';
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
  select * into s from public.time_slots where group_id=p_group_id for update;
  select * into g from public.groups where id=p_group_id for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='confirmed' then
    select id into ev from public.events where group_id=g.id;
    return jsonb_build_object('event_id',ev,'created',false);
  end if;
  if g.status='cancelled' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  if s.id is null then raise exception 'SLOT_NOT_FOUND' using errcode='P0001'; end if;
  if s.starts_at<=now() then raise exception 'INVALID_START_TIME' using errcode='P0001'; end if;
  select * into gm from public.games where id=coalesce(p_game_id,g.game_id) and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if p_price_cents is not null and p_price_cents<0 then raise exception 'INVALID_PRICE' using errcode='P0001'; end if;

  insert into public.events(group_id,game_id,starts_at,capacity,price_cents,venue,dm_name,visibility,slot_id)
    values (g.id,gm.id,s.starts_at,g.capacity,coalesce(p_price_cents,gm.price_cents),p_venue,p_dm_name,g.visibility,s.id)
    returning id into ev;
  update public.time_slots set status='booked',group_id=null,event_id=ev where id=s.id;
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

-- 店家直接開公開場次（缺人場次），同樣佔用一個時段。
create function public.admin_create_event(p_actor uuid, p_slot_id uuid, p_game_id uuid, p_capacity integer,
  p_venue text, p_dm_name text, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare s public.time_slots%rowtype; gm public.games%rowtype; ev uuid;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into gm from public.games where id=p_game_id and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if p_capacity is null or p_capacity not between gm.min_players and gm.max_players then
    raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  if p_price_cents is not null and p_price_cents<0 then raise exception 'INVALID_PRICE' using errcode='P0001'; end if;
  select * into s from public.time_slots where id=p_slot_id for update;
  if not found or s.status<>'open' or not public._sf_slot_free(s.starts_at,s.ends_at) then
    raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name,visibility,slot_id)
    values (gm.id,s.starts_at,p_capacity,coalesce(p_price_cents,gm.price_cents),p_venue,p_dm_name,'public',s.id)
    returning id into ev;
  update public.time_slots set status='booked',event_id=ev where id=s.id;
  perform public._sf_audit(p_actor,'event.create','event',ev,jsonb_build_object('slot_id',s.id));
  return jsonb_build_object('event_id',ev,'starts_at',s.starts_at);
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
    where n.nspname='public' and p.proname in ('_sf_slot_free','list_available_slots','admin_generate_slots',
      'admin_close_slot','sync_calendar_busy','_sf_lock_slot','create_group','cancel_group',
      'admin_confirm_group_event','admin_create_event') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
