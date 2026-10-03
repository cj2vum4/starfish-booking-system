begin;

-- Guard for the live race self-test (P6 acceptance: 20 concurrent requests for the last
-- seat). The api hook may only drive synthetic players (LINE IDs starting with the
-- self-test prefix) against a synthetic script (slug qa-stress-*), never real data.
create function public.selftest_targets_ok(p_user_ids uuid[], p_game_id uuid, p_event_id uuid default null)
returns boolean language sql stable set search_path='' as $$
  select cardinality(p_user_ids) between 2 and 50
    and (p_event_id is null or exists(select 1 from public.events where id=p_event_id and game_id=p_game_id))
    and (select count(*) from public.users where id=any(p_user_ids)
         and line_user_id like 'Ufeedfacefeedface%')=cardinality(p_user_ids)
    and exists(select 1 from public.games where id=p_game_id and slug like 'qa-stress-%')
$$;

-- Synthetic self-test players never cause LINE messages (e.g. "new group" to the store).
create or replace function public._sf_notify(p_user_id uuid, p_kind text, p_group_id uuid, p_dedupe text, p_payload jsonb)
returns void language sql set search_path='' as $$
  insert into public.notification_logs(user_id,group_id,notification_type,payload,dedupe_key)
    select p_user_id,p_group_id,p_kind,p_payload||jsonb_build_object('kind',p_kind,'group_id',p_group_id),p_dedupe
    where not exists(select 1 from public.groups g join public.users u on u.id=g.organizer_user_id
      where g.id=p_group_id and u.line_user_id like 'Ufeedfacefeedface%')
  on conflict (dedupe_key) do nothing
$$;
revoke all on function public._sf_notify(uuid,text,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public._sf_notify(uuid,text,uuid,text,jsonb) to service_role;

revoke all on function public.selftest_targets_ok(uuid[],uuid,uuid) from public,anon,authenticated;
grant execute on function public.selftest_targets_ok(uuid[],uuid,uuid) to service_role;

commit;
