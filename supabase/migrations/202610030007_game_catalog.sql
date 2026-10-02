begin;

-- The script catalog's source of truth is cj2vum4/starfishlarp scripts.js on GitHub.
-- admin_sync_games mirrors it; scripts removed there are deactivated, never deleted,
-- because past groups, events and play history keep pointing at them.

alter table public.games alter column price_cents drop not null;  -- not published on GitHub
alter table public.games add column players_label text;
alter table public.games add column synced_at timestamptz;

create function public.admin_sync_games(p_actor uuid, p_games jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare g jsonb; n integer := 0; off integer;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if jsonb_typeof(p_games) is distinct from 'array' or jsonb_array_length(p_games) not between 1 and 500 then
    raise exception 'INVALID_CATALOG' using errcode='P0001'; end if;
  for g in select value from jsonb_array_elements(p_games) loop
    if coalesce(g->>'slug','') !~ '^[a-z0-9][a-z0-9-]*$' or coalesce(length(trim(g->>'title')),0) not between 1 and 200
      or (g->>'min_players')::int not between 1 and 50 or (g->>'max_players')::int not between (g->>'min_players')::int and 50
      or (g->>'duration_minutes')::int not between 30 and 720 then
      raise exception 'INVALID_CATALOG' using errcode='P0001';
    end if;
    insert into public.games as x(slug,title,min_players,max_players,duration_minutes,genres,difficulty,
        players_label,image_url,source_url,active,synced_at)
      values (g->>'slug',trim(g->>'title'),(g->>'min_players')::int,(g->>'max_players')::int,
        (g->>'duration_minutes')::int,
        coalesce((select array_agg(left(t,40)) from jsonb_array_elements_text(g->'genres') t),'{}'),
        left(g->>'difficulty',20),left(g->>'players_label',100),
        nullif(g->>'image_url',''),nullif(g->>'source_url',''),true,now())
      on conflict (slug) do update set title=excluded.title,min_players=excluded.min_players,
        max_players=excluded.max_players,duration_minutes=excluded.duration_minutes,genres=excluded.genres,
        difficulty=excluded.difficulty,players_label=excluded.players_label,image_url=excluded.image_url,
        source_url=excluded.source_url,active=true,synced_at=excluded.synced_at;
    n := n+1;
  end loop;
  update public.games set active=false
    where active and synced_at is not null and slug not in (select value->>'slug' from jsonb_array_elements(p_games));
  get diagnostics off = row_count;
  perform public._sf_audit(p_actor,'games.sync','game',null,jsonb_build_object('synced',n,'deactivated',off));
  return jsonb_build_object('synced',n,'deactivated',off);
end $$;

create or replace function public.list_active_games()
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('game_id',id,'slug',slug,'title',title,'min_players',min_players,
    'max_players',max_players,'players_label',players_label,'duration_minutes',duration_minutes,
    'difficulty',difficulty,'genres',to_jsonb(genres),'image_url',image_url,'source_url',source_url)
    order by min_players,title),'[]')
  from public.games where active
$$;

-- An event needs a price per seat; GitHub has none, so the store supplies it at confirmation.
create or replace function public._sf_event_price(p_price_cents integer, p_game_price integer) returns integer
language plpgsql immutable set search_path='' as $$
begin
  if p_price_cents is not null and p_price_cents<0 then raise exception 'INVALID_PRICE' using errcode='P0001'; end if;
  if coalesce(p_price_cents,p_game_price) is null then raise exception 'PRICE_REQUIRED' using errcode='P0001'; end if;
  return coalesce(p_price_cents,p_game_price);
end $$;

create or replace function public.admin_confirm_group_event(p_actor uuid, p_group_id uuid,
  p_venue text, p_dm_name text, p_game_id uuid default null, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; gm public.games%rowtype; s public.time_slots%rowtype; ev uuid; bk uuid; n integer;
  price integer;
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
  price := public._sf_event_price(p_price_cents,gm.price_cents);

  insert into public.events(group_id,game_id,starts_at,capacity,price_cents,venue,dm_name,visibility,slot_id)
    values (g.id,gm.id,s.starts_at,g.capacity,price,p_venue,p_dm_name,g.visibility,s.id)
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
  return jsonb_build_object('event_id',ev,'booking_id',bk,'participants',n,'created',true);
end $$;

create or replace function public.admin_create_event(p_actor uuid, p_starts_at timestamptz, p_game_id uuid, p_capacity integer,
  p_venue text, p_dm_name text, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare gm public.games%rowtype; ends timestamptz; ev uuid; sid uuid; price integer;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into gm from public.games where id=p_game_id and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if p_capacity is null or p_capacity not between gm.min_players and gm.max_players then
    raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  price := public._sf_event_price(p_price_cents,gm.price_cents);
  if p_starts_at is null then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  ends := p_starts_at+make_interval(mins=>public._sf_session_minutes(gm.id));
  if not public._sf_time_free(p_starts_at,ends,true) then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name,visibility)
    values (gm.id,p_starts_at,p_capacity,price,p_venue,p_dm_name,'public')
    returning id into ev;
  sid := public._sf_reserve_time(p_starts_at,ends,'booked',null,ev);
  update public.events set slot_id=sid where id=ev;
  perform public._sf_audit(p_actor,'event.create','event',ev,jsonb_build_object('starts_at',p_starts_at));
  return jsonb_build_object('event_id',ev,'starts_at',p_starts_at,'ends_at',ends);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('admin_sync_games','list_active_games','_sf_event_price',
      'admin_confirm_group_event','admin_create_event') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
