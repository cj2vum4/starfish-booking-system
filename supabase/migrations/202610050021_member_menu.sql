begin;

-- LINE users who get the 老玩家 Rich Menu: anyone with at least one recorded play.
-- (Phase 2 adds players who bind an earlier 玩本記錄 identity.) Self-test players excluded.
create function public.member_menu_line_ids()
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(distinct u.line_user_id),'[]')
  from public.player_game_history h
  join public.players p on p.id=h.player_id
  join public.users u on u.id=p.user_id
  where u.line_user_id not like 'Ufeedfacefeedface%'
$$;

revoke all on function public.member_menu_line_ids() from public,anon,authenticated;
grant execute on function public.member_menu_line_ids() to service_role;

commit;
