begin;

alter table public.games add column review_key text;
create or replace function public._sf_apply_catalog(p_actor uuid, p_games jsonb, p_source text)
returns jsonb language plpgsql set search_path='' as $$
declare g jsonb; n integer := 0; off integer;
begin
  if jsonb_typeof(p_games) is distinct from 'array' or jsonb_array_length(p_games) not between 1 and 500 then
    raise exception 'INVALID_CATALOG' using errcode='P0001'; end if;
  for g in select value from jsonb_array_elements(p_games) loop
    if coalesce(g->>'slug','') !~ '^[a-z0-9][a-z0-9-]*$' or coalesce(length(trim(g->>'title')),0) not between 1 and 200
      or (g->>'min_players')::int not between 1 and 50 or (g->>'max_players')::int not between (g->>'min_players')::int and 50
      or (g->>'duration_minutes')::int not between 30 and 720 then
      raise exception 'INVALID_CATALOG' using errcode='P0001';
    end if;
    insert into public.games as x(slug,title,min_players,max_players,duration_minutes,genres,difficulty,
        players_label,image_url,source_url,active,synced_at,review_key)
      values (g->>'slug',trim(g->>'title'),(g->>'min_players')::int,(g->>'max_players')::int,
        (g->>'duration_minutes')::int,
        coalesce((select array_agg(left(t,40)) from jsonb_array_elements_text(g->'genres') t),'{}'),
        left(g->>'difficulty',20),left(g->>'players_label',100),
        nullif(g->>'image_url',''),nullif(g->>'source_url',''),true,now(),coalesce(nullif(g->>'review_key',''),trim(g->>'title')))
      on conflict (slug) do update set title=excluded.title,min_players=excluded.min_players,
        max_players=excluded.max_players,duration_minutes=excluded.duration_minutes,genres=excluded.genres,
        difficulty=excluded.difficulty,players_label=excluded.players_label,image_url=excluded.image_url,
        review_key=excluded.review_key,source_url=excluded.source_url,active=true,synced_at=excluded.synced_at;
    n := n+1;
  end loop;
  update public.games set active=false
    where active and synced_at is not null and slug not in (select value->>'slug' from jsonb_array_elements(p_games));
  get diagnostics off = row_count;
  perform public._sf_audit(p_actor,'games.sync','game',null,
    jsonb_build_object('synced',n,'deactivated',off,'source',left(p_source,80)));
  return jsonb_build_object('synced',n,'deactivated',off);
end $$;


create table public.line_record_accounts (
  user_id uuid primary key references public.users(id) on delete restrict,
  record_name text not null unique check(char_length(record_name) between 1 and 60)
);
alter table public.line_record_accounts enable row level security;
revoke all on public.line_record_accounts from public,anon,authenticated;
grant select,insert,update,delete on public.line_record_accounts to service_role;

create function public.my_record_account(p_actor uuid) returns text
language sql stable set search_path='' as $$
  select record_name from public.line_record_accounts where user_id=p_actor
$$;

create or replace function public.bound_record_names() returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(record_name order by record_name),'[]') from (
    select record_name from public.player_bindings where status='approved'
    union select record_name from public.line_record_accounts
  ) n
$$;

create function public._sf_guard_record_binding() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.status='approved' and exists(select 1 from public.line_record_accounts
    where record_name=new.record_name and user_id<>new.user_id) then
    raise exception 'NAME_TAKEN' using errcode='P0001';
  end if;
  if new.status='approved' and exists(select 1 from public.line_record_accounts
    where user_id=new.user_id and record_name<>new.record_name) then
    raise exception 'IDENTITY_MERGE_REQUIRED' using errcode='P0001';
  end if;
  return new;
end $$;
create trigger guard_record_binding before insert or update on public.player_bindings
  for each row execute function public._sf_guard_record_binding();
revoke all on function public._sf_guard_record_binding() from public,anon,authenticated;
grant execute on function public._sf_guard_record_binding() to service_role;
create function public.save_record_account(p_actor uuid,p_name text) returns void
language plpgsql set search_path='' as $$
begin
  insert into public.line_record_accounts(user_id,record_name) values(p_actor,p_name)
    on conflict(user_id) do update set record_name=excluded.record_name;
end $$;

-- Attendance is the authority for event reviews; no name/date/game from the client.
create function public.my_manual_review_context(p_actor uuid,p_game_id uuid,p_date date)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb;
begin
  if p_date is null or p_date<'1900-01-01'::date or p_date>(now() at time zone 'Asia/Taipei')::date then
    raise exception 'INVALID_RECORD_DATE' using errcode='P0001';
  end if;
  select jsonb_build_object('title',gm.title,'review_key',coalesce(gm.review_key,gm.title),
    'date',to_char(p_date,'YYYY-MM-DD'),'record_name',case when b.status='approved' then b.record_name else null end,
    'display_name',u.display_name) into result
    from public.games gm cross join public.users u left join public.player_bindings b on b.user_id=u.id
    where gm.id=p_game_id and gm.active and u.id=p_actor;
  if result is null then raise exception 'REVIEW_NOT_FOUND' using errcode='P0001'; end if;
  return result;
end $$;
revoke all on function public.my_manual_review_context(uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.my_manual_review_context(uuid,uuid,date) to service_role;

create function public.my_review_context(p_actor uuid, p_event_id uuid)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb;
begin
  select jsonb_build_object('event_id',e.id,'game_id',gm.id,'title',gm.title,'review_key',coalesce(gm.review_key,gm.title),
    'date',to_char(h.played_at at time zone 'Asia/Taipei','YYYY-MM-DD'),
    'record_name',case when b.status='approved' then b.record_name else null end,
    'display_name',u.display_name)
  into result
  from public.player_game_history h
  join public.players p on p.id=h.player_id and p.user_id=p_actor
  join public.users u on u.id=p.user_id
  join public.events e on e.id=h.event_id
  join public.games gm on gm.id=h.game_id
  left join public.player_bindings b on b.user_id=p_actor
  where h.event_id=p_event_id;
  if result is null then raise exception 'REVIEW_NOT_FOUND' using errcode='P0001'; end if;
  return result;
end $$;

create or replace function public.list_my_history(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('event_id',e.id,'game_id',gm.id,'title',gm.title,'review_key',coalesce(gm.review_key,gm.title),'image_url',gm.image_url,
      'played_at',h.played_at,'venue',e.venue,'dm_name',e.dm_name) order by h.played_at desc),'[]')
  from public.player_game_history h
  join public.players p on p.id=h.player_id and p.user_id=p_actor
  join public.games gm on gm.id=h.game_id
  join public.events e on e.id=h.event_id
$$;

create function public._sf_review_reminder() returns trigger
language plpgsql set search_path='' as $$
declare recipient uuid; facts jsonb;
begin
  select p.user_id into recipient from public.players p join public.users u on u.id=p.user_id
    where p.id=new.player_id and u.line_user_id not like 'Ufeedfacefeedface%';
  if recipient is null then return new; end if;
  select jsonb_build_object('kind','review_reminder','event_id',new.event_id,'game_title',title,
    'played_date',to_char(new.played_at at time zone 'Asia/Taipei','YYYY-MM-DD')) into facts
    from public.games where id=new.game_id;
  insert into public.notification_logs(user_id,event_id,notification_type,payload,dedupe_key)
    values(recipient,new.event_id,'review_reminder',facts,'review:'||new.event_id||':'||recipient)
    on conflict(dedupe_key) do nothing;
  return new;
end $$;
create trigger review_reminder after insert on public.player_game_history
  for each row execute function public._sf_review_reminder();

revoke all on function public.my_review_context(uuid,uuid),public._sf_review_reminder(),public.my_record_account(uuid),public.save_record_account(uuid,text) from public,anon,authenticated;
grant execute on function public.my_review_context(uuid,uuid),public._sf_review_reminder(),public.my_record_account(uuid),public.save_record_account(uuid,text) to service_role;

commit;
