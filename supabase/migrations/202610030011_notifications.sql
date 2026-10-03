begin;

-- LINE notifications use an outbox: triggers enqueue rows in notification_logs inside the
-- same transaction as the change that caused them, and the api function delivers them
-- afterwards with retries. A change that rolls back never notifies anyone.

create function public._sf_notify(p_user_id uuid, p_kind text, p_group_id uuid, p_dedupe text, p_payload jsonb)
returns void language sql set search_path='' as $$
  insert into public.notification_logs(user_id,group_id,notification_type,payload,dedupe_key)
    values (p_user_id,p_group_id,p_kind,p_payload||jsonb_build_object('kind',p_kind,'group_id',p_group_id),p_dedupe)
  on conflict (dedupe_key) do nothing
$$;

-- Everything a message needs, captured when the event happens.
create function public._sf_group_facts(p_group_id uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('starts_at',coalesce(s.starts_at,g.desired_start_at),'ends_at',s.ends_at,
    'game_title',gm.title,'organizer_name',coalesce(u.display_name,'主揪'),'capacity',g.capacity,
    'filled',(select count(*) from public.group_members m where m.group_id=g.id and m.status in ('reserved','joined')),
    'venue',e.venue,'price_cents',e.price_cents,'dm_name',e.dm_name,'cancel_reason',e.cancel_reason)
  from public.groups g join public.users u on u.id=g.organizer_user_id
  left join public.time_slots s on s.id=g.slot_id left join public.games gm on gm.id=g.game_id
  left join public.events e on e.group_id=g.id
  where g.id=p_group_id
$$;

-- Members with a LINE account (placeholders without one cannot be messaged).
create function public._sf_group_member_users(p_group_id uuid) returns setof uuid
language sql stable set search_path='' as $$
  select distinct p.user_id from public.group_members m join public.players p on p.id=m.player_id
  where m.group_id=p_group_id and p.user_id is not null
$$;

create function public._sf_on_seat_joined() returns trigger
language plpgsql set search_path='' as $$
declare g public.groups%rowtype; joiner uuid; facts jsonb; a uuid;
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
  end if;
  return new;
end $$;
create trigger notify_seat_joined after update of status on public.group_members
  for each row execute function public._sf_on_seat_joined();

create function public._sf_on_group_created() returns trigger
language plpgsql set search_path='' as $$
declare a uuid;
begin
  -- Facts are read after the seats exist, so this runs as a deferred constraint trigger.
  for a in select user_id from public.admin_users where user_id<>new.organizer_user_id loop
    perform public._sf_notify(a,'group_created',new.id,'group_created:'||new.id||':'||a,public._sf_group_facts(new.id));
  end loop;
  return null;
end $$;
create constraint trigger notify_group_created after insert on public.groups
  deferrable initially deferred for each row execute function public._sf_on_group_created();

create function public._sf_on_group_status() returns trigger
language plpgsql set search_path='' as $$
declare u uuid; facts jsonb; kind text;
begin
  if new.status=old.status or new.status not in ('confirmed','cancelled') then return null; end if;
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
-- Deferred so cancellation sees the event's reason and members' final state.
create constraint trigger notify_group_status after update of status on public.groups
  deferrable initially deferred for each row execute function public._sf_on_group_status();

-- Delivery: claim a batch (skipping rows another worker holds), then report each result.
create function public.claim_notifications(p_limit integer default 20)
returns jsonb language plpgsql set search_path='' as $$
declare out jsonb;
begin
  -- News older than a day is not worth sending (e.g. queued before LINE was configured).
  update public.notification_logs set status='skipped',error_code='STALE',locked_until=null
    where status in ('pending','failed','sending') and created_at<now()-interval '1 day';
  with picked as (
    select n.id from public.notification_logs n
    where (n.status='pending' or (n.status='failed' and n.next_attempt_at<=now())
      or (n.status='sending' and n.locked_until<now()))
    order by n.created_at limit least(greatest(coalesce(p_limit,20),1),100)
    for update skip locked
  ), claimed as (
    update public.notification_logs n set status='sending',attempts=n.attempts+1,locked_until=now()+interval '2 minutes'
    from picked where n.id=picked.id
    returning n.id,n.user_id,n.payload,n.retry_key,n.attempts
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'line_user_id',u.line_user_id,'friend_status',u.oa_friend_status,
    'payload',c.payload,'retry_key',c.retry_key,'attempts',c.attempts)),'[]') into out
  from claimed c join public.users u on u.id=c.user_id;
  return out;
end $$;

create function public.complete_notification(p_id uuid, p_result text, p_error text default null)
returns jsonb language plpgsql set search_path='' as $$
declare n public.notification_logs%rowtype;
begin
  if p_result not in ('sent','failed','skipped') then raise exception 'INVALID_RESULT' using errcode='P0001'; end if;
  select * into n from public.notification_logs where id=p_id for update;
  if not found then raise exception 'NOTIFICATION_NOT_FOUND' using errcode='P0001'; end if;
  update public.notification_logs set
    status=case when p_result='failed' and n.attempts>=5 then 'skipped' else p_result end,
    error_code=left(p_error,80), locked_until=null,
    sent_at=case when p_result='sent' then now() end,
    -- Backoff: 1, 2, 4, 8 minutes.
    next_attempt_at=case when p_result='failed' then now()+make_interval(mins=>power(2,least(n.attempts,6)-1)::int) else n.next_attempt_at end
  where id=p_id;
  return jsonb_build_object('ok',true);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_notify','_sf_group_facts','_sf_group_member_users',
      '_sf_on_seat_joined','_sf_on_group_created','_sf_on_group_status','claim_notifications','complete_notification') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
