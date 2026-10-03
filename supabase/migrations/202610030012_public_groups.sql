begin;

-- Public recruiting: organizers can open a private group to everyone (or close it again)
-- while it is recruiting, and players can browse groups that still have open seats.

create function public.set_group_visibility(p_actor uuid, p_group_id uuid, p_visibility text)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype;
begin
  if p_visibility is null or p_visibility not in ('public','private') then
    raise exception 'INVALID_VISIBILITY' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found or g.organizer_user_id<>p_actor then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status<>'recruiting' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  if g.visibility=p_visibility then return jsonb_build_object('visibility',p_visibility,'changed',false); end if;
  update public.groups set visibility=p_visibility where id=g.id;
  perform public._sf_audit(p_actor,'group.visibility','group',g.id,jsonb_build_object('visibility',p_visibility));
  return jsonb_build_object('visibility',p_visibility,'changed',true);
end $$;

-- 缺人場次: public, recruiting, still has open seats, not yet started. No member names.
create function public.list_public_groups()
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(x.summary order by x.starts_at),'[]')
  from (
    select public._sf_group_summary(g.id) as summary, g.desired_start_at as starts_at
    from public.groups g
    where g.visibility='public' and g.status='recruiting' and g.desired_start_at>now()
      and exists(select 1 from public.group_members m where m.group_id=g.id and m.status='open')
  ) x
$$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('set_group_visibility','list_public_groups') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
