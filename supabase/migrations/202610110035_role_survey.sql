begin;

-- 角色分配問卷（取代網站的 GoogleAppsScript_角色問卷.gs 與「角色問卷總表」試算表）。
-- 一筆回覆＝網站問卷送出一次；script＝問卷的 window.SURVEY.script，必須是劇本的 reviewKey（games.review_key）。
-- 回覆含性別、感情狀況、「同行玩家中你喜歡的人」等敏感內容：只有店家（admin_users）能經由 admin_* RPC 讀取。
create table public.role_survey_responses (
  id uuid primary key default gen_random_uuid(),
  script text not null check (char_length(script) between 1 and 100),
  fields jsonb not null check (jsonb_typeof(fields)='array' and jsonb_array_length(fields) between 1 and 80),
  submitted_at timestamptz not null default now(),
  source text not null default 'web' check (source in ('web','sheet')),
  client_id uuid unique,  -- 網站每次送出產生的「送出編號」：重送與舊試算表的同一份回覆都靠它認出來
  import_key text unique check (import_key is null or import_key ~ '^[0-9a-f]{64}$'),  -- 試算表某一列（分頁＋時間）
  assigned_role text not null default '' check (char_length(assigned_role)<=100),
  store_note text not null default '' check (char_length(store_note)<=1000),
  updated_at timestamptz
);
create index role_survey_responses_script on public.role_survey_responses(script, submitted_at desc, id desc);
create index role_survey_responses_recent on public.role_survey_responses(submitted_at) where source='web';
alter table public.role_survey_responses enable row level security;
revoke all on public.role_survey_responses from public,anon,authenticated;
grant select,insert,update,delete on public.role_survey_responses to service_role;

-- 已刪除回覆的記號（只有送出編號或試算表列的鍵，不含任何內容）：刪掉的回覆不會被重送或重新匯入帶回來。
create table public.role_survey_tombstones (
  key text primary key check (char_length(key) between 1 and 80),
  deleted_at timestamptz not null default now()
);
alter table public.role_survey_tombstones enable row level security;
revoke all on public.role_survey_tombstones from public,anon,authenticated;
grant select,insert on public.role_survey_tombstones to service_role;

-- 排程工作的上次執行時間（例：每 6 小時自動匯入一次舊試算表）。claim 成功才執行，多台同時叫也只會跑一次。
create table public.scheduled_jobs (
  name text primary key check (char_length(name) between 1 and 60),
  last_run_at timestamptz not null
);
alter table public.scheduled_jobs enable row level security;
revoke all on public.scheduled_jobs from public,anon,authenticated;
grant select,insert,update on public.scheduled_jobs to service_role;

create function public.claim_scheduled_job(p_name text, p_every interval)
returns boolean language plpgsql set search_path='' as $$
declare n integer;
begin
  insert into public.scheduled_jobs(name,last_run_at) values (p_name,now())
    on conflict (name) do update set last_run_at=now() where public.scheduled_jobs.last_run_at<now()-p_every;
  get diagnostics n = row_count;
  return n=1;
end $$;

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

-- Public submit (the website form; no login, like the Apps Script). Guards sized to the shop (a few dozen answers
-- a month): only scripts in the catalog, at most 30 web answers per 10 minutes and 200 or 5 MB per day overall.
-- The same client_id again (a retry after a lost response) is accepted without storing a second copy.
create function public.submit_role_survey(p_script text, p_fields jsonb, p_client_id uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare s text := btrim(coalesce(p_script,'')); clean jsonb; rid uuid;
begin
  if char_length(s) not between 1 and 100 or not exists(select 1 from public.games where review_key=s) then
    raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  clean := public._sf_clean_survey_fields(p_fields);
  if p_client_id is not null then
    select id into rid from public.role_survey_responses where client_id=p_client_id;
    if found or exists(select 1 from public.role_survey_tombstones where key=p_client_id::text) then
      return jsonb_build_object('id',rid,'duplicate',true);
    end if;
  end if;
  if (select count(*) from public.role_survey_responses where source='web' and submitted_at>now()-interval '10 minutes')>=30
     or (select count(*)>=200 or coalesce(sum(octet_length(fields::text)),0)>=5*1024*1024
         from public.role_survey_responses where source='web' and submitted_at>now()-interval '1 day') then
    raise exception 'TOO_MANY_REQUESTS' using errcode='P0001';
  end if;
  insert into public.role_survey_responses(script,fields,client_id) values (s,clean,p_client_id)
    on conflict (client_id) do nothing returning id into rid;
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

-- 店家：某本問卷的回覆，新的在前，一次最多 100 份。翻頁給上一頁最後一份的時間與 id（同一秒的回覆也不會漏）。
create function public.admin_role_survey_responses(p_actor uuid, p_script text, p_limit integer default 50,
  p_before timestamptz default null, p_before_id uuid default null)
returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return coalesce((select jsonb_agg(public._sf_survey_row(x.r) order by (x.r).submitted_at desc, (x.r).id desc) from (
    select r from public.role_survey_responses r
    where r.script=p_script and (p_before is null
      or (r.submitted_at, r.id) < (p_before, coalesce(p_before_id,'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by r.submitted_at desc, r.id desc limit least(greatest(coalesce(p_limit,50),1),100)) x),'[]');
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

-- 刪除（垃圾回覆，或玩家要求刪除個資）。留下不含內容的記號，重送或重新匯入都不會把它帶回來；
-- 舊試算表裡的那一列要店家自己刪。稽核只記哪一筆，不留內容。
create function public.admin_delete_role_survey(p_actor uuid, p_id uuid)
returns jsonb language plpgsql set search_path='' as $$
declare k text; c uuid;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  delete from public.role_survey_responses where id=p_id returning import_key, client_id into k, c;
  if not found then raise exception 'SURVEY_NOT_FOUND' using errcode='P0001'; end if;
  insert into public.role_survey_tombstones(key)
    select x from unnest(array[k, c::text]) x where x is not null on conflict do nothing;
  perform public._sf_audit(p_actor,'role_survey.delete','role_survey_response',p_id);
  return jsonb_build_object('deleted',true);
end $$;

-- 匯入舊「角色問卷總表」的列（api 用服務帳戶讀試算表後呼叫）。
-- p_rows: [{script, submitted_at, fields, import_key, client_id?, assigned_role?, store_note?}]，一次最多 5000 列。
-- 略過：已匯入過的列、已刪除的、以及網站已經收到的同一份（送出編號相同）。
create function public._sf_import_role_surveys(p_actor uuid, p_rows jsonb)
returns jsonb language plpgsql set search_path='' as $$
declare r jsonb; s text; clean jsonb; cid uuid; n integer; imported integer := 0; skipped integer := 0;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows)>5000 then
    raise exception 'INVALID_SURVEY' using errcode='P0001'; end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    s := btrim(coalesce(r->>'script',''));
    cid := case when coalesce(r->>'client_id','') ~ '^[0-9a-fA-F-]{36}$' then (r->>'client_id')::uuid end;
    if char_length(s) not between 1 and 100 or coalesce(r->>'import_key','') !~ '^[0-9a-f]{64}$'
       or coalesce(r->>'submitted_at','')=''
       or exists(select 1 from public.role_survey_tombstones where key in (r->>'import_key', cid::text))
       or (cid is not null and exists(select 1 from public.role_survey_responses where client_id=cid)) then
      skipped := skipped+1; continue;
    end if;
    begin
      clean := public._sf_clean_survey_fields(r->'fields');
      insert into public.role_survey_responses(script,fields,submitted_at,source,import_key,client_id,assigned_role,store_note)
        values (s,clean,(r->>'submitted_at')::timestamptz,'sheet',r->>'import_key',cid,
          left(btrim(coalesce(r->>'assigned_role','')),100),left(btrim(coalesce(r->>'store_note','')),1000))
        on conflict do nothing;
      get diagnostics n = row_count;
      if n=1 then imported := imported+1; else skipped := skipped+1; end if;
    exception when others then skipped := skipped+1;  -- a bad row (empty, unreadable date) never blocks the rest
    end;
  end loop;
  if imported>0 then
    perform public._sf_audit(p_actor,'role_survey.import','role_survey_response',null,
      jsonb_build_object('imported',imported,'skipped',skipped));
  end if;
  return jsonb_build_object('imported',imported,'skipped',skipped);
end $$;

create function public.admin_import_role_surveys(p_actor uuid, p_rows jsonb)
returns jsonb language plpgsql set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return public._sf_import_role_surveys(p_actor,p_rows);
end $$;

-- The 6-hourly automatic import during the transition (answers the website sent to the old Apps Script).
create function public.system_import_role_surveys(p_rows jsonb)
returns jsonb language sql set search_path='' as $$ select public._sf_import_role_surveys(null,p_rows) $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_clean_survey_fields','submit_role_survey','_sf_survey_row',
      'admin_role_survey_scripts','admin_role_survey_responses','admin_update_role_survey','admin_delete_role_survey',
      '_sf_import_role_surveys','admin_import_role_surveys','system_import_role_surveys','claim_scheduled_job') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
