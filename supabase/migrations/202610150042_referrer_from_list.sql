begin;

-- 介紹人改成從名單選（網站表單只列現有玩家、只在第一次來海星時顯示）。伺服器同樣把關：
-- 網站送出的生涯第一筆記錄填了名單外的介紹人 → REFERRER_NOT_FOUND，整筆不寫入，玩家改好再送。
-- 不是第一筆的記錄照舊忽略介紹人（舊頁面可能還會送）；試算表補匯入照舊只記錄。計分規則不變。
create or replace function public._sf_add_play_record(p jsonb, p_source text, p_submitted_at timestamptz, p_legacy boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare
  c jsonb := public._sf_record_config();
  web boolean := p_source = 'web';
  v_name text := public._sf_clean_text(p->>'name', case when web then 30 else 60 end);
  v_raw_date text := public._sf_clean_text(p->>'date', case when web then 20 else 40 end);
  v_script text := public._sf_clean_text(p->>'script', 100);
  v_role text := public._sf_clean_text(p->>'role', case when web then 100 else 300 end);
  v_rating text := public._sf_clean_text(p->>'rating', 10);
  v_comment text := public._sf_clean_text(p->>'comment', case when web then 50 else 2000 end);
  v_referrer text := public._sf_clean_text(p->>'referrer', case when web then 30 else 60 end);
  v_played date := public._sf_parse_play_date(v_raw_date);
  v_date text := public._sf_date_text(v_raw_date);
  v_day date := (p_submitted_at at time zone 'Asia/Taipei')::date;  -- null：舊表單沒有時間戳記的列（永遠不算補登，同 Apps Script）
  launch date := public._sf_parse_play_date(c->>'LINE上線日');
  pid uuid; rid uuid := gen_random_uuid(); ref_id uuid;
  v_status text; fp boolean := false; ever boolean := false; long_c boolean := false; dbl boolean := false;
  pts integer := 0; parts text[] := '{}'; referred integer := 0; extra jsonb := '[]';
begin
  -- validate_：網站送出要有名字、日期、劇本、角色與 1–5 的評價；試算表的舊列只要有名字和劇本（與重算時相同）。
  if v_name = '' or v_script = '' or public._sf_name_norm(v_name) = ''
     or (web and (v_raw_date = '' or v_role = '' or v_rating !~ '^[1-5]$')) then
    raise exception 'INVALID_RECORD' using errcode='P0001';
  end if;
  -- 新送出的記錄（網站、切換後補匯入的試算表列；不含重播舊資料）：劇本要在劇本目錄裡、遊玩日期要認得出來且不在未來。
  -- Apps Script 時代靠店家人工審核；點數固定之後，亂填劇本名或未來日期就能無限拿首探、首玩與每日上限。
  if not p_legacy and (v_played is null or v_played > v_day
      or not exists(select 1 from public.games g
                    where public._sf_name_norm(coalesce(g.review_key, g.title)) = public._sf_name_norm(v_script))) then
    raise exception 'INVALID_RECORD' using errcode='P0001';
  end if;
  if v_date = '' then v_date := '—'; end if;  -- 舊表單偶有空白日期：照樣記錄（不會進任何月份）
  pid := public._sf_ensure_player(v_name, v_played, p_source);

  if launch is not null and v_played is not null and v_day is not null and v_day >= launch
     and v_day - v_played > (c->>'補登寬限天數')::int then
    v_status := 'backfill';  -- 只記錄不給點，也不佔首玩、首探、介紹、每日上限、任務
  elsif exists(select 1 from public.play_records where player_id=pid and script=v_script and date_text=v_date
                 and status in ('earn','daily_cap') and not hidden) then
    v_status := 'duplicate';
  elsif (select count(*) from public.play_records where player_id=pid and date_text=v_date
           and status in ('earn','daily_cap') and not hidden) >= (c->>'每日上限筆數')::int then
    v_status := 'daily_cap';
  else
    v_status := 'earn';
    pts := (c->>'基本點數')::int; parts := parts || ('基本'||(c->>'基本點數'));
    if public._sf_char_count(v_comment) >= (c->>'心得字數門檻')::int then
      long_c := true; pts := pts + (c->>'心得點數')::int; parts := parts || ('心得'||(c->>'心得點數'));
    end if;
    ever := not exists(select 1 from public.play_records where player_id=pid and status='earn' and not hidden);
    if not exists(select 1 from public.play_records where player_id=pid and script=v_script and status='earn' and not hidden) then
      fp := true;  -- 算「新本」任務；生涯第一筆給新手好運、不另給首玩（新規則）
      if not ever or p_legacy then pts := pts + (c->>'首玩點數')::int; parts := parts || ('首玩'||(c->>'首玩點數')); end if;
    end if;
    if not exists(select 1 from public.play_records where script=v_script and status='earn' and not hidden) then
      pts := pts + (c->>'首探點數')::int; parts := parts || ('首探'||(c->>'首探點數'));
    end if;
    if ever then
      pts := pts + (c->>'新手好運點數')::int; parts := parts || ('新手好運'||(c->>'新手好運點數'));
    end if;
    if public._sf_is_double_day(v_played, v_date, c->>'雙倍日') then
      dbl := true;
      if p_legacy then pts := pts * 2; parts := parts || '雙倍日 x2'::text;
      else pts := pts + (c->>'基本點數')::int; parts := parts || '雙倍日 基本x2'::text; end if;
    end if;
    -- 介紹人：只在被介紹者第一筆計點記錄結算一次，雙方都不加倍。
    -- 新規則（店家定案）：介紹人必須是已有的玩家，亂填的只記錄不給點。舊資料照 Apps Script 當時的判斷。
    if ever and v_referrer <> '' then
      ref_id := public._sf_find_player(v_referrer);
      -- 網站送出：介紹人要從名單選；名單外的名字直接退回讓玩家改（以前是默默只記錄、不給點）。
      -- 試算表補匯入的列照舊只記錄（Apps Script 不檢查，退回會讓那列匯不進來）。
      if ref_id is null and web then raise exception 'REFERRER_NOT_FOUND' using errcode='P0001'; end if;
      if ref_id is null and p_legacy then  -- 舊規則：亂填的介紹人也拿點（點數總覽裡有這個名字，但沒有探員編號）
        insert into public.record_players(name, source) values (left(v_referrer,60), p_source) returning id into ref_id;
      end if;
      if ref_id = pid then ref_id := null; end if;
      if ref_id is not null then referred := (c->>'被介紹點數')::int; end if;
    end if;
  end if;

  insert into public.play_records(id,submitted_at,name,player_id,script,date_text,played_on,role,rating,comment,referrer,referrer_id,
      status,first_play,long_comment,points,detail,source,client_id,import_key)
    values (rid,coalesce(p_submitted_at,'1970-01-01Z'),v_name,pid,v_script,v_date,v_played,v_role,
      case when v_rating ~ '^[1-5]$' then v_rating::smallint end,v_comment,v_referrer,ref_id,v_status,fp,long_c,
      pts+referred,array_to_string(parts,'＋'),p_source,
      case when coalesce(p->>'client_id','') ~ '^[0-9a-fA-F-]{36}$' then (p->>'client_id')::uuid end,
      nullif(p->>'import_key',''));

  if v_status = 'earn' and not p_legacy then
    insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,record_id,dedupe_key,source)
      values (pid,'record',pts,array_to_string(parts,'＋'),v_script,v_date,v_played,case when dbl then '雙倍點數日' else '' end,
        rid,'rec|'||rid,p_source);
    if ref_id is not null then
      insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,record_id,dedupe_key,source)
        values (pid,'referred',referred,'被介紹'||referred,v_script,v_date,v_played,left('介紹人：'||v_referrer,300),rid,'ref|'||rid||'|referred',p_source),
               (ref_id,'referrer',(c->>'介紹人點數')::int,'介紹新玩家'||(c->>'介紹人點數'),v_script,v_date,v_played,
                left('介紹了：'||v_name,300),rid,'ref|'||rid||'|referrer',p_source);
      extra := extra || jsonb_build_array(jsonb_build_object('detail','被介紹'||referred,'points',referred));
    end if;
    if v_played is not null then
      extra := extra || public._sf_award_quests(pid, date_trunc('month', v_played)::date, array['場次','心得','新本'], p_source);
      if ref_id is not null then
        perform public._sf_award_quests(ref_id, date_trunc('month', v_played)::date, array['揪團'], p_source);
      end if;
    end if;
  end if;

  return jsonb_build_object('id',rid,'status',v_status,'player',(select name from public.record_players where id=pid),
    'award',case when v_status='earn' then jsonb_build_object('points',pts,'detail',array_to_string(parts,'＋'),'script',v_script,
      'extra',extra) end);
end $$;

commit;
