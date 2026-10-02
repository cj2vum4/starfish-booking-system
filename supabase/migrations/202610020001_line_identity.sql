begin;

create table public.users (
  id uuid primary key default gen_random_uuid(),
  line_user_id text not null unique check (line_user_id ~ '^U[0-9a-f]{32}$'),
  display_name text,
  picture_url text,
  oa_friend_status text not null default 'unknown'
    check (oa_friend_status in ('active', 'blocked', 'unknown')),
  blocked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz,
  friendship_event_at timestamptz,
  friendship_event_id text,
  check ((oa_friend_status = 'blocked') = (blocked_at is not null))
);

create table public.players (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references public.users(id) on delete restrict,
  display_name text not null check (length(trim(display_name)) between 1 and 100),
  created_at timestamptz not null default now()
);

-- Minimal processing metadata only: no raw message bodies, tokens or profile data.
create table public.line_webhook_events (
  webhook_event_id text primary key check (length(webhook_event_id) between 1 and 128),
  event_type text not null check (event_type in ('follow', 'unfollow')),
  event_at timestamptz not null,
  processed_at timestamptz not null default now()
);

alter table public.users enable row level security;
alter table public.players enable row level security;
alter table public.line_webhook_events enable row level security;
revoke all on public.users, public.players, public.line_webhook_events from public, anon, authenticated;
grant select, insert, update, delete on public.users, public.players, public.line_webhook_events to service_role;

-- Called only after signature verification. The entire batch runs in one transaction.
-- Dedupe and upsert commit together; failed batches remain retryable.
create function public.process_line_events(p_events jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  e jsonb;
  event_time timestamptz;
  inserted_count integer;
  processed integer := 0;
  duplicates integer := 0;
begin
  if jsonb_typeof(p_events) is distinct from 'array' then
    raise exception 'events must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_events) > 1000 then
    raise exception 'too many events' using errcode = '22023';
  end if;

  -- Stable order reduces deadlocks when batches overlap multiple users.
  for e in select value from jsonb_array_elements(p_events)
      order by value->>'userId', value->>'webhookEventId'
  loop
    if e->>'type' is null or e->>'type' not in ('follow', 'unfollow')
       or coalesce(e->>'userId', '') !~ '^U[0-9a-f]{32}$'
       or coalesce(length(e->>'webhookEventId'), 0) not between 1 and 128
       or coalesce(e->>'timestamp', '') !~ '^[0-9]{1,16}$' then
      raise exception 'invalid event' using errcode = '22023';
    end if;
    event_time := to_timestamp((e->>'timestamp')::numeric / 1000);
    insert into public.line_webhook_events(webhook_event_id, event_type, event_at)
      values (e->>'webhookEventId', e->>'type', event_time)
      on conflict (webhook_event_id) do nothing;
    get diagnostics inserted_count = row_count;
    if inserted_count = 0 then
      duplicates := duplicates + 1;
      continue;
    end if;

    insert into public.users as u
      (line_user_id, oa_friend_status, blocked_at, last_seen_at, friendship_event_at, friendship_event_id)
    values (
      e->>'userId',
      case when e->>'type' = 'follow' then 'active' else 'blocked' end,
      case when e->>'type' = 'unfollow' then event_time else null end,
      case when e->>'type' = 'follow' then event_time else null end,
      event_time, e->>'webhookEventId'
    )
    on conflict (line_user_id) do update set
      oa_friend_status = excluded.oa_friend_status,
      blocked_at = excluded.blocked_at,
      last_seen_at = greatest(u.last_seen_at, excluded.last_seen_at),
      friendship_event_at = excluded.friendship_event_at,
      friendship_event_id = excluded.friendship_event_id,
      updated_at = now()
    where u.friendship_event_at is null
      or (excluded.friendship_event_at, excluded.friendship_event_id)
         > (u.friendship_event_at, u.friendship_event_id);
    processed := processed + 1;
  end loop;
  return jsonb_build_object('processed', processed, 'duplicates', duplicates);
end;
$$;

revoke all on function public.process_line_events(jsonb) from public, anon, authenticated;
grant execute on function public.process_line_events(jsonb) to service_role;
comment on function public.process_line_events(jsonb) is
  'Server-only transactional LINE follow/unfollow ingestion; call after HMAC verification.';

commit;
