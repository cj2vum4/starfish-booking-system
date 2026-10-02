begin;

-- Read models for the LIFF group pages. Members, the organizer and admins see seat names;
-- someone holding only an invite sees the summary (time, organizer, how many seats left).

create function public._sf_group_summary(p_group_id uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'group_id',g.id,'status',g.status,'visibility',g.visibility,'capacity',g.capacity,
    'starts_at',coalesce(s.starts_at,g.desired_start_at),'ends_at',s.ends_at,
    'game_title',gm.title,'preferences',to_jsonb(g.preferences),'note',g.note,
    'organizer_name',coalesce(u.display_name,'主揪'),
    'filled',(select count(*) from public.group_members m where m.group_id=g.id and m.status in ('reserved','joined')))
  from public.groups g
  join public.users u on u.id=g.organizer_user_id
  left join public.time_slots s on s.id=g.slot_id
  left join public.games gm on gm.id=g.game_id
  where g.id=p_group_id
$$;

create function public.get_group(p_actor uuid, p_group_id uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare g public.groups%rowtype; pid uuid; member boolean; organizer boolean;
begin
  select * into g from public.groups where id=p_group_id;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  select id into pid from public.players where user_id=p_actor;
  organizer := g.organizer_user_id=p_actor;
  member := pid is not null and exists(select 1 from public.group_members
    where group_id=g.id and player_id=pid and status in ('reserved','joined'));
  if not (organizer or member or public._sf_is_admin(p_actor) or g.visibility='public') then
    raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  return public._sf_group_summary(g.id) || jsonb_build_object(
    'is_organizer',organizer,'is_member',member,
    'seats',case when organizer or member or public._sf_is_admin(p_actor) then (
      select coalesce(jsonb_agg(jsonb_build_object('seat_id',m.id,'seat_number',m.seat_number,'status',m.status,
        'name',case when m.status in ('reserved','joined') then p.display_name end,
        'is_me',m.player_id is not distinct from pid and pid is not null) order by m.seat_number),'[]')
      from public.group_members m left join public.players p on p.id=m.player_id
      where m.group_id=g.id and m.status<>'cancelled') end);
end $$;

create function public.list_my_groups(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(public._sf_group_summary(x.id)||jsonb_build_object('is_organizer',x.organizer)
    order by x.starts_at),'[]')
  from (
    select distinct on (g.id) g.id,g.desired_start_at as starts_at,g.organizer_user_id=p_actor as organizer
    from public.groups g
    left join public.group_members m on m.group_id=g.id and m.status in ('reserved','joined')
    left join public.players p on p.id=m.player_id
    where g.status<>'cancelled' and g.desired_start_at>now()-interval '1 day'
      and (g.organizer_user_id=p_actor or p.user_id=p_actor)
  ) x
$$;

-- What an invite link points to, so the landing page can show it before the player joins.
create function public.preview_invite(p_actor uuid, p_token_hash text)
returns jsonb language plpgsql stable set search_path='' as $$
declare t public.invite_tokens%rowtype; seat_name text; usable boolean;
begin
  perform public._sf_valid_hash(p_token_hash);
  select * into t from public.invite_tokens where token_hash=p_token_hash;
  if not found or t.purpose='claim_participant' then raise exception 'INVITE_INVALID' using errcode='P0001'; end if;
  usable := t.revoked_at is null and t.expires_at>now() and (t.purpose='join_group' or t.used_at is null);
  if t.purpose='claim_group_seat' then
    select p.display_name into seat_name from public.group_members m join public.players p on p.id=m.player_id
      where m.id=t.group_member_id;
  end if;
  return jsonb_build_object('purpose',t.purpose,'usable',usable,'reserved_for',seat_name,
    'claimed_by_me',t.claimed_by_user_id is not distinct from p_actor and t.used_at is not null)
    || public._sf_group_summary(t.group_id);
end $$;

create function public.list_active_games()
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('game_id',id,'title',title,'min_players',min_players,
    'max_players',max_players,'duration_minutes',duration_minutes) order by title),'[]')
  from public.games where active
$$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_group_summary','get_group','list_my_groups',
      'preview_invite','list_active_games') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
