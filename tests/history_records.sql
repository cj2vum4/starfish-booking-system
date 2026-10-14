-- Run in Supabase SQL Editor after 202610140040_history_records.sql. All synthetic records are rolled back.
-- 我的遊戲紀錄 lists the website play records under the member card's name after the cutover: not before it, not hidden
-- or duplicate ones, not someone else's, and not a record for the same script on a day that already has an attended session.
begin;
set local role service_role;
do $$
declare
  adm uuid; u1 uuid; u2 uuid; pl uuid; ga uuid; gb uuid; ev uuid; r jsonb; rec_c uuid;
  today text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/FMMM/FMDD');
  yesterday text := to_char(now() at time zone 'Asia/Taipei' - interval '1 day', 'YYYY/FMMM/FMDD');
begin
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000004e01','店長','active') returning id into adm;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000004e02','小美','active') returning id into u1;
  insert into public.users(line_user_id,display_name,oa_friend_status) values ('U00000000000000000000000000004e03','路人','active') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key,image_url)
    values ('hr-test-a','hr-test A',1,8,0,'HA','https://img.example/a.jpg') returning id into ga;
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key)
    values ('hr-test-b','hr-test B',1,8,0,'HB') returning id into gb;
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key) values ('hr-test-c','hr-test C',1,8,0,'HC');
  update public.record_quests set active = false where true;

  update public.record_state set source='supabase', went_live_at=now() where id;
  perform public.submit_play_record(jsonb_build_object('name','hr小美','date',yesterday,'script','HA','role','偵探','rating','5'));
  perform public.submit_play_record(jsonb_build_object('name','hr小美','date',yesterday,'script','HA','role','偵探','rating','5'));  -- 重複
  perform public.submit_play_record(jsonb_build_object('name','hr小美','date',today,'script','HB','role','管家','rating','4'));
  rec_c := (public.submit_play_record(jsonb_build_object('name','hr小美','date',today,'script','HC','role','x','rating','3')))->>'id';
  perform public.submit_play_record(jsonb_build_object('name','hr阿華','date',today,'script','HA','role','x','rating','4'));

  -- 沒綁定：沒有記錄。
  if jsonb_array_length(public.list_my_records(u1)) <> 0 then raise exception 'unbound user got records'; end if;
  insert into public.player_bindings(user_id,record_name,status) values (u1,'hr小美','approved');

  r := public.list_my_records(u1);
  if jsonb_array_length(r) <> 3 then raise exception 'records wrong: %', r; end if;
  if r->2->>'title' <> 'hr-test A' or r->2->>'image_url' <> 'https://img.example/a.jpg' or r->2->>'role' <> '偵探'
    or r->2->>'game_id' <> ga::text then raise exception 'oldest record wrong: %', r->2; end if;
  if not exists(select 1 from jsonb_array_elements(r) x where x->>'title' = 'hr-test C' and x->>'image_url' is null) then
    raise exception 'record without a poster missing: %', r; end if;
  if not (public.my_played_games(u1) ? ga::text) or not (public.my_played_games(u1) ? gb::text) then raise exception 'played set misses records'; end if;
  if jsonb_array_length(public.list_my_records(u2)) <> 0 or public.my_played_games(u2) ? ga::text then raise exception 'someone else got records'; end if;

  -- 店家隱藏的不列。
  perform public.admin_hide_record(adm, rec_c, true, '測試');
  if jsonb_array_length(public.list_my_records(u1)) <> 2 then raise exception 'hidden record listed'; end if;

  -- 同一天同一本已有出席紀錄：只列出席那筆。
  insert into public.players(user_id,display_name) values (u1,'小美') on conflict (user_id) do nothing;
  select id into pl from public.players where user_id = u1;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name,status)
    values (gb, now() - interval '3 hours', 6, 0, '南港', '海星', 'completed') returning id into ev;
  insert into public.player_game_history(player_id,game_id,event_id,played_at) values (pl, gb, ev, now() - interval '3 hours');
  r := public.list_my_records(u1);
  if (now() at time zone 'Asia/Taipei' - interval '3 hours')::date = (now() at time zone 'Asia/Taipei')::date
    and (jsonb_array_length(r) <> 1 or r->0->>'title' <> 'hr-test A') then raise exception 'attended day listed twice: %', r; end if;

  -- 切換前不列。
  update public.record_state set source='gas' where id;
  if jsonb_array_length(public.list_my_records(u1)) <> 0 or public.my_played_games(u1) ? ga::text then raise exception 'listed before cutover'; end if;
end $$;
reset role;
select 'PASS: 我的遊戲紀錄 lists play records (binding, cutover, hidden, duplicate, attended day, played set)' as result;
rollback;
