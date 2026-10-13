-- Run in Supabase SQL Editor after 202610120036_play_records.sql. All synthetic records are rolled back.
-- Checks the Apps Script rules carried over (fixed at submit time), the import, reconcile and the cutover switch.
begin;
-- The api calls every RPC with the service key: run as that role so missing grants fail here, not in production.
set local role service_role;
do $$
declare
  adm uuid; u1 uuid; u2 uuid; r jsonb; s jsonb; pid uuid; n integer; t text; f text;
  -- Submissions are judged against the real clock (backfill = sent more than 7 days after playing), so the test
  -- plays "today" and "yesterday" in Taipei.
  today text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/FMMM/FMDD');
  yesterday text := to_char(now() at time zone 'Asia/Taipei' - interval '1 day', 'YYYY/FMMM/FMDD');
begin
  -- ---- text rules (same results as the .gs functions) ----
  if public._sf_name_norm(' 海 星　') <> '海星' or public._sf_name_norm('AmY') <> 'amy' then raise exception 'name norm'; end if;
  if public._sf_date_text('2026-10-05') <> '2026/10/5' or public._sf_date_text('2026/2/30') <> '2026/3/2'
     or public._sf_date_text(' 2026 / 1 / 9 ') <> '2026/1/9' or public._sf_date_text('2026/10') <> '2026/10/1'
     or public._sf_date_text('abc') <> 'abc' or public._sf_parse_play_date('26/1/2') <> '1926-01-02' then
    raise exception 'date text %', public._sf_date_text('2026/2/30'); end if;
  -- 2026/10/5 is a Monday, 10/10 a Saturday, 10/11 a Sunday.
  if not public._sf_is_double_day('2026-10-05','2026/10/5','平日') or public._sf_is_double_day('2026-10-10','2026/10/10','平日')
     or not public._sf_is_double_day('2026-10-10','2026/10/10','假日') or not public._sf_is_double_day('2026-10-06','2026/10/6','週二、星期三')
     or not public._sf_is_double_day('2026-10-11','2026/10/11','0') or public._sf_is_double_day('2026-10-11','2026/10/11','7')
     or not public._sf_is_double_day('2026-10-09','2026/10/9','2026-10-09') or public._sf_is_double_day(null,'abc','平日')
     or public._sf_is_double_day('2026-10-05','2026/10/5','') then
    raise exception 'double day'; end if;
  if public._sf_char_count(' 一二 三 ') <> 3 then raise exception 'char count'; end if;

  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000006b01','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000006b02','老玩家','active') returning id into u1;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000006b03','新玩家','active') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  -- New submissions must name a script from the catalog (games.review_key).
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key)
    select 'pr-test-'||lower(k), 'pr-test '||k, 1, 8, 0, k from unnest(array['X','Y','Y2','Y3','Y4','Z','W','V','Q']) k;

  -- ---- before cutover: the website keeps using the Apps Script ----
  if (select source from public.record_state) <> 'gas' then raise exception 'default source'; end if;
  if public.public_records_payload() is not null or public.record_names() is not null or public.public_play_records() is not null then
    raise exception 'payload served before cutover'; end if;
  begin
    perform public.submit_play_record('{"name":"A","date":"2026/10/5","script":"S","role":"R","rating":"5"}');
    raise exception 'accepted before cutover';
  exception when others then if sqlerrm <> 'RECORDS_NOT_LIVE' then raise; end if;
  end;
  begin perform public.admin_set_records_source(adm,'supabase'); raise exception 'switched without import';
  exception when others then if sqlerrm <> 'IMPORT_REQUIRED' then raise; end if; end;
  begin perform public.admin_import_play_records(u1,'{"responses":[],"ledger":[]}'); raise exception 'player imported';
  exception when others then if sqlerrm <> 'NOT_ADMIN' then raise; end if; end;

  -- ---- import (the spreadsheet as the Apps Script left it) ----
  -- 舊玩家「阿明」（別名 Ming）、「小美」；阿明 9/1 玩 X（心得長、首玩首探新手）、同日再填一次（重複）；
  -- 小美 9/2 填 X 並寫介紹人 Ming；帳本：兩筆計點、介紹兩列、任務、讚＋精選合併的一列、LINE 回歸禮、手動兌換（神秘盒）、作廢一列。
  r := public.admin_import_play_records(adm, jsonb_build_object(
    'config', jsonb_build_array(jsonb_build_object('key','雙倍日','value',''), jsonb_build_object('key','LINE上線日','value','2026/10/01'),
      jsonb_build_object('key','基本點數','value','10'), jsonb_build_object('key','不存在的設定','value','1')),
    'rewards', jsonb_build_array(jsonb_build_object('track','保底','name','折抵 50 元','cost',50,'note','直接折抵','active',true),
      jsonb_build_object('track','特權','name','下架品','cost',80,'note','','active',false)),
    'quests', jsonb_build_array(jsonb_build_object('id','場次','label','本月完成 {目標} 場','goal',3,'points',20,'active',true),
      jsonb_build_object('id','揪團','label','本月介紹 {目標} 位新朋友','goal',1,'points',30,'active',true)),
    'players', jsonb_build_array(
      jsonb_build_object('name','阿明','aliases',jsonb_build_array('Ming','阿明'),'agent','#001','joined','2026/9/1','gilded',true,'title','解謎王','legend',false),
      jsonb_build_object('name','小美','aliases',jsonb_build_array(),'agent','#002','joined','2026/9/2'),
      jsonb_build_object('name',' 小美 ','aliases',jsonb_build_array())),
    'responses', jsonb_build_array(
      jsonb_build_object('key',repeat('1',64),'stamp','2026-09-01T12:00:00Z','name','阿明','date','2026/9/1','script','X','role','偵探','rating','5','comment','這是一段超過十五個字的心得內容真的很好玩','referrer',''),
      jsonb_build_object('key',repeat('2',64),'stamp','2026-09-01T12:05:00Z','name','ming','date','2026/9/1','script','X','role','偵探','rating','4','comment','','referrer',''),
      jsonb_build_object('key',repeat('3',64),'stamp','2026-09-02T12:00:00Z','name','小美','date','2026/9/2','script','X','role','兇手','rating','5','comment','短','referrer','Ming'),
      jsonb_build_object('key',repeat('4',64),'stamp','2026-09-03T12:00:00Z','name','','date','2026/9/3','script','X'),
      -- No 時間戳記 (typed by hand long ago): never 補登, as in the Apps Script.
      jsonb_build_object('key',repeat('7',64),'stamp',null,'name','老手','date','2025/1/1','script','S0','role','甲','rating','5')),
    'ledger', jsonb_build_array(
      jsonb_build_object('player','阿明','type','earn','points',50,'detail','基本10＋心得5＋首玩5＋首探10＋新手好運20','script','X','date','2026/9/1','source','表單','status','有效','key','阿明|X|2026/9/1'),
      jsonb_build_object('player','阿明','type','skip','points',0,'detail','','script','X','date','2026/9/1','source','表單','status','有效','note','重複記錄','key','阿明|X|2026/9/1'),
      jsonb_build_object('player','小美','type','earn','points',35,'detail','基本10＋首玩5＋新手好運20','script','X','date','2026/9/2','source','表單','status','有效','key','小美|X|2026/9/2'),
      jsonb_build_object('player','小美','type','earn','points',10,'detail','被介紹10','script','X','date','2026/9/2','source','表單','status','有效','note','介紹人：Ming','key','小美|X|2026/9/2'),
      jsonb_build_object('player','阿明','type','earn','points',10,'detail','介紹新玩家10','script','X','date','2026/9/2','source','表單','status','有效','note','介紹了：小美','key','小美|X|2026/9/2|ref'),
      jsonb_build_object('player','阿明','type','earn','points',30,'detail','本月介紹 1 位新朋友 +30','script','','date','2026/09','source','任務','status','有效','key','quest|阿明|2026/09|揪團'),
      jsonb_build_object('player','阿明','type','earn','points',26,'detail','心得獲讚6＋精選心得20','script','X','date','2026/9/1','source','心得讚','status','有效','note','3 個讚','key','like|阿明|X|2026/9/1'),
      jsonb_build_object('player','阿明','type','bonus','points',50,'detail','老玩家回歸禮（LINE 綁定）','script','','date','','source','LINE','status','有效','key','return-bonus|阿明'),
      jsonb_build_object('player','小美','type','redeem','points',-30,'detail','神秘盒','script','','date','2026/9/5','source','手動','status','有效','note','開出：免費飲料一杯','key',''),
      jsonb_build_object('player','小美','type','adjust','points',99,'detail','打錯','script','','date','2026/9/5','source','手動','status','作廢','key',''),
      jsonb_build_object('player','路人','type','adjust','points',5,'detail','手動補點','script','','date','2026/9/6','source','手動','status','有效','key',''),
      -- 歸戶名 left blank: the Apps Script does not count the row at all.
      jsonb_build_object('name','路人乙','player','','type','redeem','points',-7,'detail','手動','script','','date','2026/9/6','source','手動','status','有效','key','')),
    'interactions', jsonb_build_array(jsonb_build_object('script','X','date','2026/9/1','author','阿明','likes',3,'featured',true,'updated','2026-09-03T00:00:00Z'))));
  if (r->>'records')::int <> 4 or (r->>'players')::int <> 4 then raise exception 'import counts %', r; end if;
  if (select status from public.play_records where name='老手') <> 'earn' then raise exception 'stampless row became backfill'; end if;
  if not exists(select 1 from jsonb_array_elements(r->'anomalies') a where a->>'type'='ledger_row_without_account' and a->>'name'='路人乙')
     or exists(select 1 from public.record_players where name='路人乙') then raise exception 'ledger row without 歸戶名 %', r->'anomalies'; end if;
  if not exists(select 1 from jsonb_array_elements(r->'anomalies') a where a->>'type'='duplicate_player')
     or not exists(select 1 from jsonb_array_elements(r->'anomalies') a where a->>'type'='ledger_only_player' and a->>'name'='路人') then
    raise exception 'anomalies %', r->'anomalies'; end if;
  -- Settings: the sheet overrides, unknown keys dropped, defaults kept.
  if (public._sf_record_config()->>'心得點數')::int <> 5 or public._sf_record_config()->>'雙倍日' <> '' or exists(select 1 from public.record_settings where key='不存在的設定') then
    raise exception 'config'; end if;
  -- Replay: 'ming' is 阿明 by alias and the second 9/1 X row is a duplicate; 小美's referral by alias stands.
  select id into pid from public.record_players where name='阿明';
  if (select count(*) from public.play_records where player_id=pid) <> 2
     or (select count(*) from public.play_records where player_id=pid and status='duplicate') <> 1
     or (select referrer_id from public.play_records where name='小美') <> pid then raise exception 'replay'; end if;
  if (select points from public.play_records where name='小美') <> 45 then raise exception 'record points from ledger'; end if;
  -- Ledger as-is, with keys that stop the same thing being paid twice after the cutover.
  if not exists(select 1 from public.point_ledger where dedupe_key='quest|'||pid||'|2026-09|揪團')
     or not exists(select 1 from public.point_ledger where dedupe_key='bonus|return|'||pid)
     or (select points from public.point_ledger where kind='featured') <> 20 or (select points from public.point_ledger where kind='like') <> 6
     or (select count(*) from public.point_ledger where voided_at is not null) <> 1 then raise exception 'ledger import'; end if;

  -- The summary is the Apps Script's 點數總覽, computed from the ledger.
  s := (select x from jsonb_array_elements(public._sf_records_summary()) x where x->>'name'='阿明');
  if (s->>'earned')::int <> 166 or (s->>'balance')::int <> 166 or (s->>'plays')::int <> 1 or s->>'last' <> '2026/9/1'
     or s->>'agent' <> '#001' or not (s->>'gilded')::boolean or s->>'title' <> '解謎王' then raise exception 'summary 阿明 %', s; end if;
  s := (select x from jsonb_array_elements(public._sf_records_summary()) x where x->>'name'='小美');
  if (s->>'earned')::int <> 45 or (s->>'redeemed')::int <> 30 or (s->>'balance')::int <> 15 then raise exception 'summary 小美 %', s; end if;
  s := public._sf_records_payload();
  if jsonb_array_length(s->'rewards') <> 1 or s->'mystery'->0->>'prize' <> '免費飲料一杯' or s->'quests'->0->>'label' <> '本月完成 3 場'
     or jsonb_array_length(s->'interactions') <> 1 or s->>'doubleDayNote' <> '平日開本，點數兩倍'
     or exists(select 1 from jsonb_array_elements(s->'rules') x where x ? 'multiplier') then raise exception 'payload %', s; end if;

  -- ---- reconcile against the Apps Script's last summary ----
  insert into public.play_record_snapshot(id,payload,fetched_at) values (1, jsonb_build_object('ok',true,'summary',public._sf_records_summary()), now())
    on conflict (id) do update set payload=excluded.payload, fetched_at=excluded.fetched_at;
  if not (public.admin_records_reconcile(adm)->>'matched')::boolean then raise exception 'reconcile should match'; end if;
  -- The Apps Script writes a date cell as String(date); the same day still matches (0038).
  update public.play_record_snapshot set payload = jsonb_set(payload, '{summary}', (select jsonb_agg(case when x->>'name'='阿明'
      then x || '{"last":"Tue Sep 01 2026 00:00:00 GMT+0800 (台湾標準時)"}' else x end) from jsonb_array_elements(payload->'summary') x));
  if not (public.admin_records_reconcile(adm)->>'matched')::boolean then raise exception 'reconcile: Apps Script date text'; end if;
  update public.play_record_snapshot set payload = jsonb_set(payload, '{summary}', (select jsonb_agg(case when x->>'name'='阿明'
      then x || '{"last":"Wed Sep 02 2026 00:00:00 GMT+0800 (台湾標準時)"}' else x end) from jsonb_array_elements(payload->'summary') x));
  if (public.admin_records_reconcile(adm)->>'matched')::boolean then raise exception 'reconcile: another day must differ'; end if;
  update public.play_record_snapshot set payload = jsonb_build_object('ok',true,'summary',public._sf_records_summary());
  update public.play_record_snapshot set payload = jsonb_set(payload, '{summary,0,balance}', '999');
  r := public.admin_records_reconcile(adm);
  if (r->>'matched')::boolean or jsonb_array_length(r->'differences') <> 1 then raise exception 'reconcile diff %', r; end if;
  begin perform public.admin_set_records_source(adm,'supabase'); raise exception 'switched with differences';
  exception when others then if sqlerrm <> 'RECONCILE_MISMATCH' then raise; end if; end;
  update public.play_record_snapshot set payload = jsonb_build_object('ok',true,'summary',public._sf_records_summary());
  -- The first switch only trusts an Apps Script summary read in the last 10 minutes (the api re-reads it first).
  update public.play_record_snapshot set fetched_at = now() - interval '1 hour';
  begin perform public.admin_set_records_source(adm,'supabase'); raise exception 'switched on an old summary';
  exception when others then if sqlerrm <> 'RECONCILE_STALE' then raise; end if; end;
  update public.play_record_snapshot set fetched_at = now();

  -- ---- cutover ----
  r := public.admin_set_records_source(adm,'supabase');
  if r->>'source' <> 'supabase' or public.public_records_payload() is null then raise exception 'cutover'; end if;
  begin perform public.admin_import_play_records(adm,'{"responses":[],"ledger":[]}'); raise exception 'reimport after cutover';
  exception when others then if sqlerrm <> 'RECORDS_LIVE' then raise; end if; end;
  begin delete from public.point_ledger where kind='adjust'; raise exception 'ledger delete after cutover';
  exception when others then if sqlerrm <> 'LEDGER_APPEND_ONLY' then raise; end if; end;
  begin update public.point_ledger set points=1 where kind='adjust'; raise exception 'ledger edit';
  exception when others then if sqlerrm <> 'LEDGER_APPEND_ONLY' then raise; end if; end;

  -- ---- website submissions, fixed at submit time ----
  -- New player 阿華 today: 基本10, short comment, 首玩5 首探10 (script Y is new), 新手好運20; referred by 小美.
  r := public.submit_play_record(jsonb_build_object('name',' 阿華 ','date',today,'script','Y','role','A','rating','5','comment','短','referrer','小美'),
    '00000000-0000-4000-8000-000000000001');
  if r->>'status' <> 'earn' or (r->'award'->>'points')::int <> 45 or r->'award'->>'detail' <> '基本10＋首玩5＋首探10＋新手好運20' then
    raise exception 'new player award %', r; end if;
  select id into pid from public.record_players where name='阿華';
  if (select agent from public.record_players where id=pid) <> '#004' then raise exception 'agent number'; end if;  -- #003 is 老手 (replayed)
  -- Referral by an existing player: both +10, not doubled; 小美 completes 揪團 for this month (+30, once).
  if (select sum(points) from public.point_ledger where player_id=pid) <> 55
     or (select count(*) from public.point_ledger l join public.record_players p on p.id=l.player_id where p.name='小美' and l.kind in ('referrer','quest')) <> 2 then
    raise exception 'referral'; end if;
  -- The same submission resent: recognised, nothing added.
  r := public.submit_play_record(jsonb_build_object('name','阿華','date',today,'script','Y','role','A','rating','5'), '00000000-0000-4000-8000-000000000001');
  if not (r->>'duplicate')::boolean or (select count(*) from public.play_records where player_id=pid) <> 1 then raise exception 'idempotent %', r; end if;
  -- Same player, script, day again: recorded, 0 points.
  r := public.submit_play_record(jsonb_build_object('name','阿華','date',today,'script','Y','role','A','rating','4'));
  if r->>'status' <> 'duplicate' or r->'award' <> 'null'::jsonb then raise exception 'duplicate %', r; end if;
  -- Daily cap 3: two more scripts count (Y2 with a 15-character comment, Y3), the fourth is capped.
  r := public.submit_play_record(jsonb_build_object('name','阿華','date',today,'script','Y2','role','A','rating','4','comment','一二三四五 六七八九十一二三四五'));
  if (r->'award'->>'points')::int <> 30 then raise exception 'comment + firsts %', r; end if;
  perform public.submit_play_record(jsonb_build_object('name','阿華','date',today,'script','Y3','role','A','rating','4'));
  r := public.submit_play_record(jsonb_build_object('name','阿華','date',today,'script','Y4','role','A','rating','4'));
  if r->>'status' <> 'daily_cap' then raise exception 'daily cap %', r; end if;
  -- 場次 quest: 3 counted plays this month → +20 once (the capped one does not count).
  if (select count(*) from public.point_ledger where player_id=pid and kind='quest') <> 1 then raise exception 'quest once'; end if;
  -- Playing a script again on another day: base points only; the quest is not paid again.
  r := public.submit_play_record(jsonb_build_object('name','阿華','date',yesterday,'script','Y','role','A','rating','4'));
  if (r->'award'->>'points')::int <> 10 then raise exception 'second play %', r; end if;
  if (select count(*) from public.point_ledger where player_id=pid and kind='quest') <> 1 then raise exception 'quest paid twice'; end if;
  -- Backfill: played more than 7 days before sending (after LINE上線日): recorded, 0 points, takes no firsts.
  r := public.submit_play_record('{"name":"新人","date":"2026/1/1","script":"Z","role":"A","rating":"4"}');
  if r->>'status' <> 'backfill' or exists(select 1 from public.point_ledger l join public.record_players p on p.id=l.player_id where p.name='新人') then
    raise exception 'backfill %', r; end if;
  if not (public.submit_play_record(jsonb_build_object('name','新人三','date',today,'script','Z','role','A','rating','4'))->'award'->>'detail') like '%首探%' then
    raise exception 'a backfilled record took 首探'; end if;
  -- An unknown referrer earns nothing (new rule), and neither does a self-referral.
  perform public.submit_play_record(jsonb_build_object('name','新人二','date',today,'script','Y','role','A','rating','4','referrer','不存在'));
  perform public.submit_play_record(jsonb_build_object('name','自己','date',today,'script','Y','role','A','rating','4','referrer',' 自 己'));
  if exists(select 1 from public.point_ledger where kind in ('referred','referrer') and player_id in
      (select id from public.record_players where name in ('新人二','自己','不存在'))) or exists(select 1 from public.record_players where name='不存在') then
    raise exception 'unknown or self referrer'; end if;
  -- Double day: changing the setting only affects new points.
  insert into public.record_settings(key,value) values ('雙倍日',today) on conflict (key) do update set value=excluded.value;
  r := public.submit_play_record(jsonb_build_object('name','雙倍君','date',today,'script','W','role','A','rating','4'));
  if (r->'award'->>'points')::int <> 90 or r->'award'->>'detail' not like '%雙倍日 x2' then raise exception 'double day %', r; end if;
  if (select points from public.point_ledger where kind='record' and player_id=pid order by created_at limit 1) <> 45 then raise exception 'old points changed'; end if;
  -- Validation like validate_.
  foreach t in array array['{"name":"","date":"2026/10/3","script":"Y","role":"A","rating":"5"}','{"name":"A","date":"2026/10/3","script":"Y","role":"A","rating":"6"}',
      '{"name":"A","date":"","script":"Y","role":"A","rating":"5"}','{"name":"A","date":"2026/10/3","script":"Y","role":"","rating":"5"}'] loop
    begin perform public.submit_play_record(t::jsonb); raise exception 'invalid accepted %', t;
    exception when others then if sqlerrm <> 'INVALID_RECORD' then raise; end if; end;
  end loop;
  -- New rules (points are fixed now, no store review): a script outside the catalog, a date in the future or one that
  -- cannot be read would farm 首探／首玩 and reset the daily cap.
  foreach t in array array[jsonb_build_object('name','A','date',today,'script','亂填的劇本','role','A','rating','5')::text,
      jsonb_build_object('name','A','date',to_char(now() at time zone 'Asia/Taipei' + interval '1 day','YYYY/FMMM/FMDD'),'script','Y','role','A','rating','5')::text,
      '{"name":"A","date":"昨天","script":"Y","role":"A","rating":"5"}'] loop
    begin perform public.submit_play_record(t::jsonb); raise exception 'invalid accepted %', t;
    exception when others then if sqlerrm <> 'INVALID_RECORD' then raise; end if; end;
  end loop;
  -- The reply carries the canonical name only inside the database (the api drops it); a catalog name with other spacing is fine.
  if public.submit_play_record(jsonb_build_object('name','空白君','date',today,'script',' Y 2 ','role','A','rating','5'))->>'status' <> 'earn' then
    raise exception 'catalog match ignores spaces'; end if;

  -- ---- likes ----
  r := public.submit_review_like('Y',today,'阿華','00000000-0000-4000-8000-0000000000a1');
  if (r->>'likes')::int <> 1 then raise exception 'like %', r; end if;
  r := public.submit_review_like('Y',replace(today,'/','-'),'阿華','00000000-0000-4000-8000-0000000000a1');
  if not (r->>'duplicate')::boolean then raise exception 'same browser liked twice'; end if;
  for n in 2..7 loop
    perform public.submit_review_like('Y',today,' 阿 華',('00000000-0000-4000-8000-0000000000b'||n)::uuid);
  end loop;
  if (select sum(points) from public.point_ledger where kind='like' and player_id=pid) <> 10 then raise exception 'like cap'; end if;
  -- 阿明's imported review already has 6 like points: two more likes reach the cap of 10.
  for n in 1..3 loop perform public.submit_review_like('X','2026/9/1','阿明',('00000000-0000-4000-8000-0000000000c'||n)::uuid); end loop;
  if (select sum(l.points) from public.point_ledger l join public.review_interactions i on i.id=l.interaction_id
      where i.author='阿明' and l.kind='like') <> 10 then raise exception 'like cap with imported likes'; end if;
  begin perform public.submit_review_like('X','2026/9/1','沒這個人','00000000-0000-4000-8000-0000000000d1'); raise exception 'like on nothing';
  exception when others then if sqlerrm <> 'REVIEW_NOT_FOUND' then raise; end if; end;
  perform public.submit_review_like('Z','2026/1/1','新人','00000000-0000-4000-8000-0000000000e1');
  if exists(select 1 from public.point_ledger l join public.record_players p on p.id=l.player_id where p.name='新人') then
    raise exception 'backfill review earned like points'; end if;

  -- ---- 回歸禮 ----
  insert into public.player_bindings(user_id,record_name,status) values (u1,'小美','approved');
  r := public.grant_record_return_bonus(u1, 50);
  if r->>'bonus_status' <> 'granted' or not exists(select 1 from public.point_ledger l join public.record_players p on p.id=l.player_id
      where p.name='小美' and l.kind='bonus' and l.points=50 and l.earned_on is null) then raise exception 'bonus %', r; end if;
  update public.player_bindings set bonus_status='none' where user_id=u1;
  if public.grant_record_return_bonus(u1, 50)->>'bonus_status' <> 'already' then raise exception 'bonus twice'; end if;
  insert into public.player_bindings(user_id,record_name,status) values (u2,'阿華','approved');
  if public.grant_record_return_bonus(u2, 50)->>'bonus_status' <> 'ineligible' then raise exception 'new player got bonus'; end if;

  -- ---- LINE names / card / taken ----
  if not public.record_name_taken('ming') or not public.record_name_taken(' 阿 華') or public.record_name_taken('沒人用') then raise exception 'taken'; end if;
  if (public.record_card('小美')->'card'->>'balance')::int <> 105 then raise exception 'card %', public.record_card('小美'); end if;
  if not exists(select 1 from jsonb_array_elements(public.record_names()) x where x->>'name'='阿明' and x->>'agent'='#001') then raise exception 'names'; end if;
  if jsonb_array_length(public.public_play_records('Y')) < 1 or public.public_play_records('Y')->0 ? 'referrer' then raise exception 'public records'; end if;

  -- ---- catch-up import after the cutover (website fell back to the Apps Script) ----
  r := public.admin_import_new_play_records(adm, jsonb_build_array(
    jsonb_build_object('key',repeat('5',64),'stamp','2026-08-01T00:00:00Z','name','舊','date','2026/8/1','script','X'),
    jsonb_build_object('key',repeat('6',64),'stamp',to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"'),'name','補進來','date',today,'script','V','role','A','rating','5'),
    jsonb_build_object('key',repeat('1',64),'stamp','2026-09-01T12:00:00Z','name','阿明','date','2026/9/1','script','X'),
    jsonb_build_object('key',repeat('8',64),'stamp',to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"'),'name','亂','date',today,'script','不在目錄','role','A','rating','5')));
  if (r->>'added')::int <> 1 or (r->>'skipped')::int <> 2 or (r->>'failed')::int <> 1 then raise exception 'catch-up %', r; end if;
  s := public.admin_records_status(adm);
  if (s->'catchUpResult'->>'failed')::int <> 1 or s->'catchUpResult'->>'by' <> 'store' or s->>'catchUpAt' is null then
    raise exception 'catch-up result shown %', s; end if;
  perform public.system_records_catch_up_failed('SHEET_FORBIDDEN');
  if public.admin_records_status(adm)->'catchUpResult'->>'error' <> 'SHEET_FORBIDDEN' then raise exception 'catch-up error shown'; end if;
  if (public.admin_import_new_play_records(adm, jsonb_build_array(jsonb_build_object('key',repeat('6',64),'stamp',to_char(now(),'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'name','補進來','date',today,'script','V')))->>'added')::int <> 0 then raise exception 'catch-up twice'; end if;

  -- ---- emergency switch back: no full re-import (it would delete everything since the cutover); back again without reconcile ----
  perform public.admin_set_records_source(adm,'gas');
  begin perform public.submit_play_record(jsonb_build_object('name','A','date',today,'script','Y','role','R','rating','5'));
    raise exception 'accepted after switching back';
  exception when others then if sqlerrm <> 'RECORDS_NOT_LIVE' then raise; end if; end;
  begin perform public.admin_import_play_records(adm,'{"responses":[],"ledger":[]}'); raise exception 'reimport after switching back';
  exception when others then if sqlerrm <> 'RECORDS_WENT_LIVE' then raise; end if; end;
  begin delete from public.point_ledger where kind='adjust'; raise exception 'ledger delete after switching back';
  exception when others then if sqlerrm <> 'LEDGER_APPEND_ONLY' then raise; end if; end;
  update public.play_record_snapshot set payload = jsonb_set(payload, '{summary,0,balance}', '999');  -- would not reconcile
  r := public.admin_set_records_source(adm,'supabase');
  if r->>'source' <> 'supabase' or r->>'wentLiveAt' is null then raise exception 'back to supabase %', r; end if;
  if (select count(*) from public.play_records where source='web') < 10 then raise exception 'records kept'; end if;

  -- ---- flood guard ----
  for n in 1..40 loop
    begin
      perform public.submit_play_record(jsonb_build_object('name','灌'||n,'date',today,'script','Q','role','A','rating','5'));
    exception when others then if sqlerrm = 'TOO_MANY_REQUESTS' then exit; else raise; end if;
    end;
  end loop;
  if (select count(*) from public.play_records where source='web' and submitted_at > now()-interval '10 minutes') <> 30 then
    raise exception 'flood guard'; end if;

  -- ---- privileges ----
  foreach t in array array['record_state','record_settings','record_rewards','record_quests','record_players','record_aliases','play_records',
      'review_interactions','review_likes','point_ledger'] loop
    if not (select relrowsecurity from pg_class where oid=('public.'||t)::regclass) then raise exception 'RLS off on %', t; end if;
    foreach f in array array['anon','authenticated'] loop
      if has_table_privilege(f,'public.'||t,'SELECT') or has_table_privilege(f,'public.'||t,'INSERT') then raise exception '% exposed to %', t, f; end if;
    end loop;
  end loop;
  foreach t in array array['public.submit_play_record(jsonb,uuid)','public.submit_review_like(text,text,text,uuid)',
      'public.public_records_payload()','public.admin_import_play_records(uuid,jsonb)','public.admin_set_records_source(uuid,text,boolean)'] loop
    if has_function_privilege('anon',t,'EXECUTE') or has_function_privilege('authenticated',t,'EXECUTE') then raise exception '% exposed', t; end if;
    if not has_function_privilege('service_role',t,'EXECUTE') then raise exception '% not granted', t; end if;
  end loop;
  -- Internals stay callable by service_role (the public RPCs run as their caller), never by anon/authenticated.
  foreach t in array array['public._sf_add_play_record(jsonb,text,timestamptz,boolean)','public._sf_import_play_records(uuid,jsonb)',
      'public._sf_records_lock()','public._sf_records_payload()'] loop
    if has_function_privilege('anon',t,'EXECUTE') or has_function_privilege('authenticated',t,'EXECUTE') then
      raise exception 'internal function % exposed', t; end if;
    if not has_function_privilege('service_role',t,'EXECUTE') then raise exception 'internal function % not granted', t; end if;
  end loop;
end $$;
reset role;
select 'PASS: Apps Script rules fixed at submit time (duplicate, daily cap, backfill, firsts, double day, referral, quests, likes, return bonus), import as-is, reconcile, cutover, catch-up import, flood guard, privileges' as result;
rollback;
