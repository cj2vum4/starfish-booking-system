begin;

-- When the last seat fills, every member hears it (not only the organizer and the store).
create or replace function public._sf_on_seat_joined() returns trigger
language plpgsql set search_path='' as $$
declare g public.groups%rowtype; joiner uuid; facts jsonb; a uuid; u uuid;
begin
  if new.status<>'joined' or old.status='joined' then return new; end if;
  select * into g from public.groups where id=new.group_id;
  select user_id into joiner from public.players where id=new.player_id;
  if g.status<>'recruiting' or joiner is not distinct from g.organizer_user_id then return new; end if;
  facts := public._sf_group_facts(g.id) || jsonb_build_object('joiner_name',
    (select display_name from public.players where id=new.player_id));
  perform public._sf_notify(g.organizer_user_id,'member_joined',g.id,
    'member_joined:'||new.id||':'||new.player_id,facts);
  if (facts->>'filled')::int>=g.capacity then
    for a in select user_id from public.admin_users loop
      perform public._sf_notify(a,'group_full',g.id,'group_full:'||g.id||':'||a,facts);
    end loop;
    -- The organizer already got "已滿團" in member_joined.
    for u in select * from public._sf_group_member_users(g.id) loop
      if u is distinct from g.organizer_user_id then
        perform public._sf_notify(u,'group_full_members',g.id,'group_full_members:'||g.id||':'||u,facts);
      end if;
    end loop;
  end if;
  return new;
end $$;
revoke all on function public._sf_on_seat_joined() from public,anon,authenticated;

commit;
