begin;

-- The race self-test finds its own synthetic targets (created by scripts/selftest/race_setup.sql),
-- so a run is a single request and never needs IDs copied by hand.
create function public.selftest_targets()
returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('game_id',g.id,
    'event_id',(select e.id from public.events e where e.game_id=g.id order by e.created_at limit 1),
    'user_ids',(select coalesce(jsonb_agg(u.id order by u.line_user_id),'[]') from public.users u
      where u.line_user_id like 'Ufeedfacefeedface%'
        and not exists(select 1 from public.booking_participants bp join public.players p on p.id=bp.player_id
          join public.events e on e.id=bp.event_id where p.user_id=u.id and e.game_id=g.id)))
  from public.games g where g.slug='qa-stress-race'
$$;
revoke all on function public.selftest_targets() from public,anon,authenticated;
grant execute on function public.selftest_targets() to service_role;

commit;
