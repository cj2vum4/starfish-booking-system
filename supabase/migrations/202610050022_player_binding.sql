begin;

-- 老玩家綁定: a LINE account claims the 歸戶名 it used on the website's 玩本記錄 (points live
-- in that Google Sheet). The store approves each claim once; approval grants the one-time
-- 回歸禮 through the website's Apps Script and switches the player to the member Rich Menu.

create table public.player_bindings (
  user_id uuid primary key references public.users(id) on delete restrict,
  record_name text not null check (char_length(record_name) between 1 and 60),
  note text not null default '' check (char_length(note) <= 200),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  -- none: not attempted yet; granted / already: in the ledger; ineligible: name first recorded
  -- after the cutoff, so no bonus (the binding itself still stands).
  bonus_status text not null default 'none' check (bonus_status in ('none','granted','already','ineligible')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.users(id) on delete restrict
);
-- One LINE account per 歸戶名.
create unique index player_bindings_one_owner on public.player_bindings(record_name) where status='approved';
alter table public.player_bindings enable row level security;
revoke all on public.player_bindings from public,anon,authenticated;

create function public._sf_binding_row(b public.player_bindings) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('user_id',b.user_id,'record_name',b.record_name,'note',b.note,'status',b.status,
    'bonus_status',b.bonus_status,'requested_at',b.requested_at,'decided_at',b.decided_at,
    'display_name',(select display_name from public.users where id=b.user_id))
$$;

create function public.my_binding(p_actor uuid) returns jsonb
language sql stable set search_path='' as $$
  select public._sf_binding_row(b) from public.player_bindings b where b.user_id=p_actor
$$;

-- Approved names, so the picker can mark names that already belong to someone.
create function public.bound_record_names() returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(record_name order by record_name),'[]') from public.player_bindings where status='approved'
$$;

create function public.request_binding(p_actor uuid, p_name text, p_note text) returns jsonb
language plpgsql set search_path='' as $$
declare v_name text := btrim(coalesce(p_name,'')); v_note text := btrim(coalesce(p_note,'')); cur public.player_bindings; b public.player_bindings;
begin
  if char_length(v_name) not between 1 and 60 then raise exception 'INVALID_NAME'; end if;
  if char_length(v_note) > 200 then raise exception 'INVALID_NOTE'; end if;
  select * into cur from public.player_bindings where user_id=p_actor for update;
  if cur.status='approved' then raise exception 'ALREADY_BOUND'; end if;
  if exists(select 1 from public.player_bindings where record_name=v_name and status='approved') then
    raise exception 'NAME_TAKEN';
  end if;
  insert into public.player_bindings(user_id,record_name,note) values (p_actor,v_name,v_note)
  on conflict (user_id) do update set record_name=excluded.record_name,note=excluded.note,status='pending',
    requested_at=now(),decided_at=null,decided_by=null
  returning * into b;
  -- Tell the store a claim is waiting (once per request).
  insert into public.notification_logs(user_id,notification_type,payload,dedupe_key)
    select a.user_id,'binding_requested',jsonb_build_object('kind','binding_requested','record_name',v_name,
      'display_name',(select display_name from public.users where id=p_actor)),
      'binding_requested:'||p_actor||':'||extract(epoch from b.requested_at)::bigint||':'||a.user_id
    from public.admin_users a
    where (select line_user_id from public.users where id=p_actor) not like 'Ufeedfacefeedface%'
  on conflict (dedupe_key) do nothing;
  insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,details)
    values (p_actor,'request_binding','user',p_actor,jsonb_build_object('record_name',v_name));
  return public._sf_binding_row(b);
end $$;

create function public.admin_list_bindings(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN'; end if;
  return (select coalesce(jsonb_agg(public._sf_binding_row(b) order by (b.status<>'pending'), b.requested_at desc),'[]')
    from public.player_bindings b where b.status='pending' or b.decided_at>now()-interval '30 days');
end $$;

create function public.admin_decide_binding(p_actor uuid, p_user_id uuid, p_approve boolean) returns jsonb
language plpgsql set search_path='' as $$
declare b public.player_bindings;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN'; end if;
  select * into b from public.player_bindings where user_id=p_user_id for update;
  if not found then raise exception 'BINDING_NOT_FOUND'; end if;
  if b.status<>'pending' then raise exception 'BINDING_DECIDED'; end if;
  if p_approve and exists(select 1 from public.player_bindings where record_name=b.record_name and status='approved') then
    raise exception 'NAME_TAKEN';
  end if;
  update public.player_bindings set status=case when p_approve then 'approved' else 'rejected' end,
    decided_at=now(),decided_by=p_actor where user_id=p_user_id returning * into b;
  insert into public.notification_logs(user_id,notification_type,payload,dedupe_key)
    values (p_user_id, case when p_approve then 'binding_approved' else 'binding_rejected' end,
      jsonb_build_object('kind',case when p_approve then 'binding_approved' else 'binding_rejected' end,'record_name',b.record_name),
      'binding_decided:'||p_user_id||':'||extract(epoch from b.decided_at)::bigint)
  on conflict (dedupe_key) do nothing;
  insert into public.audit_logs(actor_user_id,action,entity_type,entity_id,details)
    values (p_actor,case when p_approve then 'approve_binding' else 'reject_binding' end,'user',p_user_id,
      jsonb_build_object('record_name',b.record_name));
  return public._sf_binding_row(b);
end $$;

-- Result of the Apps Script call for the 回歸禮; only an approved binding is updated.
create function public.mark_binding_bonus(p_user_id uuid, p_status text) returns jsonb
language plpgsql set search_path='' as $$
declare b public.player_bindings;
begin
  if p_status not in ('granted','already','ineligible') then raise exception 'INVALID_BONUS_STATUS'; end if;
  update public.player_bindings set bonus_status=p_status
    where user_id=p_user_id and status='approved' returning * into b;
  if not found then raise exception 'BINDING_NOT_FOUND'; end if;
  return public._sf_binding_row(b);
end $$;

-- The member Rich Menu also goes to approved returning players.
create or replace function public.member_menu_line_ids()
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(distinct x.line_user_id),'[]') from (
    select u.line_user_id from public.player_game_history h
      join public.players p on p.id=h.player_id join public.users u on u.id=p.user_id
    union
    select u.line_user_id from public.player_bindings b join public.users u on u.id=b.user_id where b.status='approved'
  ) x where x.line_user_id not like 'Ufeedfacefeedface%'
$$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_binding_row','my_binding','bound_record_names','request_binding',
      'admin_list_bindings','admin_decide_binding','mark_binding_bonus','member_menu_line_ids') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
