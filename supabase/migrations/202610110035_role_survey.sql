begin;

-- 角色分配問卷（取代網站的 GoogleAppsScript_角色問卷.gs 與「角色問卷總表」試算表）。
-- 一筆回覆＝網站問卷送出一次；script＝問卷的 window.SURVEY.script（通常＝劇本的 reviewKey）。
-- 回覆含性別、感情狀況、「同行玩家中你喜歡的人」等敏感內容：只有店家（admin_users）能經由 admin_* RPC 讀取。
create table public.role_survey_responses (
  id uuid primary key default gen_random_uuid(),
  script text not null check (char_length(script) between 1 and 100),
  fields jsonb not null check (jsonb_typeof(fields)='array' and jsonb_array_length(fields) between 1 and 80),
  submitted_at timestamptz not null default now(),
  source text not null default 'web' check (source in ('web','sheet')),
  import_key text unique check (import_key is null or import_key ~ '^[0-9a-f]{64}$'),  -- 試算表匯入的去重鍵
  assigned_role text not null default '' check (char_length(assigned_role)<=100),
  store_note text not null default '' check (char_length(store_note)<=1000),
  updated_at timestamptz
);
create index role_survey_responses_script on public.role_survey_responses(script, submitted_at desc);
alter table public.role_survey_responses enable row level security;
revoke all on public.role_survey_responses from public,anon,authenticated;
grant select,insert,update,delete on public.role_survey_responses to service_role;

-- Same rules as the Apps Script: at most 80 answers, labels up to 200 characters, answers up to 5000;
-- a multiple choice (array) is joined with ", " like a Google Form export; numbers become text.
-- Answers are stored as plain text and never evaluated, so no formula escaping is needed.
create function public._sf_clean_survey_fields(p_fields jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare f jsonb; label text; val text; out jsonb := '[]';
begin
  if jsonb_typeof(p_fields) is distinct from 'array' then raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  for f in select value from jsonb_array_elements(p_fields) with ordinality as e(value,n) where n<=80 order by n loop
    if jsonb_typeof(f) is distinct from 'object' or jsonb_typeof(f->'label') is distinct from 'string' then continue; end if;
    label := left(btrim(f->>'label'),200);
    if label='' then continue; end if;
    val := case jsonb_typeof(f->'value')
      when 'array' then (select string_agg(case jsonb_typeof(x) when 'string' then x#>>'{}' else x::text end, ', ' order by i)
                         from jsonb_array_elements(f->'value') with ordinality as a(x,i))
      when 'string' then f->>'value'
      when 'number' then f->>'value'
      when 'boolean' then f->>'value'
      else '' end;
    out := out || jsonb_build_array(jsonb_build_object('label',label,'value',left(coalesce(val,''),5000)));
  end loop;
  if jsonb_array_length(out)=0 then raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  return out;
end $$;

-- Public submit (the api calls it for the website form; anyone may submit, like the Apps Script did).
-- A crude flood guard keeps a bot from filling the table: at most 200 web answers per 10 minutes overall.
create function public.submit_role_survey(p_script text, p_fields jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare s text := btrim(coalesce(p_script,'')); clean jsonb; rid uuid;
begin
  if char_length(s) not between 1 and 100 then raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  clean := public._sf_clean_survey_fields(p_fields);
  if (select count(*) from public.role_survey_responses
      where source='web' and submitted_at>now()-interval '10 minutes')>=200 then
    raise exception 'TOO_MANY_REQUESTS' using errcode='P0001';
  end if;
  insert into public.role_survey_responses(script,fields) values (s,clean) returning id into rid;
  return jsonb_build_object('id',rid);
end $$;

create function public._sf_survey_row(r public.role_survey_responses)
returns jsonb language sql immutable set search_path='' as $$
  select jsonb_build_object('id',r.id,'script',r.script,'fields',r.fields,'submitted_at',r.submitted_at,'source',r.source,
    'assigned_role',r.assigned_role,'store_note',r.store_note,'updated_at',r.updated_at)
$$;

-- 店家：每本問卷的份數、還沒分配角色的份數、最新一份的時間。
create function public.admin_role_survey_scripts(p_actor uuid)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return coalesce((select jsonb_agg(x order by x->>'latest_at' desc) from (
    select jsonb_build_object('script',script,'total',count(*),'unassigned',count(*) filter (where assigned_role=''),
      'latest_at',max(submitted_at)) x
    from public.role_survey_responses group by script) t),'[]');
end $$;

-- 店家：某本問卷的回覆，新的在前，一次最多 100 份；p_before 給上一頁最後一份的時間繼續往前翻。
create function public.admin_role_survey_responses(p_actor uuid, p_script text, p_limit integer default 50,
  p_before timestamptz default null)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return coalesce((select jsonb_agg(public._sf_survey_row(x.r) order by (x.r).submitted_at desc, (x.r).id) from (
    select r from public.role_survey_responses r
    where r.script=p_script and (p_before is null or r.submitted_at<p_before)
    order by r.submitted_at desc, r.id limit least(greatest(coalesce(p_limit,50),1),100)) x),'[]');
end $$;

create function public.admin_update_role_survey(p_actor uuid, p_id uuid, p_assigned_role text, p_store_note text)
returns jsonb language plpgsql set search_path='' as $$
declare r public.role_survey_responses%rowtype;
  a text := btrim(coalesce(p_assigned_role,'')); n text := btrim(coalesce(p_store_note,''));
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if char_length(a)>100 or char_length(n)>1000 then raise exception 'INVALID_NOTE' using errcode='P0001'; end if;
  update public.role_survey_responses set assigned_role=a, store_note=n, updated_at=now() where id=p_id returning * into r;
  if not found then raise exception 'SURVEY_NOT_FOUND' using errcode='P0001'; end if;
  perform public._sf_audit(p_actor,'role_survey.update','role_survey_response',p_id,jsonb_build_object('assigned_role',a));
  return public._sf_survey_row(r);
end $$;

-- 刪除（垃圾回覆，或玩家要求刪除個資）。稽核只記哪一筆，不留內容。
create function public.admin_delete_role_survey(p_actor uuid, p_id uuid)
returns jsonb language plpgsql set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  delete from public.role_survey_responses where id=p_id;
  if not found then raise exception 'SURVEY_NOT_FOUND' using errcode='P0001'; end if;
  perform public._sf_audit(p_actor,'role_survey.delete','role_survey_response',p_id);
  return jsonb_build_object('deleted',true);
end $$;

-- 從舊的「角色問卷總表」匯入（api 用服務帳戶讀試算表後呼叫）。同一列再匯入一次不會重複（import_key）。
-- p_rows: [{script, submitted_at, fields, import_key}]，一次最多 5000 列。
create function public.admin_import_role_surveys(p_actor uuid, p_rows jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare r jsonb; s text; clean jsonb; n integer; imported integer := 0; skipped integer := 0;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)>5000 then
    raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    s := btrim(coalesce(r->>'script',''));
    if char_length(s) not between 1 and 100 or coalesce(r->>'import_key','') !~ '^[0-9a-f]{64}$'
       or coalesce(r->>'submitted_at','')='' then skipped := skipped+1; continue; end if;
    begin
      clean := public._sf_clean_survey_fields(r->'fields');
      insert into public.role_survey_responses(script,fields,submitted_at,source,import_key)
        values (s,clean,(r->>'submitted_at')::timestamptz,'sheet',r->>'import_key')
        on conflict (import_key) do nothing;
      get diagnostics n = row_count;
      if n=1 then imported := imported+1; else skipped := skipped+1; end if;
    exception when others then skipped := skipped+1;  -- a bad row (empty, unreadable date) never blocks the rest
    end;
  end loop;
  perform public._sf_audit(p_actor,'role_survey.import','role_survey_response',null,
    jsonb_build_object('imported',imported,'skipped',skipped));
  return jsonb_build_object('imported',imported,'skipped',skipped);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_clean_survey_fields','submit_role_survey','_sf_survey_row',
      'admin_role_survey_scripts','admin_role_survey_responses','admin_update_role_survey','admin_delete_role_survey',
      'admin_import_role_surveys') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
