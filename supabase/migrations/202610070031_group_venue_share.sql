begin;

-- 店家決定：主揪開團時就選場地（南港／北車／新竹交大，或自選地點），成團前可改；
-- 分享揪團時帶出日期、時間、劇本、價格、人數、地址、劇本介紹與影片連結。
alter table public.groups add column venue text not null default '南港' check (char_length(venue) between 1 and 60);
alter table public.games add column video_url text check (video_url is null or video_url ~ '^https://');

create or replace function public._sf_apply_catalog(p_actor uuid, p_games jsonb, p_source text)
returns jsonb language plpgsql set search_path='' as $$
declare g jsonb; n integer := 0; off integer;
begin
  if jsonb_typeof(p_games) is distinct from 'array' or jsonb_array_length(p_games) not between 1 and 500 then
    raise exception 'INVALID_CATALOG' using errcode='P0001'; end if;
  for g in select value from jsonb_array_elements(p_games) loop
    if coalesce(g->>'slug','') !~ '^[a-z0-9][a-z0-9-]*$' or coalesce(length(trim(g->>'title')),0) not between 1 and 200
      or (g->>'min_players')::int not between 1 and 50 or (g->>'max_players')::int not between (g->>'min_players')::int and 50
      or (g->>'duration_minutes')::int not between 30 and 720 then
      raise exception 'INVALID_CATALOG' using errcode='P0001';
    end if;
    insert into public.games as x(slug,title,min_players,max_players,duration_minutes,genres,difficulty,
        players_label,image_url,source_url,active,synced_at,review_key,video_url)
      values (g->>'slug',trim(g->>'title'),(g->>'min_players')::int,(g->>'max_players')::int,
        (g->>'duration_minutes')::int,
        coalesce((select array_agg(left(t,40)) from jsonb_array_elements_text(g->'genres') t),'{}'),
        left(g->>'difficulty',20),left(g->>'players_label',100),
        nullif(g->>'image_url',''),nullif(g->>'source_url',''),true,now(),coalesce(nullif(g->>'review_key',''),trim(g->>'title')),
        case when g->>'video_url' ~ '^https://' then left(g->>'video_url',300) end)
      on conflict (slug) do update set title=excluded.title,min_players=excluded.min_players,
        max_players=excluded.max_players,duration_minutes=excluded.duration_minutes,genres=excluded.genres,
        difficulty=excluded.difficulty,players_label=excluded.players_label,image_url=excluded.image_url,
        review_key=excluded.review_key,video_url=excluded.video_url,source_url=excluded.source_url,active=true,synced_at=excluded.synced_at;
    n := n+1;
  end loop;
  update public.games set active=false
    where active and synced_at is not null and slug not in (select value->>'slug' from jsonb_array_elements(p_games));
  get diagnostics off = row_count;
  perform public._sf_audit(p_actor,'games.sync','game',null,
    jsonb_build_object('synced',n,'deactivated',off,'source',left(p_source,80)));
  return jsonb_build_object('synced',n,'deactivated',off);
end $$;

drop function public.create_group(uuid,uuid,timestamptz,integer,uuid,text[],text,text);
create function public.create_group(p_actor uuid, p_request_id uuid, p_starts_at timestamptz,
  p_capacity integer, p_game_id uuid default null, p_preferences text[] default '{}',
  p_note text default '', p_visibility text default 'private', p_venue text default '南港')
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
  if char_length(btrim(coalesce(p_venue,''))) not between 1 and 60 then raise exception 'INVALID_VENUE' using errcode='P0001'; end if;
  if p_game_id is not null then
    select min_players,max_players into gmin,gmax from public.games where id=p_game_id and active;
    if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
    if p_capacity not between gmin and gmax then raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  end if;
  if p_starts_at is null then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;
  ends := p_starts_at+make_interval(mins=>public._sf_session_minutes(p_game_id));
  if not public._sf_time_free(p_starts_at,ends) then raise exception 'SLOT_UNAVAILABLE' using errcode='P0001'; end if;

  pid := public._sf_actor_player(p_actor);
  insert into public.groups(organizer_user_id,game_id,desired_start_at,capacity,preferences,note,visibility,request_id,venue)
    values (p_actor,p_game_id,p_starts_at,p_capacity,coalesce(p_preferences,'{}'),coalesce(p_note,''),
            p_visibility,p_request_id,btrim(p_venue))
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
  perform public._sf_audit(p_actor,'group.create','group',gid,jsonb_build_object('capacity',p_capacity,'starts_at',p_starts_at,'venue',btrim(p_venue)));
  return jsonb_build_object('group_id',gid,'starts_at',p_starts_at,'ends_at',ends,'created',true);
end $$;

create function public.set_group_venue(p_actor uuid, p_group_id uuid, p_venue text)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; v text := btrim(coalesce(p_venue,''));
begin
  if char_length(v) not between 1 and 60 then raise exception 'INVALID_VENUE' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found or g.organizer_user_id<>p_actor then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status not in ('recruiting','pending_confirmation') then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  if g.venue=v then return jsonb_build_object('venue',v,'changed',false); end if;
  update public.groups set venue=v where id=g.id;
  perform public._sf_audit(p_actor,'group.venue','group',g.id,jsonb_build_object('venue',v));
  return jsonb_build_object('venue',v,'changed',true);
end $$;

create or replace function public._sf_group_summary(p_group_id uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'group_id',g.id,'status',g.status,'visibility',g.visibility,'capacity',g.capacity,
    'starts_at',coalesce(s.starts_at,g.desired_start_at),'ends_at',s.ends_at,
    'game_id',g.game_id,'game_title',gm.title,'game_min_players',gm.min_players,'game_max_players',gm.max_players,
    'game_players_label',gm.players_label,'game_source_url',gm.source_url,'game_video_url',gm.video_url,
    'game_price_cents',gm.price_cents,'venue',g.venue,
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

revoke all on function public.create_group(uuid,uuid,timestamptz,integer,uuid,text[],text,text,text),
  public.set_group_venue(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.create_group(uuid,uuid,timestamptz,integer,uuid,text[],text,text,text),
  public.set_group_venue(uuid,uuid,text) to service_role;

commit;
