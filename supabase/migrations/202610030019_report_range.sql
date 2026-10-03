begin;

-- The Sheets export reads the last year plus 90 days ahead (455 days), which the original
-- 400-day cap rejected. Allow up to 800 days.
create or replace function public.admin_report(p_actor uuid, p_from timestamptz, p_to timestamptz)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if p_from is null or p_to is null or p_to<=p_from or p_to-p_from>interval '800 days' then
    raise exception 'INVALID_RANGE' using errcode='P0001'; end if;
  return jsonb_build_object(
    'sessions',(select coalesce(jsonb_agg(jsonb_build_object(
        'event_id',e.id,'group_id',e.group_id,'starts_at',e.starts_at,'ends_at',s.ends_at,'title',gm.title,
        'organizer',(select u.display_name from public.groups g join public.users u on u.id=g.organizer_user_id where g.id=e.group_id),
        'source',case when e.group_id is null then '店家開場' else '揪團' end,
        'status',e.status,'capacity',e.capacity,
        'booked',(select count(*) from public.booking_participants bp where bp.event_id=e.id and bp.status<>'cancelled'),
        'attended',(select count(*) from public.booking_participants bp where bp.event_id=e.id and bp.attendance='attended'),
        'absent',(select count(*) from public.booking_participants bp where bp.event_id=e.id and bp.attendance='absent'),
        'venue',e.venue,'dm_name',e.dm_name,'price_cents',e.price_cents,'cancel_reason',e.cancel_reason)
      order by e.starts_at),'[]')
      from public.events e join public.games gm on gm.id=e.game_id left join public.time_slots s on s.id=e.slot_id
      where e.starts_at>=p_from and e.starts_at<p_to),
    'attendance',(select coalesce(jsonb_agg(jsonb_build_object('event_id',e.id,'starts_at',e.starts_at,'title',gm.title,
        'player',p.display_name,'has_line',p.user_id is not null,'status',bp.status,'attendance',bp.attendance)
      order by e.starts_at,bp.created_at),'[]')
      from public.booking_participants bp join public.events e on e.id=bp.event_id
      join public.games gm on gm.id=e.game_id join public.players p on p.id=bp.player_id
      where e.starts_at>=p_from and e.starts_at<p_to),
    'players',(select coalesce(jsonb_agg(jsonb_build_object('player',p.display_name,'has_line',p.user_id is not null,
        'oa_friend',u.oa_friend_status,'played',(select count(*) from public.player_game_history h where h.player_id=p.id),
        'last_played',(select max(h.played_at) from public.player_game_history h where h.player_id=p.id),
        'joined_at',p.created_at)
      order by p.created_at),'[]')
      from public.players p left join public.users u on u.id=p.user_id
      where u.line_user_id is null or u.line_user_id not like 'Ufeedfacefeedface%'));
end $$;

revoke all on function public.admin_report(uuid,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.admin_report(uuid,timestamptz,timestamptz) to service_role;

commit;
