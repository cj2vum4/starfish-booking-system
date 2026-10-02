begin;

alter table public.players add column created_by_user_id uuid references public.users(id) on delete restrict;

create table public.games (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]*$'),
  title text not null check (length(trim(title)) between 1 and 200),
  description text not null default '',
  min_players integer not null check (min_players between 1 and 50),
  max_players integer not null check (max_players between min_players and 50),
  genres text[] not null default '{}',
  difficulty text,
  duration_minutes integer check (duration_minutes > 0),
  price_cents integer not null check (price_cents >= 0),
  currency text not null default 'TWD' check (currency = 'TWD'),
  source_url text,
  image_url text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.groups (
  id uuid primary key default gen_random_uuid(),
  organizer_user_id uuid not null references public.users(id) on delete restrict,
  game_id uuid references public.games(id) on delete restrict,
  proposed_game_id uuid references public.games(id) on delete restrict,
  desired_start_at timestamptz not null,
  capacity integer not null check (capacity between 1 and 50),
  preferences text[] not null default '{}',
  note text not null default '' check (length(note) <= 2000),
  visibility text not null default 'private' check (visibility in ('public','private')),
  status text not null default 'recruiting'
    check (status in ('recruiting','pending_confirmation','confirmed','cancelled')),
  request_id uuid not null,
  created_at timestamptz not null default now(),
  unique (organizer_user_id,request_id)
);

create table public.group_members (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete restrict,
  seat_number integer not null check (seat_number between 1 and 50),
  player_id uuid references public.players(id) on delete restrict,
  reserved_by_user_id uuid references public.users(id) on delete restrict,
  status text not null default 'open' check (status in ('open','reserved','joined','cancelled')),
  joined_at timestamptz,
  check ((status in ('reserved','joined') and player_id is not null)
      or (status in ('open','cancelled'))),
  unique (group_id,seat_number)
);
create unique index group_members_one_player on public.group_members(group_id,player_id)
  where status in ('reserved','joined');
create index group_members_player on public.group_members(player_id);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid unique references public.groups(id) on delete restrict,
  game_id uuid not null references public.games(id) on delete restrict,
  starts_at timestamptz not null,
  capacity integer not null check (capacity between 1 and 50),
  price_cents integer not null check (price_cents >= 0),
  currency text not null default 'TWD' check (currency='TWD'),
  venue text not null check (length(trim(venue)) between 1 and 200),
  dm_name text not null check (length(trim(dm_name)) between 1 and 100),
  visibility text not null default 'public' check (visibility in ('public','private')),
  status text not null default 'open' check (status in ('open','confirmed','completed','cancelled')),
  created_at timestamptz not null default now(),
  unique(id,game_id)
);
create index events_recruiting on public.events(starts_at) where status='open' and visibility='public';

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  booker_user_id uuid not null references public.users(id) on delete restrict,
  request_id uuid not null,
  status text not null default 'active' check (status in ('active','cancelled')),
  created_at timestamptz not null default now(),
  unique(booker_user_id,request_id),
  unique(id,event_id)
);
create index bookings_event on public.bookings(event_id);

create table public.booking_participants (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null,
  event_id uuid not null,
  player_id uuid not null references public.players(id) on delete restrict,
  price_cents integer not null check (price_cents >= 0),
  status text not null check (status in ('reserved','joined','cancelled','completed','no_show')),
  attendance text not null default 'unknown' check (attendance in ('unknown','attended','absent')),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  foreign key (booking_id,event_id) references public.bookings(id,event_id) on delete restrict
);
create unique index booking_participants_one_player on public.booking_participants(event_id,player_id)
  where status <> 'cancelled';
create index booking_participants_booking on public.booking_participants(booking_id);
create index booking_participants_player on public.booking_participants(player_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  payer_user_id uuid not null references public.users(id) on delete restrict,
  event_id uuid not null references public.events(id) on delete restrict,
  method text not null check (method in ('cash','bank_transfer','linepay')),
  status text not null default 'unpaid'
    check (status in ('unpaid','pending','paid','failed','cancelled','refund_pending','refunded')),
  amount_cents integer not null check (amount_cents > 0),
  currency text not null default 'TWD' check (currency='TWD'),
  request_id uuid not null,
  provider_transaction_id text unique,
  transfer_last_five text check (transfer_last_five ~ '^[0-9]{5}$'),
  proof_storage_path text,
  paid_at timestamptz,
  refunded_at timestamptz,
  created_at timestamptz not null default now(),
  unique(payer_user_id,request_id)
);
create index payments_event on public.payments(event_id);
create table public.payment_allocations (
  payment_id uuid not null references public.payments(id) on delete restrict,
  participant_id uuid not null references public.booking_participants(id) on delete restrict,
  amount_cents integer not null check (amount_cents >= 0),
  active boolean not null default true,
  primary key(payment_id,participant_id)
);
-- A seat can have one unpaid/pending/paid allocation; cancellation/refund releases it.
create unique index payment_allocations_one_active on public.payment_allocations(participant_id) where active;

create table public.player_game_history (
  player_id uuid not null references public.players(id) on delete restrict,
  game_id uuid not null,
  event_id uuid not null,
  played_at timestamptz not null,
  primary key(player_id,event_id),
  foreign key(event_id,game_id) references public.events(id,game_id) on delete restrict
);
create index player_history_game on public.player_game_history(game_id);

create table public.invite_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  purpose text not null check (purpose in ('join_group','claim_group_seat','claim_participant')),
  group_id uuid references public.groups(id) on delete restrict,
  group_member_id uuid references public.group_members(id) on delete restrict,
  participant_id uuid references public.booking_participants(id) on delete restrict,
  created_by_user_id uuid not null references public.users(id) on delete restrict,
  claimed_by_user_id uuid references public.users(id) on delete restrict,
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  check(expires_at > created_at),
  check ((purpose='join_group' and group_id is not null and group_member_id is null and participant_id is null)
      or (purpose='claim_group_seat' and group_id is not null and group_member_id is not null and participant_id is null)
      or (purpose='claim_participant' and group_id is null and group_member_id is null and participant_id is not null))
);
create index invite_tokens_group on public.invite_tokens(group_id);

create table public.notification_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete restrict,
  event_id uuid references public.events(id) on delete restrict,
  group_id uuid references public.groups(id) on delete restrict,
  notification_type text not null,
  payload_version integer not null default 1,
  payload jsonb not null check (jsonb_typeof(payload)='object'),
  dedupe_key text not null unique,
  retry_key uuid not null default gen_random_uuid() unique,
  status text not null default 'pending' check (status in ('pending','sending','sent','failed','skipped')),
  attempts integer not null default 0 check (attempts>=0),
  next_attempt_at timestamptz not null default now(),
  locked_until timestamptz,
  error_code text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index notification_logs_queue on public.notification_logs(next_attempt_at) where status in ('pending','failed','sending');
create index notification_logs_user on public.notification_logs(user_id);

create table public.app_sessions (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references public.users(id) on delete restrict,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  check(expires_at > created_at)
);
create index app_sessions_user on public.app_sessions(user_id);
create table public.admin_users (
  user_id uuid primary key references public.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references public.users(id) on delete restrict,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}',
  created_at timestamptz not null default now()
);

-- Capacity is a database invariant, not merely an application-level check.
create function public.enforce_event_capacity() returns trigger
language plpgsql set search_path='' as $$
declare cap integer; event_status text; occupied integer;
begin
  select capacity,status into cap,event_status from public.events where id=new.event_id for update;
  if cap is null then raise exception 'EVENT_NOT_FOUND' using errcode='23503'; end if;
  if new.status in ('reserved','joined') then
    if event_status not in ('open','confirmed') then raise exception 'EVENT_CLOSED' using errcode='23514'; end if;
    select count(*) into occupied from public.booking_participants
      where event_id=new.event_id and status<>'cancelled' and id<>new.id;
    if occupied>=cap then raise exception 'SOLD_OUT' using errcode='23514'; end if;
  end if;
  return new;
end $$;
create trigger booking_capacity before insert or update of event_id,status on public.booking_participants
  for each row execute function public.enforce_event_capacity();

create function public.enforce_group_capacity() returns trigger
language plpgsql set search_path='' as $$
declare cap integer; group_status text;
begin
  select capacity,status into cap,group_status from public.groups where id=new.group_id for update;
  if cap is null then raise exception 'GROUP_NOT_FOUND' using errcode='23503'; end if;
  if new.seat_number>cap then raise exception 'GROUP_CAPACITY_EXCEEDED' using errcode='23514'; end if;
  if new.status in ('reserved','joined') and group_status='cancelled'
    then raise exception 'GROUP_CLOSED' using errcode='23514'; end if;
  return new;
end $$;
create trigger group_capacity before insert or update of group_id,seat_number,status on public.group_members
  for each row execute function public.enforce_group_capacity();

create function public.prevent_capacity_reduction() returns trigger
language plpgsql set search_path='' as $$
declare needed integer;
begin
  if tg_table_name='events' then
    select count(*) into needed from public.booking_participants where event_id=new.id and status<>'cancelled';
  else
    select coalesce(max(seat_number),0) into needed from public.group_members where group_id=new.id and status<>'cancelled';
  end if;
  if new.capacity<needed then raise exception 'CAPACITY_BELOW_OCCUPANCY' using errcode='23514'; end if;
  return new;
end $$;
create trigger event_capacity_reduction before update of capacity on public.events
  for each row execute function public.prevent_capacity_reduction();
create trigger group_capacity_reduction before update of capacity on public.groups
  for each row execute function public.prevent_capacity_reduction();

-- Functions invoked by triggers need no direct API execution permission.
revoke all on function public.enforce_event_capacity(), public.enforce_group_capacity(), public.prevent_capacity_reduction()
  from public,anon,authenticated;

do $$ declare t text;
begin
  foreach t in array array['games','groups','group_members','events','bookings','booking_participants',
    'payments','payment_allocations','player_game_history','invite_tokens','notification_logs',
    'app_sessions','admin_users','audit_logs'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from public,anon,authenticated',t);
    execute format('grant select,insert,update,delete on public.%I to service_role',t);
  end loop;
end $$;
revoke update,delete on public.audit_logs from service_role;
revoke all on sequence public.audit_logs_id_seq from public,anon,authenticated;
grant usage,select on sequence public.audit_logs_id_seq to service_role;

commit;
