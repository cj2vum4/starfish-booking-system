begin;

-- 我的遊戲紀錄：以前只列預約系統記錄出席的場次（player_game_history），老玩家綁定後在網站填過的玩本記錄看不到。
-- 切換之後玩本記錄就在這個資料庫，會員卡同一套名字（核准的老玩家綁定，或新玩家自己取的名字）底下的記錄一起列出。
-- 切換前不列：那時資料庫裡只是匯入的副本，以 Apps Script 為準。
-- 不列：店家隱藏的、「重複」（同人同本同日再填一次）、以及同一天已經有出席紀錄的同一本（避免同一場出現兩次）。
-- 劇本名比對和送出時檢查劇本目錄一樣，不分空白與大小寫。
-- 作廢只作廢點數，記錄本身照列；超過每日上限、補登逾期也是真的玩過，照列。
create function public.list_my_records(p_actor uuid) returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'script',r.script,'title',coalesce(g.title,r.script),'game_id',g.id,
      'image_url',g.image_url,'date',r.date_text,'played_on',r.played_on,'role',r.role)
    order by r.played_on desc nulls last, r.submitted_at desc),'[]')
  from public.play_records r
  left join lateral (select gm.id, gm.title, gm.image_url from public.games gm
    where public._sf_name_norm(coalesce(gm.review_key, gm.title)) = public._sf_name_norm(r.script) order by gm.active desc, gm.synced_at desc nulls last limit 1) g on true
  where r.player_id = public._sf_line_player(p_actor)
    and exists(select 1 from public.record_state where source = 'supabase')
    and not r.hidden and r.status <> 'duplicate'
    and not exists(select 1 from public.player_game_history h
      join public.players p on p.id = h.player_id and p.user_id = p_actor
      join public.games hg on hg.id = h.game_id
      where public._sf_name_norm(coalesce(hg.review_key, hg.title)) = public._sf_name_norm(r.script)
        and (h.played_at at time zone 'Asia/Taipei')::date = r.played_on)
$$;

-- 開團時標「你玩過」：出席紀錄之外，也算玩本記錄裡玩過的劇本（同樣切換後、不含隱藏與重複）。
create or replace function public.my_played_games(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(distinct x.game_id),'[]') from (
    select h.game_id from public.player_game_history h join public.players p on p.id=h.player_id
      where p.user_id=p_actor
    union
    select gm.id from public.play_records r join public.games gm on public._sf_name_norm(coalesce(gm.review_key, gm.title)) = public._sf_name_norm(r.script)
      where r.player_id = public._sf_line_player(p_actor)
        and exists(select 1 from public.record_state where source = 'supabase')
        and not r.hidden and r.status <> 'duplicate'
  ) x
$$;

revoke all on function public.list_my_records(uuid), public.my_played_games(uuid) from public,anon,authenticated;
grant execute on function public.list_my_records(uuid), public.my_played_games(uuid) to service_role;

commit;
