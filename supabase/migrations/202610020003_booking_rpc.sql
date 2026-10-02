begin;

-- Server-only business operations. p_actor is the user resolved from the server session
-- (P3); it is never taken from client input. Business errors raise P0001 with a stable
-- code in the message so the API layer can map them to HTTP status codes.

create function public._sf_actor_player(p_actor uuid) returns uuid
language plpgsql set search_path='' as $$
declare pid uuid; uname text;
begin
  select display_name into uname from public.users where id=p_actor;
  if not found then raise exception 'USER_NOT_FOUND' using errcode='P0001'; end if;
  select id into pid from public.players where user_id=p_actor;
  if pid is null then
    insert into public.players(user_id,display_name)
      values (p_actor, coalesce(nullif(left(trim(uname),100),''),'LINE 玩家'))
      on conflict (user_id) do nothing returning id into pid;
    if pid is null then select id into pid from public.players where user_id=p_actor; end if;
  end if;
  return pid;
end $$;

create function public._sf_is_admin(p_actor uuid) returns boolean
language sql stable set search_path='' as $$
  select exists(select 1 from public.admin_users where user_id=p_actor)
$$;

create function public._sf_audit(p_actor uuid, p_action text, p_entity_type text, p_entity_id uuid,
  p_details jsonb default '{}') returns void
language sql set search_path='' as $$
  insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,details)
    values (p_actor,p_action,p_entity_type,p_entity_id,p_details)
$$;

-- Tokens live at most 30 days and never beyond the given limit (e.g. the planned start).
create function public._sf_token_expiry(p_expires_at timestamptz, p_limit timestamptz) returns timestamptz
language plpgsql stable set search_path='' as $$
begin
  if p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '30 days' then
    raise exception 'INVALID_EXPIRY' using errcode='P0001';
  end if;
  if p_limit is not null and p_limit<=now() then raise exception 'INVALID_EXPIRY' using errcode='P0001'; end if;
  return least(p_expires_at,coalesce(p_limit,p_expires_at));
end $$;

create function public._sf_valid_hash(p_token_hash text) returns void
language plpgsql immutable set search_path='' as $$
begin
  if coalesce(p_token_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_TOKEN' using errcode='P0001';
  end if;
end $$;

-- 開團：主揪自動坐 1 號位，其餘依人數建立空位。同一 request_id 重送回傳同一團。
create function public.create_group(p_actor uuid, p_request_id uuid, p_desired_start_at timestamptz,
  p_capacity integer, p_game_id uuid default null, p_preferences text[] default '{}',
  p_note text default '', p_visibility text default 'private')
returns jsonb language plpgsql set search_path='' as $$
declare gid uuid; pid uuid; gmin integer; gmax integer;
begin
  if p_request_id is null then raise exception 'INVALID_REQUEST' using errcode='P0001'; end if;
  select id into gid from public.groups where organizer_user_id=p_actor and request_id=p_request_id;
  if gid is not null then return jsonb_build_object('group_id',gid,'created',false); end if;

  if p_desired_start_at is null or p_desired_start_at<=now() then
    raise exception 'INVALID_START_TIME' using errcode='P0001'; end if;
  if p_capacity is null or p_capacity not between 1 and 50 then
    raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  if p_visibility is null or p_visibility not in ('public','private') then
    raise exception 'INVALID_VISIBILITY' using errcode='P0001'; end if;
  if length(coalesce(p_note,''))>2000 then raise exception 'INVALID_NOTE' using errcode='P0001'; end if;
  if p_game_id is not null then
    select min_players,max_players into gmin,gmax from public.games where id=p_game_id and active;
    if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
    if p_capacity not between gmin and gmax then raise exception 'INVALID_CAPACITY' using errcode='P0001'; end if;
  end if;

  pid := public._sf_actor_player(p_actor);
  insert into public.groups(organizer_user_id,game_id,desired_start_at,capacity,preferences,note,visibility,request_id)
    values (p_actor,p_game_id,p_desired_start_at,p_capacity,coalesce(p_preferences,'{}'),coalesce(p_note,''),
            p_visibility,p_request_id)
    on conflict (organizer_user_id,request_id) do nothing returning id into gid;
  if gid is null then
    select id into gid from public.groups where organizer_user_id=p_actor and request_id=p_request_id;
    return jsonb_build_object('group_id',gid,'created',false);
  end if;
  insert into public.group_members(group_id,seat_number,player_id,status,joined_at)
    select gid,s,case when s=1 then pid end,case when s=1 then 'joined' else 'open' end,case when s=1 then now() end
    from generate_series(1,p_capacity) s;
  perform public._sf_audit(p_actor,'group.create','group',gid,jsonb_build_object('capacity',p_capacity));
  return jsonb_build_object('group_id',gid,'created',true);
end $$;

-- 主揪產生加入連結（可多人使用，到期或解散即失效）。伺服器只傳 token 的 SHA-256。
create function public.create_group_invite(p_actor uuid, p_group_id uuid, p_token_hash text, p_expires_at timestamptz)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; tid uuid;
begin
  perform public._sf_valid_hash(p_token_hash);
  select * into g from public.groups where id=p_group_id for update;
  if not found or g.organizer_user_id<>p_actor then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status<>'recruiting' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  insert into public.invite_tokens(token_hash,purpose,group_id,created_by_user_id,expires_at)
    values (p_token_hash,'join_group',g.id,p_actor,public._sf_token_expiry(p_expires_at,g.desired_start_at))
    returning id into tid;
  perform public._sf_audit(p_actor,'invite.create','invite_token',tid,jsonb_build_object('purpose','join_group'));
  return jsonb_build_object('invite_id',tid);
end $$;

-- 主揪替朋友預留具名席位（例如「涵涵」），並產生一次性認領 token。
create function public.reserve_group_seat(p_actor uuid, p_group_id uuid, p_display_name text,
  p_token_hash text, p_expires_at timestamptz)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; seat_id uuid; seat_no integer; pid uuid; tid uuid;
begin
  perform public._sf_valid_hash(p_token_hash);
  if coalesce(length(trim(p_display_name)),0) not between 1 and 100 then
    raise exception 'INVALID_NAME' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found or g.organizer_user_id<>p_actor then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status<>'recruiting' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  select id,seat_number into seat_id,seat_no from public.group_members
    where group_id=g.id and status='open' order by seat_number limit 1;
  if seat_id is null then raise exception 'GROUP_FULL' using errcode='P0001'; end if;

  insert into public.players(display_name,created_by_user_id) values (trim(p_display_name),p_actor) returning id into pid;
  update public.group_members set player_id=pid,reserved_by_user_id=p_actor,status='reserved' where id=seat_id;
  insert into public.invite_tokens(token_hash,purpose,group_id,group_member_id,created_by_user_id,expires_at)
    values (p_token_hash,'claim_group_seat',g.id,seat_id,p_actor,public._sf_token_expiry(p_expires_at,g.desired_start_at))
    returning id into tid;
  perform public._sf_audit(p_actor,'group.reserve_seat','group_member',seat_id,jsonb_build_object('seat',seat_no));
  return jsonb_build_object('group_member_id',seat_id,'seat_number',seat_no,'player_id',pid,'invite_id',tid);
end $$;

-- 直接加入：公開團憑 group id；私人團需有效的 join_group token。重複加入回傳原席位。
create function public.join_group(p_actor uuid, p_group_id uuid, p_token_hash text default null)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; pid uuid; seat_id uuid; seat_no integer;
begin
  select * into g from public.groups where id=p_group_id for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.visibility='private' and g.organizer_user_id<>p_actor and not exists(
      select 1 from public.invite_tokens where token_hash=p_token_hash and purpose='join_group'
        and group_id=g.id and revoked_at is null and expires_at>now()) then
    raise exception 'INVITE_INVALID' using errcode='P0001';
  end if;
  pid := public._sf_actor_player(p_actor);
  select seat_number into seat_no from public.group_members
    where group_id=g.id and player_id=pid and status in ('reserved','joined');
  if seat_no is not null then
    return jsonb_build_object('group_id',g.id,'seat_number',seat_no,'joined',false);
  end if;
  if g.status<>'recruiting' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  select id,seat_number into seat_id,seat_no from public.group_members
    where group_id=g.id and status='open' order by seat_number limit 1;
  if seat_id is null then raise exception 'GROUP_FULL' using errcode='P0001'; end if;
  update public.group_members set player_id=pid,status='joined',joined_at=now(),reserved_by_user_id=null
    where id=seat_id;
  perform public._sf_audit(p_actor,'group.join','group',g.id,jsonb_build_object('seat',seat_no));
  return jsonb_build_object('group_id',g.id,'seat_number',seat_no,'joined',true);
end $$;

-- 認領：join_group token 等同加入；claim token 只能被一位 LINE 使用者認領一次。
-- 認領者尚無玩家檔時，直接把預留的 placeholder 綁到他身上（保留履歷）；已有玩家檔則換成他。
create function public.claim_invite(p_actor uuid, p_token_hash text)
returns jsonb language plpgsql set search_path='' as $$
declare t public.invite_tokens%rowtype; gstatus text; target uuid; target_user uuid; pid uuid;
  seat_status text; part_status text; part_event uuid;
begin
  perform public._sf_valid_hash(p_token_hash);
  select * into t from public.invite_tokens where token_hash=p_token_hash;
  if not found then raise exception 'INVITE_INVALID' using errcode='P0001'; end if;
  if t.purpose='join_group' then return public.join_group(p_actor,t.group_id,p_token_hash); end if;

  -- Lock order matches the other RPCs: group/event first, then the token and seat rows.
  if t.purpose='claim_group_seat' then
    select status into gstatus from public.groups where id=t.group_id for update;
  else
    select event_id into part_event from public.booking_participants where id=t.participant_id;
    perform 1 from public.events where id=part_event for update;
  end if;
  select * into t from public.invite_tokens where id=t.id for update;
  if t.used_at is not null then
    if t.claimed_by_user_id=p_actor then return jsonb_build_object('invite_id',t.id,'claimed',false); end if;
    raise exception 'INVITE_USED' using errcode='P0001';
  end if;
  if t.revoked_at is not null or t.expires_at<=now() then raise exception 'INVITE_INVALID' using errcode='P0001'; end if;

  if t.purpose='claim_group_seat' then
    if gstatus='cancelled' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
    select player_id,status into target,seat_status from public.group_members where id=t.group_member_id for update;
    if seat_status<>'reserved' then raise exception 'INVITE_INVALID' using errcode='P0001'; end if;
  else
    select player_id,status into target,part_status from public.booking_participants where id=t.participant_id for update;
    if part_status not in ('reserved','joined') then raise exception 'INVITE_INVALID' using errcode='P0001'; end if;
  end if;

  perform 1 from public.users where id=p_actor;
  if not found then raise exception 'USER_NOT_FOUND' using errcode='P0001'; end if;
  select user_id into target_user from public.players where id=target for update;
  if target_user is not null and target_user<>p_actor then raise exception 'INVITE_INVALID' using errcode='P0001'; end if;
  select id into pid from public.players where user_id=p_actor;
  if pid is null then
    update public.players set user_id=p_actor where id=target;
    pid := target;
  elsif pid<>target then
    begin
      if t.purpose='claim_group_seat' then
        update public.group_members set player_id=pid where id=t.group_member_id;
        update public.booking_participants bp set player_id=pid from public.events e
          where e.group_id=t.group_id and bp.event_id=e.id and bp.player_id=target and bp.status<>'cancelled';
      else
        update public.booking_participants set player_id=pid where id=t.participant_id;
      end if;
    exception when unique_violation then
      raise exception 'ALREADY_MEMBER' using errcode='P0001';
    end;
  end if;

  if t.purpose='claim_group_seat' then
    update public.group_members set status='joined',joined_at=now() where id=t.group_member_id;
    update public.booking_participants bp set status='joined' from public.events e
      where e.group_id=t.group_id and bp.event_id=e.id and bp.player_id=pid and bp.status='reserved';
  else
    update public.booking_participants set status='joined' where id=t.participant_id and status='reserved';
  end if;
  update public.invite_tokens set used_at=now(),claimed_by_user_id=p_actor where id=t.id;
  perform public._sf_audit(p_actor,'invite.claim','invite_token',t.id,jsonb_build_object('purpose',t.purpose));
  return jsonb_build_object('invite_id',t.id,'claimed',true,'player_id',pid);
end $$;

-- 退出揪團／主揪移除預留席位：席位回到空位，該席的未用 token 失效。主揪不能退出自己的團。
create function public.leave_group_seat(p_actor uuid, p_group_member_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare gid uuid; g public.groups%rowtype; seat public.group_members%rowtype; seat_user uuid;
begin
  select group_id into gid from public.group_members where id=p_group_member_id;
  if gid is null then raise exception 'SEAT_NOT_FOUND' using errcode='P0001'; end if;
  select * into g from public.groups where id=gid for update;
  select * into seat from public.group_members where id=p_group_member_id for update;
  select user_id into seat_user from public.players where id=seat.player_id;
  if g.organizer_user_id<>p_actor and seat_user is distinct from p_actor then
    raise exception 'SEAT_NOT_FOUND' using errcode='P0001'; end if;
  if seat_user=g.organizer_user_id then raise exception 'ORGANIZER_CANNOT_LEAVE' using errcode='P0001'; end if;
  if seat.status='open' then return jsonb_build_object('released',false); end if;
  if g.status not in ('recruiting','pending_confirmation') then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  update public.group_members set status='open',player_id=null,reserved_by_user_id=null,joined_at=null
    where id=seat.id;
  update public.invite_tokens set revoked_at=now() where group_member_id=seat.id and used_at is null and revoked_at is null;
  perform public._sf_audit(p_actor,'group.leave_seat','group_member',seat.id,jsonb_build_object('seat',seat.seat_number));
  return jsonb_build_object('released',true,'seat_number',seat.seat_number);
end $$;

-- 解散揪團：所有席位與邀請立即失效。已成場的團需改由店家取消場次。
create function public.cancel_group(p_actor uuid, p_group_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype;
begin
  select * into g from public.groups where id=p_group_id for update;
  if not found or (g.organizer_user_id<>p_actor and not public._sf_is_admin(p_actor)) then
    raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='cancelled' then return jsonb_build_object('cancelled',false); end if;
  if g.status='confirmed' then raise exception 'GROUP_CONFIRMED' using errcode='P0001'; end if;
  update public.groups set status='cancelled' where id=g.id;
  update public.group_members set status='cancelled' where group_id=g.id and status<>'cancelled';
  update public.invite_tokens set revoked_at=now() where group_id=g.id and used_at is null and revoked_at is null;
  perform public._sf_audit(p_actor,'group.cancel','group',g.id);
  return jsonb_build_object('cancelled',true);
end $$;

-- 店家確認成場：建立 event，主揪為 booker，團內已加入／預留的玩家成為 participants。
create function public.admin_confirm_group_event(p_actor uuid, p_group_id uuid, p_starts_at timestamptz,
  p_venue text, p_dm_name text, p_game_id uuid default null, p_price_cents integer default null)
returns jsonb language plpgsql set search_path='' as $$
declare g public.groups%rowtype; gm public.games%rowtype; ev uuid; bk uuid; n integer;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into g from public.groups where id=p_group_id for update;
  if not found then raise exception 'GROUP_NOT_FOUND' using errcode='P0001'; end if;
  if g.status='confirmed' then
    select id into ev from public.events where group_id=g.id;
    return jsonb_build_object('event_id',ev,'created',false);
  end if;
  if g.status='cancelled' then raise exception 'GROUP_CLOSED' using errcode='P0001'; end if;
  select * into gm from public.games where id=coalesce(p_game_id,g.game_id) and active;
  if not found then raise exception 'GAME_NOT_FOUND' using errcode='P0001'; end if;
  if p_starts_at is null or p_starts_at<=now() then raise exception 'INVALID_START_TIME' using errcode='P0001'; end if;
  if p_price_cents is not null and p_price_cents<0 then raise exception 'INVALID_PRICE' using errcode='P0001'; end if;

  insert into public.events(group_id,game_id,starts_at,capacity,price_cents,venue,dm_name,visibility)
    values (g.id,gm.id,p_starts_at,g.capacity,coalesce(p_price_cents,gm.price_cents),p_venue,p_dm_name,g.visibility)
    returning id into ev;
  insert into public.bookings(event_id,booker_user_id,request_id) values (ev,g.organizer_user_id,gen_random_uuid())
    returning id into bk;
  insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
    select bk,ev,player_id,coalesce(p_price_cents,gm.price_cents),status from public.group_members
    where group_id=g.id and status in ('reserved','joined') order by seat_number;
  get diagnostics n = row_count;
  update public.groups set status='confirmed',game_id=gm.id where id=g.id;
  perform public._sf_audit(p_actor,'group.confirm_event','event',ev,jsonb_build_object('group_id',g.id,'participants',n));
  return jsonb_build_object('event_id',ev,'booking_id',bk,'participants',n,'created',true);
end $$;

-- 多人預約（含代報）。p_participants 每一項為 {"self":true}、{"player_id":...}（本人或自己建立且未綁定的
-- 玩家）或 {"display_name":"..."}（新建 placeholder）。先鎖 event 列，再新增，任何一席失敗整筆回滾。
create function public.create_booking(p_actor uuid, p_event_id uuid, p_request_id uuid, p_participants jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare ev public.events%rowtype; bk uuid; spec jsonb; pid uuid; puser uuid; pname text; part uuid;
  n integer; occupied integer; parts jsonb := '[]';
begin
  if p_request_id is null then raise exception 'INVALID_REQUEST' using errcode='P0001'; end if;
  select id into bk from public.bookings where booker_user_id=p_actor and request_id=p_request_id;
  if bk is not null then
    return jsonb_build_object('booking_id',bk,'created',false);
  end if;
  if jsonb_typeof(p_participants) is distinct from 'array' then
    raise exception 'INVALID_PARTICIPANTS' using errcode='P0001'; end if;
  n := jsonb_array_length(p_participants);
  if n not between 1 and 50 then raise exception 'INVALID_PARTICIPANTS' using errcode='P0001'; end if;
  perform 1 from public.users where id=p_actor;
  if not found then raise exception 'USER_NOT_FOUND' using errcode='P0001'; end if;

  select * into ev from public.events where id=p_event_id for update;
  if not found or (ev.visibility='private' and not public._sf_is_admin(p_actor)
      and not exists(select 1 from public.groups where id=ev.group_id and organizer_user_id=p_actor)) then
    raise exception 'EVENT_NOT_FOUND' using errcode='P0001'; end if;
  -- A concurrent retry of the same request may have committed while we waited for the lock.
  select id into bk from public.bookings where booker_user_id=p_actor and request_id=p_request_id;
  if bk is not null then return jsonb_build_object('booking_id',bk,'created',false); end if;
  if ev.status not in ('open','confirmed') or ev.starts_at<=now() then
    raise exception 'EVENT_CLOSED' using errcode='P0001'; end if;
  select count(*) into occupied from public.booking_participants where event_id=ev.id and status<>'cancelled';
  if occupied+n>ev.capacity then raise exception 'SOLD_OUT' using errcode='P0001'; end if;

  insert into public.bookings(event_id,booker_user_id,request_id) values (ev.id,p_actor,p_request_id) returning id into bk;
  for spec in select value from jsonb_array_elements(p_participants) loop
    if jsonb_typeof(spec)<>'object' then raise exception 'INVALID_PARTICIPANTS' using errcode='P0001'; end if;
    if spec->'self'='true'::jsonb then
      pid := public._sf_actor_player(p_actor);
    elsif spec ? 'player_id' then
      select id,user_id into pid,puser from public.players
        where id=(spec->>'player_id')::uuid and (user_id=p_actor or (user_id is null and created_by_user_id=p_actor));
      if pid is null then raise exception 'PLAYER_NOT_ALLOWED' using errcode='P0001'; end if;
    elsif spec ? 'display_name' then
      pname := trim(spec->>'display_name');
      if coalesce(length(pname),0) not between 1 and 100 then raise exception 'INVALID_NAME' using errcode='P0001'; end if;
      insert into public.players(display_name,created_by_user_id) values (pname,p_actor) returning id into pid;
    else
      raise exception 'INVALID_PARTICIPANTS' using errcode='P0001';
    end if;
    select user_id into puser from public.players where id=pid;
    begin
      insert into public.booking_participants(booking_id,event_id,player_id,price_cents,status)
        values (bk,ev.id,pid,ev.price_cents,case when puser=p_actor then 'joined' else 'reserved' end)
        returning id into part;
    exception when unique_violation then
      raise exception 'ALREADY_BOOKED' using errcode='P0001';
    end;
    parts := parts || jsonb_build_object('participant_id',part,'player_id',pid);
  end loop;
  perform public._sf_audit(p_actor,'booking.create','booking',bk,jsonb_build_object('event_id',ev.id,'participants',n));
  return jsonb_build_object('booking_id',bk,'created',true,'participants',parts);
end $$;

-- 缺人場次「加入」：等同只替自己預約一席。
create function public.join_event(p_actor uuid, p_event_id uuid, p_request_id uuid)
returns jsonb language sql set search_path='' as $$
  select public.create_booking(p_actor,p_event_id,p_request_id,'[{"self":true}]'::jsonb)
$$;

-- 代報的朋友之後可用一次性 token 把席位綁回自己的 LINE。
create function public.create_participant_claim(p_actor uuid, p_participant_id uuid, p_token_hash text,
  p_expires_at timestamptz)
returns jsonb language plpgsql set search_path='' as $$
declare booker uuid; puser uuid; pstatus text; starts timestamptz; tid uuid;
begin
  perform public._sf_valid_hash(p_token_hash);
  select b.booker_user_id,pl.user_id,bp.status,e.starts_at into booker,puser,pstatus,starts
    from public.booking_participants bp join public.bookings b on b.id=bp.booking_id
    join public.players pl on pl.id=bp.player_id join public.events e on e.id=bp.event_id
    where bp.id=p_participant_id;
  if booker is distinct from p_actor then raise exception 'PARTICIPANT_NOT_FOUND' using errcode='P0001'; end if;
  if puser is not null or pstatus<>'reserved' then raise exception 'ALREADY_CLAIMED' using errcode='P0001'; end if;
  insert into public.invite_tokens(token_hash,purpose,participant_id,created_by_user_id,expires_at)
    values (p_token_hash,'claim_participant',p_participant_id,p_actor,public._sf_token_expiry(p_expires_at,starts))
    returning id into tid;
  perform public._sf_audit(p_actor,'invite.create','invite_token',tid,jsonb_build_object('purpose','claim_participant'));
  return jsonb_build_object('invite_id',tid);
end $$;

-- 單人取消：booker、本人或管理員可取消；釋出席位與未付款的分攤，已付款者回報需退款。
create function public.cancel_participant(p_actor uuid, p_participant_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare evid uuid; starts timestamptz; bp public.booking_participants%rowtype; booker uuid; puser uuid; paid integer;
begin
  select event_id into evid from public.booking_participants where id=p_participant_id;
  if evid is null then raise exception 'PARTICIPANT_NOT_FOUND' using errcode='P0001'; end if;
  select starts_at into starts from public.events where id=evid for update;
  select * into bp from public.booking_participants where id=p_participant_id for update;
  select booker_user_id into booker from public.bookings where id=bp.booking_id;
  select user_id into puser from public.players where id=bp.player_id;
  if booker<>p_actor and puser is distinct from p_actor and not public._sf_is_admin(p_actor) then
    raise exception 'PARTICIPANT_NOT_FOUND' using errcode='P0001'; end if;
  if bp.status='cancelled' then return jsonb_build_object('cancelled',false); end if;
  if bp.status not in ('reserved','joined') then raise exception 'CANNOT_CANCEL' using errcode='P0001'; end if;
  if starts<=now() then raise exception 'EVENT_STARTED' using errcode='P0001'; end if;

  update public.booking_participants set status='cancelled',cancelled_at=now() where id=bp.id;
  update public.payment_allocations pa set active=false from public.payments p
    where pa.payment_id=p.id and pa.participant_id=bp.id and pa.active
      and p.status in ('unpaid','pending','failed','cancelled');
  select count(*) into paid from public.payment_allocations pa join public.payments p on p.id=pa.payment_id
    where pa.participant_id=bp.id and pa.active;
  update public.invite_tokens set revoked_at=now() where participant_id=bp.id and used_at is null and revoked_at is null;
  update public.bookings set status='cancelled' where id=bp.booking_id and not exists(
    select 1 from public.booking_participants where booking_id=bp.booking_id and status<>'cancelled');
  perform public._sf_audit(p_actor,'participant.cancel','booking_participant',bp.id,
    jsonb_build_object('event_id',evid,'refund_required',paid>0));
  return jsonb_build_object('cancelled',true,'refund_required',paid>0);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_actor_player','_sf_is_admin','_sf_audit','_sf_token_expiry',
      '_sf_valid_hash','create_group','create_group_invite','reserve_group_seat','join_group','claim_invite',
      'leave_group_seat','cancel_group','admin_confirm_group_event','create_booking','join_event',
      'create_participant_claim','cancel_participant') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
