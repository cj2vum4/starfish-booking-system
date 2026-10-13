-- Run in Supabase SQL Editor after 202610130039_store_points.sql. All synthetic records are rolled back.
-- Stage 3: redemption requests (held, approved by the store, glory track), direct redemption, adjustments, voiding,
-- hiding a record (and undoing it), featured reviews, aliases, merging two names, settings, rewards, quests, monthly report.
begin;
set local role service_role;
do $$
declare
  adm uuid; u1 uuid; u2 uuid; r jsonb; s jsonb; rid uuid; rec_a uuid; rec_b uuid; rw_50 uuid; rw_gold uuid; rw_title uuid; rw_legend uuid;
  n integer; t text;
  today text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/FMMM/FMDD');
  month_key text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/MM');
  bal integer;
begin
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000007d01','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000007d02','小美','active') returning id into u1;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000007d03','路人','active') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key)
    values ('st-test-a','st-test A',1,8,0,'SA'), ('st-test-b','st-test B',1,8,0,'SB'), ('st-test-c','st-test C',1,8,0,'SC');
  insert into public.record_rewards(sort,track,name,cost,note) values (1,'保底','折抵 50 元',50,''),
    (2,'榮耀','榮譽牆名字鍍金',100,''), (3,'榮耀','自訂專屬稱號',200,''), (4,'榮耀','傳奇殿堂留名',500,'');
  select id into rw_50 from public.record_rewards where name='折抵 50 元';
  select id into rw_gold from public.record_rewards where name='榮譽牆名字鍍金';
  select id into rw_title from public.record_rewards where name='自訂專屬稱號';
  select id into rw_legend from public.record_rewards where name='傳奇殿堂留名';

  -- ---- before the cutover the sheet is the source: no store writes, the member card says not live ----
  begin perform public.admin_adjust_points(adm,'小美',5,'x'); raise exception 'store wrote before cutover';
  exception when others then if sqlerrm <> 'RECORDS_NOT_LIVE' then raise; end if; end;
  if (public.my_redemptions(u1)->>'live')::boolean then raise exception 'redemption live before cutover'; end if;

  update public.record_state set source='supabase', went_live_at=now() where id;
  insert into public.record_settings(key,value) values ('雙倍日','') on conflict (key) do update set value='';
  -- 小美: SA 10+5+5+10+20 = 50, SB 10+5+5+10 = 30 → 80. 阿華: SC 10+5+10+20 = 45 (no comment points).
  rec_a := (public.submit_play_record(jsonb_build_object('name','小美','date',today,'script','SA','role','A','rating','5',
    'comment','這是一段超過十五個字的心得內容真的很好玩')))->>'id';
  rec_b := (public.submit_play_record(jsonb_build_object('name','小美','date',today,'script','SB','role','A','rating','5',
    'comment','這也是一段超過十五個字的心得內容很推薦')))->>'id';
  perform public.submit_play_record(jsonb_build_object('name','阿華','date',today,'script','SC','role','A','rating','4'));
  if public._sf_balance(public._sf_find_player('小美')) <> 80 then raise exception 'setup balance %', public._sf_balance(public._sf_find_player('小美')); end if;
  insert into public.player_bindings(user_id,record_name,status) values (u1,'小美','approved');

  -- ---- 補點／扣點 ----
  r := public.admin_adjust_points(adm,'小美',200,'活動補點','adj-1');
  if (r->>'balance')::int <> 280 then raise exception 'adjust %', r; end if;
  r := public.admin_adjust_points(adm,'小美',200,'活動補點','adj-1');
  if (r->>'balance')::int <> 280 or not (r->>'duplicate')::boolean then raise exception 'adjust twice %', r; end if;
  foreach t in array array['0|x','2000|x','5|'] loop
    begin perform public.admin_adjust_points(adm,'小美',split_part(t,'|',1)::int,split_part(t,'|',2));
      raise exception 'bad adjust accepted %', t;
    exception when others then if sqlerrm not in ('INVALID_POINTS','INVALID_REASON') then raise; end if; end;
  end loop;
  begin perform public.admin_adjust_points(u1,'小美',5,'x'); raise exception 'player adjusted';
  exception when others then if sqlerrm <> 'NOT_ADMIN' then raise; end if; end;
  begin perform public.admin_adjust_points(adm,'沒這個人',5,'x'); raise exception 'unknown player';
  exception when others then if sqlerrm <> 'NAME_NOT_FOUND' then raise; end if; end;

  -- ---- 玩家申請兌換：保留點數，店家核准才扣 ----
  begin perform public.request_redemption(u2, rw_50); raise exception 'unbound player requested';
  exception when others then if sqlerrm <> 'BINDING_REQUIRED' then raise; end if; end;
  r := public.request_redemption(u1, rw_gold);
  rid := r->>'id';
  if r->>'status' <> 'pending' or (r->>'held')::int <> 100 or (r->>'balance')::int <> 280 then raise exception 'request %', r; end if;
  if not exists(select 1 from public.notification_logs where user_id=adm and notification_type='redemption_requested'
      and payload->>'reward'='榮譽牆名字鍍金') then raise exception 'store not notified'; end if;
  begin perform public.request_redemption(u1, rw_title, ''); raise exception 'title missing';
  exception when others then if sqlerrm <> 'INVALID_TITLE' then raise; end if; end;
  begin perform public.request_redemption(u1, rw_title, '解謎王'); raise exception 'held points spent twice';
  exception when others then if sqlerrm <> 'NOT_ENOUGH_POINTS' then raise; end if; end;
  r := public.request_redemption(u1, rw_50, '', 'req-50');
  if (public.request_redemption(u1, rw_50, '', 'req-50')->>'id') <> r->>'id' then raise exception 'request resent twice'; end if;
  begin perform public.cancel_redemption(u2, (r->>'id')::uuid); raise exception 'cancelled someone else''s';
  exception when others then if sqlerrm <> 'REDEMPTION_NOT_FOUND' then raise; end if; end;
  r := public.cancel_redemption(u1, (r->>'id')::uuid);
  if r->>'status' <> 'cancelled' or (r->>'held')::int <> 100 then raise exception 'cancel %', r; end if;
  r := public.my_redemptions(u1);
  if (r->>'held')::int <> 100 or jsonb_array_length(r->'requests') <> 2
     or not exists(select 1 from jsonb_array_elements(r->'rewards') x where (x->>'id')::uuid = rw_title) then
    raise exception 'my redemptions %', r; end if;
  r := public.admin_redemptions(adm);
  if jsonb_array_length(r->'pending') <> 1 or jsonb_array_length(r->'recent') <> 1 then raise exception 'store list %', r; end if;

  r := public.admin_decide_redemption(adm, rid, true);
  if r->>'status' <> 'approved' or (r->>'balance')::int <> 180 then raise exception 'approve %', r; end if;
  if not (select gilded from public.record_players where name='小美') then raise exception 'gilded not applied'; end if;
  if not exists(select 1 from public.notification_logs where user_id=u1 and notification_type='redemption_approved') then
    raise exception 'player not told'; end if;
  begin perform public.admin_decide_redemption(adm, rid, false); raise exception 'decided twice';
  exception when others then if sqlerrm <> 'REDEMPTION_DECIDED' then raise; end if; end;
  if (public._sf_records_summary()->0->>'gilded')::boolean is not true and not exists(select 1 from jsonb_array_elements(public._sf_records_summary()) x
      where x->>'name'='小美' and (x->>'gilded')::boolean and (x->>'redeemed')::int = 100) then raise exception 'summary after redeem'; end if;

  -- Rejected: nothing deducted; the player hears why.
  r := public.request_redemption(u1, rw_50);
  r := public.admin_decide_redemption(adm, (r->>'id')::uuid, false, '', '這週沒有開本');
  if r->>'status' <> 'rejected' or (r->>'balance')::int <> 180 or r->>'store_note' <> '這週沒有開本' then raise exception 'reject %', r; end if;
  if not exists(select 1 from public.notification_logs where user_id=u1 and notification_type='redemption_rejected'
      and payload->>'note'='這週沒有開本') then raise exception 'reject not told'; end if;

  -- ---- 店家直接兌換（沒綁 LINE）：自訂稱號 ----
  begin perform public.admin_redeem(adm,'小美',rw_title,'解謎王','','dir-1'); raise exception 'redeemed without points';
  exception when others then if sqlerrm <> 'NOT_ENOUGH_POINTS' then raise; end if; end;
  perform public.admin_adjust_points(adm,'小美',100,'補足','adj-2');
  r := public.admin_redeem(adm,'小美',rw_title,' 解謎王 ','到店口頭','dir-1');
  if r->>'status' <> 'approved' or (r->>'balance')::int <> 80 or (select title from public.record_players where name='小美') <> '解謎王' then
    raise exception 'direct redeem %', r; end if;
  if (public.admin_redeem(adm,'小美',rw_title,'解謎王','','dir-1')->>'balance')::int <> 80 then raise exception 'direct redeem twice'; end if;
  if exists(select 1 from public.notification_logs where notification_type like 'redemption_%' and payload->>'reward'='自訂專屬稱號') then
    raise exception 'direct redeem notified someone'; end if;

  -- ---- 作廢一筆（兌換的那筆＝退點）----
  select ledger_id into rid from public.redemption_requests where reward_name='榮譽牆名字鍍金' and status='approved';
  begin perform public.admin_void_ledger(adm, rid, ''); raise exception 'void without reason';
  exception when others then if sqlerrm <> 'INVALID_REASON' then raise; end if; end;
  if (public.admin_void_ledger(adm, rid, '按錯')->>'balance')::int <> 180 then raise exception 'void refund'; end if;
  if (select status from public.redemption_requests where ledger_id = rid) <> 'refunded' then raise exception 'refund not shown on the request'; end if;
  begin perform public.admin_void_ledger(adm, rid, '再一次'); raise exception 'voided twice';
  exception when others then if sqlerrm <> 'LEDGER_VOIDED' then raise; end if; end;

  -- ---- 隱藏惡意記錄（同時作廢點數），可取消 ----
  perform public.submit_review_like('SA', today, '小美', '00000000-0000-4000-8000-0000000000f1');  -- +2 like points → 182
  r := public.admin_hide_record(adm, rec_a, true, '亂填');
  if (r->>'ledger_rows')::int <> 2 or public._sf_balance(public._sf_find_player('小美')) <> 130 then
    raise exception 'hide % balance %', r, public._sf_balance(public._sf_find_player('小美')); end if;
  if exists(select 1 from jsonb_array_elements(public.public_play_records('SA')) x) then raise exception 'hidden record still public'; end if;
  if (select (x->>'plays')::int from jsonb_array_elements(public._sf_records_summary()) x where x->>'name'='小美') <> 1 then
    raise exception 'hidden record counted as a play'; end if;
  begin perform public.submit_review_like('SA', today, '小美', '00000000-0000-4000-8000-0000000000f2'); raise exception 'liked a hidden review';
  exception when others then if sqlerrm <> 'REVIEW_NOT_FOUND' then raise; end if; end;
  begin perform public.admin_hide_record(adm, rec_a, true); raise exception 'hidden twice';
  exception when others then if sqlerrm <> 'RECORD_HIDDEN' then raise; end if; end;
  r := public.admin_hide_record(adm, rec_a, false);
  if (r->>'ledger_rows')::int <> 2 or public._sf_balance(public._sf_find_player('小美')) <> 182
     or jsonb_array_length(public.public_play_records('SA')) <> 1 then raise exception 'unhide %', r; end if;
  perform public.admin_hide_record(adm, rec_a, true);
  perform public.admin_hide_record(adm, rec_a, false);
  if public._sf_balance(public._sf_find_player('小美')) <> 182 then raise exception 'hide/unhide twice'; end if;

  -- ---- 精選心得 ----
  if (public.admin_feature_record(adm, rec_b, true)->>'balance')::int <> 202 then raise exception 'feature'; end if;
  if (public.admin_feature_record(adm, rec_b, true)->>'balance')::int <> 202 then raise exception 'featured twice paid twice'; end if;
  if (public.admin_feature_record(adm, rec_b, false)->>'balance')::int <> 182 then raise exception 'unfeature'; end if;
  if (public.admin_feature_record(adm, rec_b, true)->>'balance')::int <> 202 then raise exception 'feature again'; end if;
  if not exists(select 1 from jsonb_array_elements(public._sf_records_payload()->'interactions') x where x->>'script'='SB' and (x->>'featured')::boolean) then
    raise exception 'featured not public'; end if;
  begin perform public.admin_feature_record(adm, (select id from public.play_records where name='阿華'), true); raise exception 'featured empty';
  exception when others then if sqlerrm <> 'NO_COMMENT' then raise; end if; end;
  r := public.admin_reviews(adm, 'SB');
  if jsonb_array_length(r) <> 1 or not (r->0->>'featured')::boolean then raise exception 'store reviews %', r; end if;

  -- ---- 別名、合併、榮耀軌 ----
  r := public.admin_set_alias(adm, '小美', '美美');
  if public._sf_find_player('美美') <> public._sf_find_player('小美') or not (r->'aliases' ? '美美') then raise exception 'alias'; end if;
  begin perform public.admin_set_alias(adm, '小美', '阿華'); raise exception 'alias of another player';
  exception when others then if sqlerrm <> 'NAME_IS_PLAYER' then raise; end if; end;
  perform public.admin_set_alias(adm, '小美', '美美', true);
  begin perform public.admin_set_alias(adm, '小美', '美美', true); raise exception 'removed twice';
  exception when others then if sqlerrm <> 'ALIAS_NOT_FOUND' then raise; end if; end;
  begin update public.point_ledger set player_id = public._sf_find_player('小美') where player_id = public._sf_find_player('阿華');
    raise exception 'ledger moved outside a merge';
  exception when others then if sqlerrm <> 'LEDGER_APPEND_ONLY' then raise; end if; end;
  begin perform public.admin_merge_players(adm, '小美', ' 小美'); raise exception 'merged with itself';
  exception when others then if sqlerrm <> 'SAME_PLAYER' then raise; end if; end;
  r := public.admin_merge_players(adm, '阿華', '小美');
  if (r->>'balance')::int <> 247 or not (r->'aliases' ? '阿華') or exists(select 1 from public.record_players where name='阿華')
     or public._sf_find_player('阿華') <> public._sf_find_player('小美') then raise exception 'merge %', r; end if;
  if (select (x->>'plays')::int from jsonb_array_elements(public._sf_records_summary()) x where x->>'name'='小美') <> 3 then
    raise exception 'merged plays'; end if;
  r := public.admin_set_glory(adm, '小美', false, '', true);
  if (r->>'gilded')::boolean or not (r->>'legend')::boolean or r->>'title' <> '' then raise exception 'glory %', r; end if;
  r := public.admin_players(adm, '小');
  if not exists(select 1 from jsonb_array_elements(r) x where x->>'name'='小美') then raise exception 'search %', r; end if;
  r := public.admin_player(adm, '阿華');
  if r->>'name' <> '小美' or jsonb_array_length(r->'ledger') < 5 or jsonb_array_length(r->'records') <> 3 or not (r->>'bound')::boolean then
    raise exception 'player detail %', r; end if;

  -- ---- 設定、獎勵、任務 ----
  r := public.admin_save_setting(adm, '基本點數', '12');
  if (public._sf_record_config()->>'基本點數')::int <> 12 then raise exception 'setting'; end if;
  foreach t in array array['基本點數|abc','基本點數|1001','不存在|1','LINE上線日|昨天'] loop
    begin perform public.admin_save_setting(adm, split_part(t,'|',1), split_part(t,'|',2)); raise exception 'bad setting %', t;
    exception when others then if sqlerrm <> 'INVALID_SETTING' then raise; end if; end;
  end loop;
  perform public.admin_save_setting(adm, 'LINE上線日', '2026-10-01');
  if (select value from public.record_settings where key='LINE上線日') <> '2026/10/1' then raise exception 'date setting'; end if;
  r := public.admin_save_reward(adm, null, '特權', '點播權', 150, '指定下個月的本', true);
  if not exists(select 1 from jsonb_array_elements(r->'rewards') x where x->>'name'='點播權' and (x->>'cost')::int=150) then raise exception 'reward add'; end if;
  perform public.admin_save_reward(adm, rw_50, '保底', '折抵 50 元', 60, '', false);
  if (select cost from public.record_rewards where id=rw_50) <> 60 or exists(select 1 from jsonb_array_elements(public._sf_records_payload()->'rewards') x
      where x->>'name'='折抵 50 元') then raise exception 'reward edit'; end if;
  begin perform public.request_redemption(u1, rw_50); raise exception 'requested an inactive reward';
  exception when others then if sqlerrm <> 'REWARD_NOT_FOUND' then raise; end if; end;
  begin perform public.admin_save_reward(adm, null, '', 'x', 0, '', true); raise exception 'free reward';
  exception when others then if sqlerrm <> 'INVALID_REWARD' then raise; end if; end;
  r := public.admin_save_quest(adm, '場次', '本月完成 {目標} 場', 3, 20, true);
  if not exists(select 1 from jsonb_array_elements(r->'quests') x where x->>'id'='場次' and (x->>'goal')::int=3) then raise exception 'quest'; end if;
  begin perform public.admin_save_quest(adm, '亂', '', 1, 1, true); raise exception 'unknown quest';
  exception when others then if sqlerrm <> 'INVALID_QUEST' then raise; end if; end;

  -- ---- 月報 ----
  r := public.admin_records_report(adm);
  s := (select x from jsonb_array_elements(r) x where x->>'month' = month_key);
  -- After the merge all three plays (SA, SB, SC today) are 小美's: one active player, one new player, three sessions.
  if s is null or (s->>'responses')::int <> 3 or (s->>'sessions')::int <> 3 or (s->>'active')::int <> 1 or (s->>'newPlayers')::int <> 1
     or (s->>'earned')::int <= 0 or (s->>'redeemed')::int <> 200 then raise exception 'report %', s; end if;

  -- ---- 權限 ----
  foreach t in array array['public.request_redemption(uuid,uuid,text,text)','public.admin_decide_redemption(uuid,uuid,boolean,text,text)',
      'public.admin_adjust_points(uuid,text,integer,text,text)','public.admin_merge_players(uuid,text,text)','public._sf_decide_redemption(uuid,uuid,boolean,text,text)',
      'public.admin_records_report(uuid)','public.my_redemptions(uuid)'] loop
    if has_function_privilege('anon',t,'EXECUTE') or has_function_privilege('authenticated',t,'EXECUTE') then raise exception '% exposed', t; end if;
    if not has_function_privilege('service_role',t,'EXECUTE') then raise exception '% not granted', t; end if;
  end loop;
  if has_table_privilege('anon','public.redemption_requests','SELECT') or not (select relrowsecurity from pg_class where oid='public.redemption_requests'::regclass) then
    raise exception 'redemption_requests exposed'; end if;
  begin perform public.admin_redemptions(u1); raise exception 'player read requests';
  exception when others then if sqlerrm <> 'NOT_ADMIN' then raise; end if; end;
end $$;

-- Review findings: hidden records do not block the real player; LINE names match exactly; a merge does not pay a
-- quest twice and keeps the old name's card; unhiding does not pay featured/likes twice.
do $$
declare
  adm uuid := (select user_id from public.admin_users limit 1); u3 uuid; r jsonb; r1 uuid; r2 uuid; t text;
  today text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/FMMM/FMDD');
  iid uuid;
begin
  -- Someone posts as "Amy" in three scripts; the store hides them. The real Amy then earns normally.
  for t in select unnest(array['SA','SB','SC']) loop
    r1 := (public.submit_play_record(jsonb_build_object('name','Amy','date',today,'script',t,'role','A','rating','5')))->>'id';
    perform public.admin_hide_record(adm, r1, true, '冒名');
  end loop;
  if public._sf_balance(public._sf_find_player('Amy')) <> 0 then raise exception 'hidden points kept'; end if;
  r := public.submit_play_record(jsonb_build_object('name','Amy','date',today,'script','SA','role','A','rating','5'));
  if r->>'status' <> 'earn' or not (select first_play from public.play_records where id = (r->>'id')::uuid) then
    raise exception 'hidden record blocked the real player %', r; end if;
  for t in select unnest(array['SB','SC']) loop
    if public.submit_play_record(jsonb_build_object('name','Amy','date',today,'script',t,'role','A','rating','5'))->>'status' <> 'earn' then
      raise exception 'hidden records counted toward the daily cap'; end if;
  end loop;

  -- A LINE name that only loosely matches a player ("AmyChen" vs "Amy Chen") does not reach that player's points.
  perform public.submit_play_record(jsonb_build_object('name','Amy Chen','date',today,'script','SA','role','A','rating','5'));
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000007d04','冒充','active') returning id into u3;
  insert into public.line_record_accounts(user_id,record_name) values (u3,'AmyChen');
  if public.my_redemptions(u3)->'player' <> 'null'::jsonb or public.record_card('AmyChen')->'card' <> 'null'::jsonb then
    raise exception 'loose LINE name reached another player'; end if;
  begin perform public.request_redemption(u3, (select id from public.record_rewards where active limit 1)); raise exception 'loose name redeemed';
  exception when others then if sqlerrm <> 'BINDING_REQUIRED' then raise; end if; end;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000007d05','陳小姐','active') returning id into u3;
  insert into public.line_record_accounts(user_id,record_name) values (u3,'陳小姐');
  begin perform public.admin_set_alias(adm, 'Amy Chen', '陳小姐'); raise exception 'alias handed a LINE account the points';
  exception when others then if sqlerrm <> 'ALIAS_HAS_LINE' then raise; end if; end;

  -- Merge: both names completed this month's 場次 quest → one stays; the old name's card shows the merged player.
  perform public.admin_save_quest(adm, '場次', '本月 {目標} 場', 1, 7, true);
  perform public.submit_play_record(jsonb_build_object('name','Q1','date',today,'script','SA','role','A','rating','5'));
  perform public.submit_play_record(jsonb_build_object('name','Q2','date',today,'script','SB','role','A','rating','5'));
  insert into public.line_record_accounts(user_id,record_name)
    values ((select id from public.users where line_user_id='U00000000000000000000000000007d03'),'Q2');
  perform public.admin_merge_players(adm, 'Q2', 'Q1');
  if (select count(*) from public.point_ledger where player_id = public._sf_find_player('Q1') and kind='quest' and voided_at is null) <> 1 then
    raise exception 'quest paid twice after a merge'; end if;
  perform public.submit_play_record(jsonb_build_object('name','Q1','date',today,'script','SC','role','A','rating','5'));
  if (select count(*) from public.point_ledger where player_id = public._sf_find_player('Q1') and kind='quest' and voided_at is null) <> 1 then
    raise exception 'quest paid again after a merge'; end if;
  if public.record_card('Q2')->'card'->>'name' <> 'Q1'
     or public.my_redemptions((select id from public.users where line_user_id='U00000000000000000000000000007d03'))->>'player' <> 'Q1' then
    raise exception 'old name lost its card after the merge'; end if;

  -- A duplicate record of the same review: hide both, unhide one, re-feature and re-like, unhide the other.
  -- Featured stays one payment and likes stay at the cap.
  r1 := (public.submit_play_record(jsonb_build_object('name','Lin','date',today,'script','SA','role','A','rating','5',
    'comment','這是一段超過十五個字的心得內容真的很好玩')))->>'id';
  r2 := (public.submit_play_record(jsonb_build_object('name','Lin','date',today,'script','SA','role','A','rating','5',
    'comment','重送一次的同一則心得內容也超過十五個字')))->>'id';
  if (select status from public.play_records where id = r2) <> 'duplicate' then raise exception 'setup duplicate'; end if;
  perform public.admin_feature_record(adm, r1, true);
  for t in select unnest(array['1','2','3','4','5']) loop
    perform public.submit_review_like('SA', today, 'Lin', ('00000000-0000-4000-8000-00000000a00'||t)::uuid); end loop;
  select id into iid from public.review_interactions where script='SA' and date_text=today and author_norm=public._sf_name_norm('Lin');
  perform public.admin_hide_record(adm, r2, true);
  perform public.admin_hide_record(adm, r1, true);
  perform public.admin_hide_record(adm, r2, false);
  perform public.admin_feature_record(adm, r2, false);
  perform public.admin_feature_record(adm, r2, true);
  for t in select unnest(array['6','7','8','9','b']) loop
    perform public.submit_review_like('SA', today, 'Lin', ('00000000-0000-4000-8000-00000000a00'||t)::uuid); end loop;
  perform public.admin_hide_record(adm, r1, false);
  if (select sum(points) from public.point_ledger where interaction_id=iid and kind='featured' and voided_at is null) <> 20
     or (select sum(points) from public.point_ledger where interaction_id=iid and kind='like' and voided_at is null) <> 10 then
    raise exception 'unhide paid twice: featured % likes %',
      (select sum(points) from public.point_ledger where interaction_id=iid and kind='featured' and voided_at is null),
      (select sum(points) from public.point_ledger where interaction_id=iid and kind='like' and voided_at is null); end if;
end $$;
reset role;
select 'PASS: stage 3 store points (redemption held/approved/rejected/direct, glory, adjust, void, hide/unhide, featured, alias, merge, settings, rewards, quests, report, privileges, review findings)' as result;
rollback;
