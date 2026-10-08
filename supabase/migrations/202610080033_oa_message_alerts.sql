begin;

-- Alerts contain processing metadata only. Chat content stays in LINE OA.
create table public.oa_message_alert_settings (
  singleton boolean primary key default true check (singleton),
  recipient_user_id uuid references public.users(id) on delete restrict,
  enabled boolean not null default false,
  cooldown_seconds integer not null default 300 check (cooldown_seconds between 0 and 3600),
  check (not enabled or recipient_user_id is not null)
);
create table public.oa_message_events (
  webhook_event_id text primary key check (length(webhook_event_id) between 1 and 128),
  event_at timestamptz not null,
  processed_at timestamptz not null default now()
);
create table public.oa_message_alert_senders (
  line_user_id text primary key check (line_user_id ~ '^U[0-9a-f]{32}$'),
  last_alert_at timestamptz not null
);
create table public.oa_message_alerts (
  id uuid primary key default gen_random_uuid(),
  webhook_event_id text not null unique references public.oa_message_events(webhook_event_id),
  recipient_user_id uuid not null references public.users(id) on delete restrict,
  retry_key uuid not null default gen_random_uuid() unique,
  status text not null default 'pending' check (status in ('pending','failed','sent','skipped')),
  attempts integer not null default 0,
  error_code text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index oa_message_alerts_pending on public.oa_message_alerts(created_at)
  where status in ('pending','failed');

-- Pin the current sole store administrator, never automatically add future admins.
insert into public.oa_message_alert_settings(singleton,recipient_user_id,enabled)
select true, case when count(*)=1 then (array_agg(user_id))[1] end, count(*)=1
from public.admin_users;

create function public.process_oa_message_alerts(p_events jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare e jsonb; cfg public.oa_message_alert_settings%rowtype; inserted integer;
  previous timestamptz; event_time timestamptz; out jsonb; pending_count integer;
begin
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events)>1000 then
    raise exception 'invalid message events' using errcode='22023';
  end if;
  -- Serializes dedupe and per-sender cooldown, including concurrent webhook deliveries.
  select * into cfg from public.oa_message_alert_settings where singleton for update;
  for e in select value from jsonb_array_elements(p_events) loop
    if coalesce(e->>'userId','') !~ '^U[0-9a-f]{32}$'
      or coalesce(length(e->>'webhookEventId'),0) not between 1 and 128
      or coalesce(e->>'timestamp','') !~ '^[0-9]{1,16}$' then
      raise exception 'invalid message event' using errcode='22023';
    end if;
    event_time := to_timestamp((e->>'timestamp')::numeric/1000);
    insert into public.oa_message_events(webhook_event_id,event_at)
      values(e->>'webhookEventId',event_time) on conflict do nothing;
    get diagnostics inserted = row_count;
    if inserted=0 or not cfg.enabled or event_time<now()-interval '1 day'
      or event_time>now()+interval '5 minutes' then continue; end if;
    -- Store's own LINE tests/replies must not create a notification loop.
    if exists(select 1 from public.admin_users a join public.users u on u.id=a.user_id
      where u.line_user_id=e->>'userId') then continue; end if;
    if not exists(select 1 from public.admin_users where user_id=cfg.recipient_user_id) then continue; end if;
    select last_alert_at into previous from public.oa_message_alert_senders where line_user_id=e->>'userId';
    if previous is not null and previous>now()-make_interval(secs=>cfg.cooldown_seconds) then continue; end if;
    insert into public.oa_message_alert_senders(line_user_id,last_alert_at) values(e->>'userId',now())
      on conflict(line_user_id) do update set last_alert_at=excluded.last_alert_at;
    insert into public.oa_message_alerts(webhook_event_id,recipient_user_id)
      values(e->>'webhookEventId',cfg.recipient_user_id);
  end loop;
  update public.oa_message_alerts n set status='skipped',error_code='STALE_OR_DISABLED'
    where status in ('pending','failed') and (created_at<now()-interval '1 day' or not cfg.enabled
      or n.recipient_user_id is distinct from cfg.recipient_user_id
      or not exists(select 1 from public.admin_users where user_id=n.recipient_user_id));
  select count(*) into pending_count from public.oa_message_alerts where status in ('pending','failed');
  select coalesce(jsonb_agg(jsonb_build_object('id',n.id,'retry_key',n.retry_key,
    'line_user_id',u.line_user_id,'friend_status',u.oa_friend_status)),'[]') into out
    from (select * from public.oa_message_alerts where status in ('pending','failed')
      order by created_at,id limit 20) n join public.users u on u.id=n.recipient_user_id;
  return jsonb_build_object('alerts',out,'pending_count',pending_count);
end $$;

create function public.complete_oa_message_alert(p_id uuid,p_result text,p_error text default null)
returns void language plpgsql security invoker set search_path='' as $$
begin
  if p_result is null or p_result not in ('sent','failed','skipped') then
    raise exception 'invalid alert result' using errcode='22023';
  end if;
  update public.oa_message_alerts set status=p_result,attempts=attempts+1,
    error_code=left(p_error,80),sent_at=case when p_result='sent' then now() end
    where id=p_id and status in ('pending','failed');
end $$;

alter table public.oa_message_alert_settings enable row level security;
alter table public.oa_message_events enable row level security;
alter table public.oa_message_alert_senders enable row level security;
alter table public.oa_message_alerts enable row level security;
revoke all on public.oa_message_alert_settings,public.oa_message_events,
  public.oa_message_alert_senders,public.oa_message_alerts from public,anon,authenticated;
grant select,insert,update,delete on public.oa_message_alert_settings,public.oa_message_events,
  public.oa_message_alert_senders,public.oa_message_alerts to service_role;
revoke all on function public.process_oa_message_alerts(jsonb),
  public.complete_oa_message_alert(uuid,text,text) from public,anon,authenticated;
grant execute on function public.process_oa_message_alerts(jsonb),
  public.complete_oa_message_alert(uuid,text,text) to service_role;

commit;
