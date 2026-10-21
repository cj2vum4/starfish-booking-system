begin;

-- 角色問卷依場次配對角色（2026-10-21 店家要求）。
-- 場次＝同一本劇本＋玩家在問卷填的遊玩日期；某場的份數到劇本人數（games.max_players）就通知店家，
-- 店家在 LIFF 看配對建議（規則在 api 的 ROLE_MATCH_RULES）並一次套用到每份的「分配的角色」。

-- 遊玩日期：標題含「日期」的第一題，認得 2026-10-25、2026/10/25、2026年10月25日；讀不懂就是 null（不分場次）。
create function public._sf_survey_play_date(p_fields jsonb)
returns date language plpgsql immutable set search_path='' as $$
declare v text; m text[];
begin
  if jsonb_typeof(p_fields) is distinct from 'array' then return null; end if;
  select e.f->>'value' into v from jsonb_array_elements(p_fields) with ordinality as e(f,n)
    where jsonb_typeof(e.f)='object' and e.f->>'label' like '%日期%' and coalesce(e.f->>'value','')<>''
    order by e.n limit 1;
  m := regexp_match(coalesce(v,''), '(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})');
  if m is null then return null; end if;
  return make_date(m[1]::integer, m[2]::integer, m[3]::integer);
exception when others then return null;  -- 2026-02-31 之類
end $$;

alter table public.role_survey_responses add column play_date date;
update public.role_survey_responses set play_date=public._sf_survey_play_date(fields) where true;
create index role_survey_responses_session on public.role_survey_responses(script, play_date) where play_date is not null;

create function public._sf_role_survey_play_date() returns trigger
language plpgsql set search_path='' as $$
begin
  new.play_date := public._sf_survey_play_date(new.fields);
  return new;
end $$;
create trigger role_survey_play_date before insert or update of fields on public.role_survey_responses
  for each row execute function public._sf_role_survey_play_date();

-- 網站送來的一份讓某個今天以後的場次到齊（份數 ≥ 劇本人數）：通知每位店家，同一場只通知一次。
-- 匯入舊試算表的列不通知（多半是過去的場次）。
create function public._sf_role_survey_complete() returns trigger
language plpgsql set search_path='' as $$
declare need integer; n integer;
begin
  if new.source<>'web' or new.play_date is null or new.play_date<(now() at time zone 'Asia/Taipei')::date then return null; end if;
  select g.max_players into need from public.games g where g.review_key=new.script order by g.active desc limit 1;
  if need is null then return null; end if;
  select count(*) into n from public.role_survey_responses where script=new.script and play_date=new.play_date;
  if n<need then return null; end if;
  insert into public.notification_logs(user_id,notification_type,payload,dedupe_key)
    select a.user_id,'role_survey_complete',jsonb_build_object('kind','role_survey_complete','script',new.script,
        'play_date',new.play_date,'count',n,'players',need),
      'role_survey_complete:'||new.script||':'||new.play_date||':'||a.user_id
    from public.admin_users a
  on conflict (dedupe_key) do nothing;
  return null;
end $$;
create trigger role_survey_complete after insert on public.role_survey_responses
  for each row execute function public._sf_role_survey_complete();

create or replace function public._sf_survey_row(r public.role_survey_responses)
returns jsonb language sql immutable set search_path='' as $$
  select jsonb_build_object('id',r.id,'script',r.script,'fields',r.fields,'submitted_at',r.submitted_at,'source',r.source,
    'assigned_role',r.assigned_role,'store_note',r.store_note,'updated_at',r.updated_at,'play_date',r.play_date)
$$;

-- 店家：某本問卷的場次（遊玩日期 30 天前到以後），每場幾份、幾份還沒分配；players＝劇本人數。
create function public.admin_role_survey_sessions(p_actor uuid, p_script text)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return jsonb_build_object(
    'players',(select g.max_players from public.games g where g.review_key=p_script order by g.active desc limit 1),
    'sessions',coalesce((select jsonb_agg(jsonb_build_object('play_date',s.play_date,'total',s.total,'unassigned',s.unassigned)
        order by s.play_date desc) from (
      select play_date, count(*) as total, count(*) filter (where assigned_role='') as unassigned
      from public.role_survey_responses
      where script=p_script and play_date>=(now() at time zone 'Asia/Taipei')::date-30
      group by play_date order by play_date desc limit 60) s),'[]'));
end $$;

-- 店家：要配對的回覆——某場次的全部（p_play_date），或店家勾選的（p_ids）；最多 30 份，先填的在前。
create function public.admin_role_survey_pick(p_actor uuid, p_script text, p_play_date date default null, p_ids uuid[] default null)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if (p_play_date is null)=(p_ids is null) or cardinality(p_ids)>30 then raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  return coalesce((select jsonb_agg(public._sf_survey_row(x.r) order by (x.r).submitted_at, (x.r).id) from (
    select r from public.role_survey_responses r
    where r.script=p_script and (case when p_ids is null then r.play_date=p_play_date else r.id=any(p_ids) end)
    order by r.submitted_at, r.id limit 30) x),'[]');
end $$;

-- 店家：一次套用配對（[{id, role}]，最多 30 份；備註不動）。任何一份找不到就整批不套用。
create function public.admin_assign_role_surveys(p_actor uuid, p_assignments jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare a jsonb; rid uuid; v_role text; n integer := 0;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if jsonb_typeof(p_assignments) is distinct from 'array' or jsonb_array_length(p_assignments) not between 1 and 30 then
    raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  for a in select value from jsonb_array_elements(p_assignments) loop
    if coalesce(a->>'id','') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
    rid := (a->>'id')::uuid;
    v_role := btrim(coalesce(a->>'role',''));
    if char_length(v_role)>100 then raise exception 'INVALID_NOTE' using errcode='P0001'; end if;
    update public.role_survey_responses set assigned_role=v_role, updated_at=now() where id=rid;
    if not found then raise exception 'SURVEY_NOT_FOUND' using errcode='P0001'; end if;
    n := n+1;
  end loop;
  perform public._sf_audit(p_actor,'role_survey.assign','role_survey_response',null,jsonb_build_object('count',n));
  return jsonb_build_object('updated',n);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_survey_play_date','_sf_role_survey_play_date','_sf_role_survey_complete',
      '_sf_survey_row','admin_role_survey_sessions','admin_role_survey_pick','admin_assign_role_surveys') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
