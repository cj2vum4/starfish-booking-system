begin;

-- 店家決定：開場時間到了還沒成團的揪團直接取消（不另發 LINE 通知）。
-- The API runs this before reading or changing groups, so nobody sees or joins an expired one.
create function public.expire_stale_groups()
returns integer language plpgsql set search_path='' as $$
declare g record; n integer := 0;
begin
  -- Read by the deferred status trigger at commit: expiry is not the organizer dissolving it.
  perform set_config('starfish.quiet_group_cancel','1',true);
  for g in select id from public.groups
      where status in ('recruiting','pending_confirmation') and desired_start_at<=now()
      for update skip locked loop
    update public.groups set status='cancelled' where id=g.id;
    update public.group_members set status='cancelled' where group_id=g.id and status<>'cancelled';
    update public.invite_tokens set revoked_at=now() where group_id=g.id and used_at is null and revoked_at is null;
    update public.time_slots set status='released' where group_id=g.id and status='held';
    perform public._sf_audit(null,'group.expire','group',g.id);
    n := n+1;
  end loop;
  return n;
end $$;
revoke all on function public.expire_stale_groups() from public,anon,authenticated;
grant execute on function public.expire_stale_groups() to service_role;

create or replace function public._sf_on_group_status() returns trigger
language plpgsql set search_path='' as $$
declare u uuid; facts jsonb; kind text;
begin
  if new.status=old.status or new.status not in ('confirmed','cancelled') then return null; end if;
  if new.status='cancelled' and current_setting('starfish.quiet_group_cancel',true)='1' then return null; end if;
  facts := public._sf_group_facts(new.id);
  kind := case when new.status='confirmed' then 'group_confirmed'
    when exists(select 1 from public.events e where e.group_id=new.id) then 'event_cancelled'
    else 'group_dissolved' end;
  for u in select * from public._sf_group_member_users(new.id) loop
    -- The organizer dissolving their own group needs no message about it.
    if kind='group_dissolved' and u=new.organizer_user_id then continue; end if;
    perform public._sf_notify(u,kind,new.id,kind||':'||new.id||':'||u,facts);
  end loop;
  return null;
end $$;

commit;
