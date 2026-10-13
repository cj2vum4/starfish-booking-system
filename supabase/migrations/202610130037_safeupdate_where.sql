-- 0037：0036 的整表刪除／更新加上 WHERE（2026-10-13）。
-- Supabase 經 PostgREST 呼叫時載入 safeupdate，沒有 WHERE 的 DELETE／UPDATE 一律拒絕（錯誤 21000「DELETE requires a WHERE clause」），
-- 店家第一次按「匯入玩本記錄」就失敗；切換、補匯入也會。本機測試的 Postgres 沒有 safeupdate，所以沒抓到
-- （之後 tests/database.test.mjs 會檢查所有 migration）。內容與 0036 相同，只多了 `where true`／`where id`；權限沿用（create or replace 不變）。
begin;

create or replace function public._sf_import_play_records(p_actor uuid, p jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare x jsonb; i integer; pid uuid; rid uuid; iid uuid; k text; m text[];
  n_players integer := 0; n_records integer := 0; n_ledger integer := 0; n_inter integer := 0;
  anomalies jsonb := '[]'; feat integer; kind text; dk text; pts integer; cutoff timestamptz;
begin
  if jsonb_typeof(p->'responses') is distinct from 'array' or jsonb_typeof(p->'ledger') is distinct from 'array'
     or jsonb_array_length(p->'responses') > 20000 or jsonb_array_length(p->'ledger') > 50000 then
    raise exception 'INVALID_IMPORT' using errcode='P0001';
  end if;
  if public._sf_records_lock() <> 'gas' then raise exception 'RECORDS_LIVE' using errcode='P0001'; end if;
  if (select went_live_at from public.record_state) is not null then raise exception 'RECORDS_WENT_LIVE' using errcode='P0001'; end if;

  delete from public.point_ledger where true; delete from public.review_likes where true; delete from public.review_interactions where true;
  delete from public.play_records where true; delete from public.record_aliases where true; delete from public.record_players where true;
  delete from public.record_settings where true; delete from public.record_rewards where true; delete from public.record_quests where true;

  insert into public.record_settings(key,value)
    select distinct on (ck) ck, left(public._sf_js_trim(e->>'value'),200)
    from jsonb_array_elements(coalesce(p->'config','[]')) with ordinality t(e,o), lateral (select public._sf_js_trim(e->>'key') ck) kk
    where ck in ('基本點數','心得點數','心得字數門檻','首玩點數','首探點數','新手好運點數','介紹人點數','被介紹點數','每日上限筆數',
      '讚點數','讚點數上限','精選點數','雙倍日','雙倍日文案','回歸禮資格日','LINE上線日','補登寬限天數')
    order by ck, o desc;  -- 同一項寫了兩次：後面的蓋前面（readConfig_）
  insert into public.record_rewards(sort,track,name,cost,note,active)
    select o, left(public._sf_js_trim(e->>'track'),20), left(public._sf_js_trim(e->>'name'),60), coalesce(round((e->>'cost')::numeric),0),
      left(public._sf_js_trim(e->>'note'),200), coalesce((e->>'active')::boolean,true)
    from jsonb_array_elements(coalesce(p->'rewards','[]')) with ordinality t(e,o) where public._sf_js_trim(e->>'name') <> '';
  insert into public.record_quests(id,sort,label,goal,points,active)
    select distinct on (qid) qid, o, left(public._sf_js_trim(e->>'label'),100), coalesce(round((e->>'goal')::numeric),0),
      coalesce(round((e->>'points')::numeric),0), coalesce((e->>'active')::boolean,true)
    from jsonb_array_elements(coalesce(p->'quests','[]')) with ordinality t(e,o), lateral (select left(public._sf_js_trim(e->>'id'),20) qid) q
    where qid <> '' order by qid, o;

  -- 玩家：顯示名重複時照 Apps Script 的讀法——
  --   一字不差的同名：探員編號取後面有填的那列，榮耀軌取後面那列，加入日期取第一列（回歸禮看第一列）；
  --   只差空白或大小寫：名字對照是後面那列蓋前面，整列以後面那列為準。
  -- 別名分兩輪：別名蓋過顯示名，後面的列蓋前面的。
  for x, i in select e, o from jsonb_array_elements(coalesce(p->'players','[]')) with ordinality t(e,o) loop
    k := left(public._sf_js_trim(x->>'name'),60);
    if public._sf_name_norm(k) = '' then continue; end if;
    if exists(select 1 from public.record_players where name_norm = public._sf_name_norm(k)) then
      anomalies := anomalies || jsonb_build_array(jsonb_build_object('type','duplicate_player','name',k));
      if exists(select 1 from public.record_players where name = k) then
        begin
          update public.record_players set agent = coalesce(nullif(left(public._sf_js_trim(x->>'agent'),20),''), agent),
            note = left(public._sf_js_trim(x->>'note'),500), gilded = coalesce((x->>'gilded')::boolean,false),
            title = left(public._sf_js_trim(x->>'title'),40), legend = coalesce((x->>'legend')::boolean,false)
            where name = k;
        exception when unique_violation then
          anomalies := anomalies || jsonb_build_array(jsonb_build_object('type','duplicate_agent','name',k,'agent',x->>'agent'));
        end;
        continue;
      end if;
      delete from public.record_players where name_norm = public._sf_name_norm(k);
      n_players := n_players - 1;
    end if;
    insert into public.record_players(name,agent,joined_on,note,gilded,title,legend,source)
      values (k, nullif(left(public._sf_js_trim(x->>'agent'),20),''), public._sf_parse_play_date(x->>'joined'),
        left(public._sf_js_trim(x->>'note'),500), coalesce((x->>'gilded')::boolean,false),
        left(public._sf_js_trim(x->>'title'),40), coalesce((x->>'legend')::boolean,false), 'sheet')
      on conflict (agent) do nothing;
    if not found then
      anomalies := anomalies || jsonb_build_array(jsonb_build_object('type','duplicate_agent','name',k,'agent',x->>'agent'));
      insert into public.record_players(name,joined_on,note,gilded,title,legend,source)
        values (k, public._sf_parse_play_date(x->>'joined'), left(public._sf_js_trim(x->>'note'),500),
          coalesce((x->>'gilded')::boolean,false), left(public._sf_js_trim(x->>'title'),40), coalesce((x->>'legend')::boolean,false), 'sheet');
    end if;
    n_players := n_players + 1;
  end loop;
  for x in select e from jsonb_array_elements(coalesce(p->'players','[]')) e loop
    select id into pid from public.record_players where name_norm = public._sf_name_norm(x->>'name');
    if pid is null then continue; end if;
    for k in select public._sf_js_trim(a) from jsonb_array_elements_text(coalesce(x->'aliases','[]')) a loop
      if public._sf_name_norm(k) in ('', public._sf_name_norm(x->>'name')) then continue; end if;
      insert into public.record_aliases(alias_norm,alias,player_id) values (public._sf_name_norm(k), left(k,60), pid)
        on conflict (alias_norm) do update set alias=excluded.alias, player_id=excluded.player_id;
    end loop;
  end loop;

  -- 心得互動（記錄的作者名＋劇本＋日期）。
  for x in select e from jsonb_array_elements(coalesce(p->'interactions','[]')) e loop
    if public._sf_js_trim(x->>'script') = '' or public._sf_name_norm(x->>'author') = '' then continue; end if;
    insert into public.review_interactions(script,date_text,author,likes,featured,updated_at)
      values (left(public._sf_js_trim(x->>'script'),100), left(public._sf_date_text(x->>'date'),40), left(public._sf_js_trim(x->>'author'),60),
        greatest(coalesce(round((x->>'likes')::numeric),0),0), coalesce((x->>'featured')::boolean,false),
        coalesce((x->>'updated')::timestamptz, now()))
      on conflict (script,date_text,author_norm) do nothing;
    if found then n_inter := n_inter + 1;
    else anomalies := anomalies || jsonb_build_array(jsonb_build_object('type','duplicate_interaction','script',x->>'script','author',x->>'author'));
    end if;
  end loop;

  -- 表單回應：依遊玩日、送出時間、列順序重播（rebuildPoints_ 的順序）。沒有名字或劇本的列略過（與重算相同）。
  for x in
    select e from jsonb_array_elements(p->'responses') with ordinality t(e,o)
    where public._sf_js_trim(e->>'name') <> '' and public._sf_js_trim(e->>'script') <> ''
    order by public._sf_parse_play_date(left(public._sf_clean_text(e->>'date',40),40)) nulls first,
      (e->>'stamp')::timestamptz nulls first, o
  loop
    if coalesce(x->>'key','') !~ '^[0-9a-f]{64}$' then raise exception 'INVALID_IMPORT' using errcode='P0001'; end if;
    perform public._sf_add_play_record(jsonb_build_object('name',x->>'name','date',x->>'date','script',x->>'script','role',x->>'role',
      'rating',x->>'rating','comment',x->>'comment','referrer',x->>'referrer','import_key',x->>'key'), 'sheet',
      (x->>'stamp')::timestamptz, true);
    n_records := n_records + 1;
  end loop;

  -- 點數帳本：原樣搬。玩家以「歸戶名」的顯示名對應（點數總覽就是這樣分人）；找不到就建一位。
  -- 歸戶名空白的列（店家手動加、只填玩家名）Apps Script 完全不算：一樣略過，列在需要留意的清單讓店家補上再匯入。
  for x, i in select e, o from jsonb_array_elements(p->'ledger') with ordinality t(e,o) loop
    k := left(public._sf_js_trim(x->>'player'),60);
    if public._sf_name_norm(k) = '' then
      if public._sf_name_norm(x->>'name') <> '' and coalesce(round((x->>'points')::numeric),0) <> 0 then
        anomalies := anomalies || jsonb_build_array(jsonb_build_object('type','ledger_row_without_account',
          'name',left(public._sf_js_trim(x->>'name'),60)));
      end if;
      continue;
    end if;
    pts := coalesce(round((x->>'points')::numeric),0);
    if public._sf_js_trim(x->>'type') = 'skip' and pts = 0 then continue; end if;
    select id into pid from public.record_players where name_norm = public._sf_name_norm(k);
    if pid is null then
      insert into public.record_players(name,source) values (k,'sheet') returning id into pid;
      anomalies := anomalies || jsonb_build_array(jsonb_build_object('type',
        case when exists(select 1 from public.record_aliases where alias_norm=public._sf_name_norm(k)) then 'ledger_name_is_alias'
          else 'ledger_only_player' end,'name',k));
    end if;
    rid := null; iid := null; dk := 'sheet|'||i; feat := 0;
    case public._sf_js_trim(x->>'source')
      when '表單' then
        kind := case when x->>'detail' like '被介紹%' then 'referred' when x->>'detail' like '介紹新玩家%' then 'referrer' else 'record' end;
        if kind <> 'referrer' then
          select id into rid from public.play_records where player_id=pid and script=public._sf_js_trim(x->>'script')
            and date_text=public._sf_date_text(x->>'date') and status='earn' order by submitted_at limit 1;
        end if;
      when '任務' then
        kind := 'quest';
        m := regexp_match(coalesce(x->>'key',''), '^quest\|.*\|(\d{4})/(\d{2})\|([^|]+)$');
        if m is not null then dk := 'quest|'||pid||'|'||m[1]||'-'||m[2]||'|'||m[3]; end if;
      when '心得讚' then
        kind := 'like';
        select ri.id into iid from public.review_interactions ri where ri.script=public._sf_js_trim(x->>'script')
          and ri.date_text=public._sf_date_text(x->>'date') and public._sf_find_player(ri.author)=pid order by ri.updated_at limit 1;
        if x->>'detail' like '%精選心得%' then
          feat := coalesce(nullif(substring(x->>'detail' from '精選心得(\d+)'),'')::int,0);
        end if;
      when 'LINE' then
        kind := 'bonus';
        if coalesce(x->>'key','') like 'return-bonus|%' then dk := 'bonus|return|'||pid; end if;
      else
        kind := case when pts < 0 then 'redeem' else 'adjust' end;
    end case;
    if feat > 0 and iid is not null then
      insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,interaction_id,dedupe_key,source,created_at,
          voided_at,void_reason)
        values (pid,'featured',feat,'精選心得'||feat,left(public._sf_js_trim(x->>'script'),100),left(public._sf_date_text(x->>'date'),40),
          public._sf_parse_play_date(x->>'date'),'',iid,'featured|'||iid,'sheet',coalesce((x->>'stamp')::timestamptz,now()),
          case when public._sf_js_trim(x->>'status')='作廢' then now() end,
          case when public._sf_js_trim(x->>'status')='作廢' then '試算表標為作廢' else '' end)
        on conflict (dedupe_key) do nothing;
      if found then pts := pts - feat; n_ledger := n_ledger + 1; end if;
      if iid is not null then dk := 'like|'||iid||'|import'; end if;
    elsif kind = 'like' and iid is not null then
      dk := 'like|'||iid||'|import';
    end if;
    insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,record_id,interaction_id,dedupe_key,source,
        created_at,voided_at,void_reason)
      values (pid,kind,pts,left(coalesce(x->>'detail',''),200),left(public._sf_js_trim(x->>'script'),100),
        left(public._sf_date_text(x->>'date'),40),
        case when kind='quest' and m is not null then make_date(m[1]::int,m[2]::int,1) else public._sf_parse_play_date(x->>'date') end,
        left(coalesce(x->>'note',''),300),rid,iid,dk,'sheet',coalesce((x->>'stamp')::timestamptz,now()),
        case when public._sf_js_trim(x->>'status')='作廢' then now() end,
        case when public._sf_js_trim(x->>'status')='作廢' then '試算表標為作廢' else '' end)
      on conflict (dedupe_key) do nothing;
    if found then n_ledger := n_ledger + 1;
    else
      -- 同一件事出現兩次（例：同一個月同一任務兩列）：照原樣保留第二列，只是不再當成那件事的去重依據。
      insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,record_id,interaction_id,dedupe_key,source,
          created_at,voided_at,void_reason)
        values (pid,kind,pts,left(coalesce(x->>'detail',''),200),left(public._sf_js_trim(x->>'script'),100),
          left(public._sf_date_text(x->>'date'),40),public._sf_parse_play_date(x->>'date'),left(coalesce(x->>'note',''),300),
          rid,iid,'sheet|'||i,'sheet',coalesce((x->>'stamp')::timestamptz,now()),
          case when public._sf_js_trim(x->>'status')='作廢' then now() end,
          case when public._sf_js_trim(x->>'status')='作廢' then '試算表標為作廢' else '' end);
      n_ledger := n_ledger + 1;
      anomalies := anomalies || jsonb_build_array(jsonb_build_object('type','repeated_key','name',k,'key',x->>'key'));
    end if;
    m := null;
    -- 作廢的表單列：那天那本的記錄都標為作廢（Apps Script 以「歸戶名＋劇本＋日期」作廢）。
    if kind in ('record','referred') and public._sf_js_trim(x->>'status')='作廢' then
      update public.play_records set voided=true where player_id=pid and script=public._sf_js_trim(x->>'script')
        and date_text=public._sf_date_text(x->>'date');
    end if;
  end loop;

  -- 記錄的點數與明細以帳本為準（固定的那份）。
  update public.play_records pr set points = coalesce((select sum(l.points) from public.point_ledger l
      where l.record_id=pr.id and l.kind in ('record','referred')),0),
    detail = coalesce((select left(l.detail,200) from public.point_ledger l where l.record_id=pr.id and l.kind='record' limit 1), '')
    where pr.status='earn';

  -- 手打成未來時間的列不能把分界推到未來（之後真正的新列會被當成已匯入而略過）
  select least(max((e->>'stamp')::timestamptz), now()) into cutoff from jsonb_array_elements(p->'responses') e;
  update public.record_state set imported_at=now(), imported_by=p_actor, sheet_cutoff=cutoff,
    import_summary=jsonb_build_object('players',(select count(*) from public.record_players),'records',n_records,
      'ledger',n_ledger,'interactions',n_inter,'anomalies',jsonb_array_length(anomalies))
    where id;
  perform public._sf_audit(p_actor,'records.import','record_state',null,
    jsonb_build_object('records',n_records,'ledger',n_ledger,'players',n_players));
  return jsonb_build_object('players',(select count(*) from public.record_players),'records',n_records,'ledger',n_ledger,
    'interactions',n_inter,'anomalies',anomalies,'sheetCutoff',cutoff);
end $$;

create or replace function public._sf_import_new_play_records(p_actor uuid, p_rows jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare x jsonb; st public.record_state; added integer := 0; skipped integer := 0; failed integer := 0; res jsonb;
begin
  if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) > 20000 then
    raise exception 'INVALID_IMPORT' using errcode='P0001'; end if;
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  select * into st from public.record_state;
  for x in select e from jsonb_array_elements(p_rows) with ordinality t(e,o)
    order by (e->>'stamp')::timestamptz nulls first, o loop
    if coalesce(x->>'key','') !~ '^[0-9a-f]{64}$' or (x->>'stamp') is null
       or (st.sheet_cutoff is not null and (x->>'stamp')::timestamptz <= st.sheet_cutoff)
       or exists(select 1 from public.play_records where import_key = x->>'key') then
      skipped := skipped + 1; continue;
    end if;
    begin
      res := public._sf_add_play_record(jsonb_build_object('name',x->>'name','date',x->>'date','script',x->>'script','role',x->>'role',
        'rating',x->>'rating','comment',x->>'comment','referrer',x->>'referrer','import_key',x->>'key'), 'sheet', (x->>'stamp')::timestamptz);
      added := added + 1;
    exception when others then failed := failed + 1;  -- 一列不合格（例如劇本不在目錄裡）不擋其他列；分開計數
    end;
  end loop;
  if added > 0 then
    perform public._sf_audit(p_actor,'records.import_new','record_state',null,
      jsonb_build_object('added',added,'skipped',skipped,'failed',failed));
  end if;
  update public.record_state set catch_up_at=now(),
    catch_up_result=jsonb_build_object('added',added,'skipped',skipped,'failed',failed,'by',case when p_actor is null then 'schedule' else 'store' end)
    where id;
  return jsonb_build_object('added',added,'skipped',skipped,'failed',failed);
end $$;

create or replace function public.system_records_catch_up_failed(p_code text) returns void
language sql set search_path='' as $$
  update public.record_state set catch_up_at=now(), catch_up_result=jsonb_build_object('error',left(coalesce(p_code,''),60))
  where id
$$;

create or replace function public.admin_set_records_source(p_actor uuid, p_source text, p_force boolean default false) returns jsonb
language plpgsql set search_path='' as $$
declare st public.record_state;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if p_source not in ('gas','supabase') then raise exception 'INVALID_SOURCE' using errcode='P0001'; end if;
  perform public._sf_records_lock();
  select * into st from public.record_state;
  if p_source = 'supabase' and st.imported_at is null then raise exception 'IMPORT_REQUIRED' using errcode='P0001'; end if;
  -- 比對的必須是剛讀到的 Apps Script 總覽（api 切換前會先重讀一次）：舊的副本可能漏掉匯入之後才手動加的兌換、補點。
  if p_source = 'supabase' and st.went_live_at is null and not coalesce(p_force,false) then
    if coalesce((select fetched_at from public.play_record_snapshot where id=1), '-infinity') < now() - interval '10 minutes' then
      raise exception 'RECONCILE_STALE' using errcode='P0001';
    end if;
    if not (public.admin_records_reconcile(p_actor)->>'matched')::boolean then
      raise exception 'RECONCILE_MISMATCH' using errcode='P0001';
    end if;
  end if;
  update public.record_state set source=p_source, switched_at=now(), switched_by=p_actor,
    went_live_at=coalesce(went_live_at, case when p_source='supabase' then now() end)
    where id;
  perform public._sf_audit(p_actor,'records.source','record_state',null,jsonb_build_object('source',p_source,'force',coalesce(p_force,false)));
  return public.admin_records_status(p_actor);
end $$;

commit;
