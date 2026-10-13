-- 0039：第 3 階段「店家點數管理」（2026-10-13）。取代試算表上的手動操作（docs/GAS_MIGRATION.md）：
--   兌換申請與審核（玩家在會員卡申請 → 管理員 OA 通知 → 店家核准才扣點；店家也能直接幫沒綁 LINE 的玩家兌換）、
--   補點／扣點、作廢一筆點數、隱藏惡意記錄（同時作廢它的點數，可取消）、精選心得、別名與合併同一人、
--   榮耀軌（鍍金、自訂稱號、傳奇殿堂；兌換核准時自動生效）、點數規則／獎勵／任務設定、月報。
-- 寫入一律要在切換之後（record_state.source='supabase'）：切換前試算表才是正本，這裡改的會被重新匯入蓋掉。
-- 所有店家函式在函式內檢查 admin_users；只授權 service_role（api 以店家的 session 呼叫）。
begin;

-- ---------------------------------------------------------------------------------------------
-- 資料表
-- ---------------------------------------------------------------------------------------------

-- 隱藏的記錄不出現在榮譽牆、劇本頁，也不算場次；它的點數在隱藏時一併作廢。
alter table public.play_records
  add column hidden boolean not null default false,
  add column hidden_at timestamptz,
  add column hidden_by uuid references public.users(id) on delete set null,
  add column hidden_reason text not null default '' check (char_length(hidden_reason) <= 200);

-- 兌換申請。玩家申請時點數只「保留」（同一時間申請中的總和不能超過餘額），店家核准才寫扣點帳本。
create table public.redemption_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.record_players(id),
  user_id uuid references public.users(id) on delete set null,  -- 申請的 LINE 玩家；店家直接兌換時是 null
  reward_id uuid references public.record_rewards(id) on delete set null,
  reward_name text not null check (char_length(reward_name) between 1 and 60),
  track text not null default '' check (char_length(track) <= 20),
  cost integer not null check (cost > 0),
  title text not null default '' check (char_length(title) <= 20),  -- 自訂稱號：玩家填、店家核准前可改
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  store_note text not null default '' check (char_length(store_note) <= 200),
  request_key text unique check (request_key is null or char_length(request_key) between 1 and 80),  -- 重送只記一次
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.users(id) on delete set null,
  ledger_id uuid references public.point_ledger(id)
);
create index redemption_requests_pending on public.redemption_requests(created_at) where status = 'pending';
create index redemption_requests_player on public.redemption_requests(player_id, created_at desc);
alter table public.redemption_requests enable row level security;
revoke all on public.redemption_requests from public, anon, authenticated;
grant select, insert, update, delete on public.redemption_requests to service_role;

-- ---------------------------------------------------------------------------------------------
-- 共用小工具
-- ---------------------------------------------------------------------------------------------

-- 店家的寫入：必須是店家、必須已切換。鎖住 record_state（與送出、按讚同一把鎖）。
create function public._sf_store_write(p_actor uuid) returns void
language plpgsql set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
end $$;

create function public._sf_balance(p_player uuid) returns integer
language sql stable set search_path='' as $$
  select coalesce(sum(points),0)::int from public.point_ledger where player_id = p_player and voided_at is null
$$;

-- 申請中（還沒核准）的兌換保留的點數。
create function public._sf_held(p_player uuid) returns integer
language sql stable set search_path='' as $$
  select coalesce(sum(cost),0)::int from public.redemption_requests where player_id = p_player and status = 'pending'
$$;

create function public._sf_today_tp() returns date
language sql stable set search_path='' as $$ select (now() at time zone 'Asia/Taipei')::date $$;

-- 名字（或別名）→ 玩家；找不到就 NAME_NOT_FOUND。
create function public._sf_player_by_name(p_name text) returns uuid
language plpgsql stable set search_path='' as $$
declare pid uuid := public._sf_find_player(p_name);
begin
  if pid is null then raise exception 'NAME_NOT_FOUND' using errcode='P0001'; end if;
  return pid;
end $$;

-- 這個 LINE 使用者的玩本記錄名字：核准的老玩家綁定，或新玩家自己取的名字（會員卡同一套）。
create function public._sf_line_player(p_actor uuid) returns uuid
language sql stable set search_path='' as $$
  select public._sf_find_player(coalesce(
    (select record_name from public.player_bindings where user_id = p_actor and status = 'approved'),
    (select record_name from public.line_record_accounts where user_id = p_actor)))
$$;

create function public._sf_redemption_row(r public.redemption_requests) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('id',r.id,'player',p.name,'agent',coalesce(p.agent,''),'reward',r.reward_name,'track',r.track,
    'cost',r.cost,'title',r.title,'status',r.status,'store_note',r.store_note,'created_at',r.created_at,'decided_at',r.decided_at,
    'from_line',r.user_id is not null,'balance',public._sf_balance(r.player_id),'held',public._sf_held(r.player_id))
  from public.record_players p where p.id = r.player_id
$$;

-- ---------------------------------------------------------------------------------------------
-- 兌換
-- ---------------------------------------------------------------------------------------------

-- 會員卡：我的兌換申請與可用點數。切換前 live=false（兌換仍到店由店家在試算表扣點）。
create function public.my_redemptions(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare pid uuid;
begin
  if (select source from public.record_state) <> 'supabase' then return jsonb_build_object('live',false); end if;
  pid := public._sf_line_player(p_actor);
  if pid is null then return jsonb_build_object('live',true,'player',null); end if;
  return jsonb_build_object('live',true,'player',(select name from public.record_players where id=pid),
    'balance',public._sf_balance(pid),'held',public._sf_held(pid),
    'rewards',coalesce((select jsonb_agg(jsonb_build_object('id',id,'track',track,'name',name,'cost',cost,'note',note) order by sort, name)
      from public.record_rewards where active and cost > 0),'[]'),
    'requests',coalesce((select jsonb_agg(public._sf_redemption_row(r) order by r.created_at desc)
      from (select * from public.redemption_requests where player_id=pid order by created_at desc limit 20) r),'[]'));
end $$;

-- 玩家申請兌換：獎勵要上架；可用點數（餘額－申請中的保留）要夠；同時最多 5 筆申請中。通知所有店家（管理員 OA）。
create function public.request_redemption(p_actor uuid, p_reward_id uuid, p_title text default '', p_request_key text default null)
returns jsonb language plpgsql set search_path='' as $$
declare pid uuid; rw public.record_rewards; r public.redemption_requests; t text := public._sf_js_trim(coalesce(p_title,''));
  bal integer; held integer;
begin
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  if p_request_key is not null then
    select * into r from public.redemption_requests where request_key = p_request_key;
    if found then return public._sf_redemption_row(r); end if;
  end if;
  pid := public._sf_line_player(p_actor);
  if pid is null then raise exception 'BINDING_REQUIRED' using errcode='P0001'; end if;
  select * into rw from public.record_rewards where id = p_reward_id and active and cost > 0;
  if not found then raise exception 'REWARD_NOT_FOUND' using errcode='P0001'; end if;
  if rw.name like '%稱號%' and (t = '' or char_length(t) > 20) then raise exception 'INVALID_TITLE' using errcode='P0001'; end if;
  if rw.name not like '%稱號%' then t := ''; end if;
  if (select count(*) from public.redemption_requests where player_id=pid and status='pending') >= 5 then
    raise exception 'TOO_MANY_REQUESTS' using errcode='P0001'; end if;
  bal := public._sf_balance(pid); held := public._sf_held(pid);
  if bal - held < rw.cost then raise exception 'NOT_ENOUGH_POINTS' using errcode='P0001'; end if;
  insert into public.redemption_requests(player_id,user_id,reward_id,reward_name,track,cost,title,request_key)
    values (pid,p_actor,rw.id,rw.name,rw.track,rw.cost,t,p_request_key) returning * into r;
  insert into public.notification_logs(user_id,notification_type,payload,dedupe_key)
    select a.user_id,'redemption_requested',jsonb_build_object('kind','redemption_requested',
        'record_name',(select name from public.record_players where id=pid),'reward',rw.name,'cost',rw.cost,
        'balance',bal,'title',t),'redemption_requested:'||r.id||':'||a.user_id
    from public.admin_users a
  on conflict (dedupe_key) do nothing;
  return public._sf_redemption_row(r);
end $$;

-- 玩家取消自己還在申請中的兌換（保留的點數放回）。
create function public.cancel_redemption(p_actor uuid, p_id uuid) returns jsonb
language plpgsql set search_path='' as $$
declare r public.redemption_requests;
begin
  perform public._sf_records_lock();
  select * into r from public.redemption_requests where id = p_id and user_id = p_actor for update;
  if not found then raise exception 'REDEMPTION_NOT_FOUND' using errcode='P0001'; end if;
  if r.status <> 'pending' then raise exception 'REDEMPTION_DECIDED' using errcode='P0001'; end if;
  update public.redemption_requests set status='cancelled', decided_at=now() where id = p_id returning * into r;
  return public._sf_redemption_row(r);
end $$;

-- 核准或不通過（內部；呼叫前已鎖）。核准：餘額要夠（申請中的保留不算這一筆自己）→ 寫兌換帳本（負數）→ 榮耀軌生效；
-- 名稱含「鍍金」→ 鍍金、含「稱號」→ 自訂稱號、含「傳奇」→ 傳奇殿堂（與試算表「獎勵」分頁的品項名稱對應）。
create function public._sf_decide_redemption(p_actor uuid, p_id uuid, p_approve boolean, p_title text, p_note text)
returns public.redemption_requests language plpgsql set search_path='' as $$
declare r public.redemption_requests; lid uuid; t text; bal integer; today date := public._sf_today_tp();
begin
  select * into r from public.redemption_requests where id = p_id for update;
  if not found then raise exception 'REDEMPTION_NOT_FOUND' using errcode='P0001'; end if;
  if r.status <> 'pending' then raise exception 'REDEMPTION_DECIDED' using errcode='P0001'; end if;
  t := public._sf_js_trim(coalesce(nullif(public._sf_js_trim(coalesce(p_title,'')),''), r.title));
  if p_approve then
    if r.reward_name like '%稱號%' and (t = '' or char_length(t) > 20) then raise exception 'INVALID_TITLE' using errcode='P0001'; end if;
    bal := public._sf_balance(r.player_id);
    if bal < r.cost then raise exception 'NOT_ENOUGH_POINTS' using errcode='P0001'; end if;
    insert into public.point_ledger(player_id,kind,points,detail,date_text,earned_on,note,dedupe_key,source,created_by)
      values (r.player_id,'redeem',-r.cost,left('兌換：'||r.reward_name,200),
        extract(year from today)::int||'/'||extract(month from today)::int||'/'||extract(day from today)::int,today,
        left(concat_ws('・', case when r.reward_name like '%稱號%' then '稱號：'||t end, nullif(coalesce(p_note,''),'')),300),
        'redeem|'||r.id,'store',p_actor)
      returning id into lid;
    update public.record_players set
      gilded = gilded or r.reward_name like '%鍍金%',
      legend = legend or r.reward_name like '%傳奇%',
      title = case when r.reward_name like '%稱號%' then t else title end
      where id = r.player_id;
    update public.redemption_requests set status='approved', decided_at=now(), decided_by=p_actor, ledger_id=lid,
      title=case when r.reward_name like '%稱號%' then t else title end, store_note=left(coalesce(p_note,''),200)
      where id = p_id returning * into r;
  else
    update public.redemption_requests set status='rejected', decided_at=now(), decided_by=p_actor, store_note=left(coalesce(p_note,''),200)
      where id = p_id returning * into r;
  end if;
  if r.user_id is not null then
    insert into public.notification_logs(user_id,notification_type,payload,dedupe_key)
      values (r.user_id, case when p_approve then 'redemption_approved' else 'redemption_rejected' end,
        jsonb_build_object('kind',case when p_approve then 'redemption_approved' else 'redemption_rejected' end,
          'reward',r.reward_name,'cost',r.cost,'balance',public._sf_balance(r.player_id),'note',r.store_note,'title',r.title),
        'redemption_decided:'||r.id)
      on conflict (dedupe_key) do nothing;
  end if;
  perform public._sf_audit(p_actor, case when p_approve then 'redemption.approve' else 'redemption.reject' end,
    'redemption_request', r.id, jsonb_build_object('cost',r.cost,'reward',r.reward_name));
  return r;
end $$;

create function public.admin_decide_redemption(p_actor uuid, p_id uuid, p_approve boolean, p_title text default '', p_note text default '')
returns jsonb language plpgsql set search_path='' as $$
declare r public.redemption_requests;
begin
  perform public._sf_store_write(p_actor);
  -- 先決定、下一句才讀餘額：同一句裡讀不到剛寫進帳本的那筆。
  r := public._sf_decide_redemption(p_actor, p_id, p_approve, p_title, left(public._sf_js_trim(coalesce(p_note,'')),200));
  return public._sf_redemption_row(r);
end $$;

-- 店家直接幫玩家兌換（沒綁 LINE、到店口頭說的）：建一筆申請並立即核准。
create function public.admin_redeem(p_actor uuid, p_player text, p_reward_id uuid, p_title text default '', p_note text default '',
  p_request_key text default null) returns jsonb language plpgsql set search_path='' as $$
declare pid uuid; rw public.record_rewards; r public.redemption_requests;
begin
  perform public._sf_store_write(p_actor);
  if p_request_key is not null then
    select * into r from public.redemption_requests where request_key = p_request_key;
    if found then return public._sf_redemption_row(r); end if;
  end if;
  pid := public._sf_player_by_name(p_player);
  select * into rw from public.record_rewards where id = p_reward_id and cost > 0;
  if not found then raise exception 'REWARD_NOT_FOUND' using errcode='P0001'; end if;
  insert into public.redemption_requests(player_id,reward_id,reward_name,track,cost,title,request_key)
    values (pid,rw.id,rw.name,rw.track,rw.cost,left(public._sf_js_trim(coalesce(p_title,'')),20),p_request_key) returning * into r;
  r := public._sf_decide_redemption(p_actor, r.id, true, p_title, left(public._sf_js_trim(coalesce(p_note,'')),200));
  return public._sf_redemption_row(r);
end $$;

-- 店家：兌換申請（申請中的全部，加上最近 30 筆已處理的）。
create function public.admin_redemptions(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return jsonb_build_object('live',(select source from public.record_state) = 'supabase',
    'pending',coalesce((select jsonb_agg(public._sf_redemption_row(r) order by r.created_at)
      from public.redemption_requests r where r.status='pending'),'[]'),
    'recent',coalesce((select jsonb_agg(public._sf_redemption_row(r) order by r.decided_at desc)
      from (select * from public.redemption_requests where status<>'pending' order by decided_at desc nulls last limit 30) r),'[]'));
end $$;

-- ---------------------------------------------------------------------------------------------
-- 補點／扣點、作廢
-- ---------------------------------------------------------------------------------------------

-- 補點（正數）或扣點（負數），要寫原因。p_request_key：同一次按鈕重送只記一次。
create function public.admin_adjust_points(p_actor uuid, p_player text, p_points integer, p_reason text,
  p_request_key text default null) returns jsonb language plpgsql set search_path='' as $$
declare pid uuid; why text := left(public._sf_js_trim(coalesce(p_reason,'')),100); today date := public._sf_today_tp(); lid uuid;
begin
  perform public._sf_store_write(p_actor);
  pid := public._sf_player_by_name(p_player);
  if p_points is null or p_points = 0 or p_points not between -1000 and 1000 then raise exception 'INVALID_POINTS' using errcode='P0001'; end if;
  if why = '' then raise exception 'INVALID_REASON' using errcode='P0001'; end if;
  insert into public.point_ledger(player_id,kind,points,detail,date_text,earned_on,dedupe_key,source,created_by)
    values (pid,'adjust',p_points,case when p_points > 0 then '補點：' else '扣點：' end || why,
      extract(year from today)::int||'/'||extract(month from today)::int||'/'||extract(day from today)::int,today,
      'adjust|'||coalesce(p_request_key, gen_random_uuid()::text),'store',p_actor)
    on conflict (dedupe_key) do nothing
    returning id into lid;
  if lid is not null then
    perform public._sf_audit(p_actor,'records.adjust','record_player',pid,jsonb_build_object('points',p_points,'reason',why));
  end if;
  return jsonb_build_object('player',(select name from public.record_players where id=pid),'balance',public._sf_balance(pid),
    'duplicate',lid is null);
end $$;

-- 作廢一筆點數（帳本只能填作廢欄位，不能改回）。兌換的那筆作廢＝退還點數。
create function public.admin_void_ledger(p_actor uuid, p_ledger_id uuid, p_reason text) returns jsonb
language plpgsql set search_path='' as $$
declare l public.point_ledger; why text := left(public._sf_js_trim(coalesce(p_reason,'')),200);
begin
  perform public._sf_store_write(p_actor);
  if why = '' then raise exception 'INVALID_REASON' using errcode='P0001'; end if;
  select * into l from public.point_ledger where id = p_ledger_id for update;
  if not found then raise exception 'LEDGER_NOT_FOUND' using errcode='P0001'; end if;
  if l.voided_at is not null then raise exception 'LEDGER_VOIDED' using errcode='P0001'; end if;
  update public.point_ledger set voided_at=now(), voided_by=p_actor, void_reason=why where id = p_ledger_id;
  perform public._sf_audit(p_actor,'records.void','point_ledger',p_ledger_id,jsonb_build_object('points',l.points,'reason',why));
  return jsonb_build_object('balance',public._sf_balance(l.player_id));
end $$;

-- ---------------------------------------------------------------------------------------------
-- 隱藏惡意記錄、精選心得
-- ---------------------------------------------------------------------------------------------

-- 隱藏：心得從榮譽牆、劇本頁消失、不算場次；這筆的記錄／介紹點數，以及只屬於這則心得的讚與精選點數一併作廢
-- （作廢原因記「hidden:<記錄>」）。取消隱藏：記錄回來，當初因隱藏而作廢的點數補回（新的一筆，帳本不改舊列）。
create function public.admin_hide_record(p_actor uuid, p_record_id uuid, p_hide boolean, p_reason text default '')
returns jsonb language plpgsql set search_path='' as $$
declare pr public.play_records; iid uuid; tag text := 'hidden:'||p_record_id; l public.point_ledger; n integer := 0;
begin
  perform public._sf_store_write(p_actor);
  select * into pr from public.play_records where id = p_record_id for update;
  if not found then raise exception 'RECORD_NOT_FOUND' using errcode='P0001'; end if;
  select id into iid from public.review_interactions
    where script = pr.script and date_text = pr.date_text and author_norm = public._sf_name_norm(pr.name);
  -- 同一則心得（同作者、同劇本、同日）若還有別筆沒隱藏的記錄，讚與精選留著。
  if exists(select 1 from public.play_records x where x.id <> pr.id and not x.hidden and x.script = pr.script
      and x.date_text = pr.date_text and public._sf_name_norm(x.name) = public._sf_name_norm(pr.name)) then
    iid := null;
  end if;
  if p_hide then
    if pr.hidden then raise exception 'RECORD_HIDDEN' using errcode='P0001'; end if;
    update public.play_records set hidden=true, hidden_at=now(), hidden_by=p_actor,
      hidden_reason=left(public._sf_js_trim(coalesce(p_reason,'')),200) where id = pr.id;
    update public.point_ledger set voided_at=now(), voided_by=p_actor, void_reason=tag
      where voided_at is null and (record_id = pr.id or (iid is not null and interaction_id = iid));
    get diagnostics n = row_count;
  else
    if not pr.hidden then raise exception 'RECORD_NOT_HIDDEN' using errcode='P0001'; end if;
    update public.play_records set hidden=false, hidden_at=null, hidden_by=null, hidden_reason='' where id = pr.id;
    for l in select * from public.point_ledger where void_reason = tag order by created_at, id loop
      insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,record_id,interaction_id,
          dedupe_key,source,created_by)
        values (l.player_id,l.kind,l.points,l.detail,l.script,l.date_text,l.earned_on,left('取消隱藏，補回原本的點數'||
            case when l.note <> '' then '・'||l.note else '' end,300),l.record_id,l.interaction_id,
          left('restore|'||l.id,300),'store',p_actor)
        on conflict (dedupe_key) do nothing;
      if found then n := n + 1; end if;
    end loop;
  end if;
  perform public._sf_audit(p_actor, case when p_hide then 'records.hide' else 'records.unhide' end,'play_record',pr.id,
    jsonb_build_object('ledger_rows',n));
  return jsonb_build_object('id',pr.id,'hidden',p_hide,'ledger_rows',n);
end $$;

-- 精選心得：給作者「精選點數」一次；取消精選＝作廢那筆。再次精選再發一筆新的（帳本不改舊列）。
-- 只有補登的記錄（不給點）被精選也不給點，與按讚相同。
create function public.admin_feature_record(p_actor uuid, p_record_id uuid, p_featured boolean) returns jsonb
language plpgsql set search_path='' as $$
declare pr public.play_records; i public.review_interactions; pts integer := (public._sf_record_config()->>'精選點數')::int;
  pid uuid; n integer;
begin
  perform public._sf_store_write(p_actor);
  select * into pr from public.play_records where id = p_record_id;
  if not found or pr.hidden then raise exception 'RECORD_NOT_FOUND' using errcode='P0001'; end if;
  if public._sf_js_trim(pr.comment) = '' then raise exception 'NO_COMMENT' using errcode='P0001'; end if;
  insert into public.review_interactions(script,date_text,author) values (pr.script,pr.date_text,pr.name)
    on conflict (script,date_text,author_norm) do nothing;
  select * into i from public.review_interactions
    where script=pr.script and date_text=pr.date_text and author_norm=public._sf_name_norm(pr.name) for update;
  pid := public._sf_find_player(i.author);
  if p_featured then
    update public.review_interactions set featured=true, updated_at=now() where id = i.id;
    if pts > 0 and pid is not null and not exists(select 1 from public.point_ledger
        where interaction_id = i.id and kind = 'featured' and voided_at is null)
      and exists(select 1 from public.play_records r where r.script=pr.script and r.date_text=pr.date_text
        and r.player_id=pid and r.status<>'backfill' and not r.hidden) then
      select count(*) into n from public.point_ledger where interaction_id = i.id and kind = 'featured';
      insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,interaction_id,dedupe_key,source,created_by)
        values (pid,'featured',pts,'精選心得'||pts,i.script,i.date_text,public._sf_parse_play_date(i.date_text),i.id,
          'featured|'||i.id||case when n > 0 then '|'||n else '' end,'store',p_actor);
    end if;
  else
    update public.review_interactions set featured=false, updated_at=now() where id = i.id;
    update public.point_ledger set voided_at=now(), voided_by=p_actor, void_reason='取消精選'
      where interaction_id = i.id and kind = 'featured' and voided_at is null;
  end if;
  perform public._sf_audit(p_actor, case when p_featured then 'records.feature' else 'records.unfeature' end,'review_interaction',i.id);
  return jsonb_build_object('id',pr.id,'featured',p_featured,'balance',case when pid is null then null else public._sf_balance(pid) end);
end $$;

-- 店家：心得清單（新的在前，含隱藏的；可依劇本），30 筆一頁。
create function public.admin_reviews(p_actor uuid, p_script text default null, p_before timestamptz default null,
  p_before_id uuid default null) returns jsonb language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'submitted_at')::timestamptz desc, x->>'id' desc) from (
    select jsonb_build_object('id',r.id,'name',r.name,'player',p.name,'script',r.script,'date',r.date_text,'role',r.role,
      'rating',r.rating,'comment',r.comment,'status',r.status,'points',r.points,'hidden',r.hidden,'hidden_reason',r.hidden_reason,
      'source',r.source,'submitted_at',r.submitted_at,
      'featured',coalesce(i.featured,false),'likes',coalesce(i.likes,0)) x
    from public.play_records r join public.record_players p on p.id = r.player_id
    left join public.review_interactions i on i.script=r.script and i.date_text=r.date_text and i.author_norm=public._sf_name_norm(r.name)
    where (p_script is null or p_script = '' or r.script = p_script)
      and (p_before is null or (r.submitted_at, r.id) < (p_before, coalesce(p_before_id,'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
    order by r.submitted_at desc, r.id desc limit 30) s), '[]');
end $$;

-- ---------------------------------------------------------------------------------------------
-- 玩家：搜尋、明細、榮耀軌、別名、合併
-- ---------------------------------------------------------------------------------------------

create function public.admin_players(p_actor uuid, p_query text default '') returns jsonb
language plpgsql stable set search_path='' as $$
declare q text := public._sf_name_norm(coalesce(p_query,''));
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('name',p.name,'agent',coalesce(p.agent,''),'balance',public._sf_balance(p.id),'held',public._sf_held(p.id),
      'aliases',coalesce((select jsonb_agg(a.alias order by a.alias) from public.record_aliases a where a.player_id=p.id),'[]'),
      'last',(select max(submitted_at) from public.play_records r where r.player_id=p.id)) x
    from public.record_players p
    where q = '' or p.name_norm like '%'||q||'%' or exists(select 1 from public.record_aliases a where a.player_id=p.id and a.alias_norm like '%'||q||'%')
      or (q ~ '^#?\d+$' and coalesce(p.agent,'') like '%'||ltrim(q,'#'))
    order by case when p.name_norm = q then 0 else 1 end,
      (select max(submitted_at) from public.play_records r where r.player_id=p.id) desc nulls last, p.name
    limit 30) s), '[]');
end $$;

create function public.admin_player(p_actor uuid, p_name text) returns jsonb
language plpgsql stable set search_path='' as $$
declare pid uuid; p public.record_players;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  pid := public._sf_player_by_name(p_name);
  select * into p from public.record_players where id = pid;
  return jsonb_build_object('live',(select source from public.record_state) = 'supabase',
    'name',p.name,'agent',coalesce(p.agent,''),'joined',p.joined_on,'gilded',p.gilded,'title',p.title,'legend',p.legend,'note',p.note,
    'balance',public._sf_balance(pid),'held',public._sf_held(pid),
    'earned',(select coalesce(sum(points),0) from public.point_ledger where player_id=pid and voided_at is null and points >= 0),
    'redeemed',(select coalesce(-sum(points),0) from public.point_ledger where player_id=pid and voided_at is null and points < 0),
    'aliases',coalesce((select jsonb_agg(a.alias order by a.alias) from public.record_aliases a where a.player_id=pid),'[]'),
    'bound',exists(select 1 from public.player_bindings b where b.status='approved' and public._sf_find_player(b.record_name)=pid)
      or exists(select 1 from public.line_record_accounts a where public._sf_find_player(a.record_name)=pid),
    'ledger',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'kind',l.kind,'points',l.points,'detail',l.detail,'script',l.script,
        'date',l.date_text,'note',l.note,'source',l.source,'created_at',l.created_at,'voided',l.voided_at is not null,'void_reason',l.void_reason)
        order by l.created_at desc, l.id) from (select * from public.point_ledger where player_id=pid order by created_at desc, id limit 200) l),'[]'),
    'records',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'script',r.script,'date',r.date_text,'status',r.status,
        'points',r.points,'hidden',r.hidden,'comment',r.comment) order by r.submitted_at desc)
        from (select * from public.play_records where player_id=pid order by submitted_at desc limit 100) r),'[]'),
    'requests',coalesce((select jsonb_agg(public._sf_redemption_row(r) order by r.created_at desc)
        from (select * from public.redemption_requests where player_id=pid order by created_at desc limit 20) r),'[]'));
end $$;

-- 榮耀軌：店家手動設定（兌換核准時會自動設定，這裡用於更正）。
create function public.admin_set_glory(p_actor uuid, p_player text, p_gilded boolean, p_title text, p_legend boolean)
returns jsonb language plpgsql set search_path='' as $$
declare pid uuid; t text := left(public._sf_js_trim(coalesce(p_title,'')),20);
begin
  perform public._sf_store_write(p_actor);
  pid := public._sf_player_by_name(p_player);
  update public.record_players set gilded=coalesce(p_gilded,false), title=t, legend=coalesce(p_legend,false) where id = pid;
  perform public._sf_audit(p_actor,'records.glory','record_player',pid,jsonb_build_object('gilded',p_gilded,'title',t,'legend',p_legend));
  return public.admin_player(p_actor, p_player);
end $$;

-- 別名：這個名字（填表時寫的）算到這位玩家。名字若已經是另一位有記錄的玩家，請用「合併」。
create function public.admin_set_alias(p_actor uuid, p_player text, p_alias text, p_remove boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare pid uuid; a text := left(public._sf_js_trim(coalesce(p_alias,'')),60); an text := public._sf_name_norm(coalesce(p_alias,''));
begin
  perform public._sf_store_write(p_actor);
  pid := public._sf_player_by_name(p_player);
  if an = '' then raise exception 'INVALID_NAME' using errcode='P0001'; end if;
  if p_remove then
    delete from public.record_aliases where alias_norm = an and player_id = pid;
    if not found then raise exception 'ALIAS_NOT_FOUND' using errcode='P0001'; end if;
  else
    if exists(select 1 from public.record_players where name_norm = an) then raise exception 'NAME_IS_PLAYER' using errcode='P0001'; end if;
    if exists(select 1 from public.record_aliases where alias_norm = an and player_id <> pid) then
      raise exception 'ALIAS_TAKEN' using errcode='P0001'; end if;
    insert into public.record_aliases(alias_norm,alias,player_id) values (an,a,pid) on conflict (alias_norm) do nothing;
  end if;
  perform public._sf_audit(p_actor, case when p_remove then 'records.alias_remove' else 'records.alias_add' end,'record_player',pid,
    jsonb_build_object('alias',a));
  return public.admin_player(p_actor, p_player);
end $$;

-- 合併同一人：p_from 的所有記錄、點數、兌換、別名移到 p_into，p_from 變成 p_into 的別名。
-- 探員編號留 p_into 的；榮耀軌取兩邊有的；加入日期取早的。帳本只改歸屬（觸發器只在這裡放行 player_id 的變更）。
create function public.admin_merge_players(p_actor uuid, p_from text, p_into text) returns jsonb
language plpgsql set search_path='' as $$
declare a uuid; b uuid; fa public.record_players; ib public.record_players;
begin
  perform public._sf_store_write(p_actor);
  a := public._sf_player_by_name(p_from); b := public._sf_player_by_name(p_into);
  if a = b then raise exception 'SAME_PLAYER' using errcode='P0001'; end if;
  select * into fa from public.record_players where id = a for update;
  select * into ib from public.record_players where id = b for update;
  perform set_config('starfish.merging', 'on', true);
  update public.point_ledger set player_id = b where player_id = a;
  perform set_config('starfish.merging', '', true);
  update public.play_records set player_id = b where player_id = a;
  update public.play_records set referrer_id = b where referrer_id = a;
  update public.redemption_requests set player_id = b where player_id = a;
  update public.record_aliases set player_id = b where player_id = a;
  delete from public.record_players where id = a;
  insert into public.record_aliases(alias_norm,alias,player_id) values (fa.name_norm, fa.name, b)
    on conflict (alias_norm) do update set alias=excluded.alias, player_id=excluded.player_id;
  update public.record_players set gilded = gilded or fa.gilded, legend = legend or fa.legend,
    title = case when title = '' then fa.title else title end,
    joined_on = case when joined_on is null or (fa.joined_on is not null and fa.joined_on < joined_on) then fa.joined_on else joined_on end,
    note = left(trim(both '・' from note || case when fa.note <> '' then '・'||fa.note else '' end),500)
    where id = b;
  perform public._sf_audit(p_actor,'records.merge','record_player',b,jsonb_build_object('from',fa.name,'from_agent',fa.agent));
  return public.admin_player(p_actor, p_into);
end $$;

-- 帳本只增不改；合併同一人時（只在 admin_merge_players 內）允許只改歸屬。
create or replace function public._sf_guard_ledger() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op = 'DELETE' then
    if (select source <> 'gas' or went_live_at is not null from public.record_state) then
      raise exception 'LEDGER_APPEND_ONLY' using errcode='P0001';
    end if;
    return old;
  end if;
  if current_setting('starfish.merging', true) = 'on'
     and (new.kind, new.points, new.detail, new.script, new.date_text, new.earned_on, new.note, new.record_id, new.interaction_id,
          new.dedupe_key, new.source, new.created_at, new.created_by, new.voided_at, new.voided_by, new.void_reason)
     is not distinct from (old.kind, old.points, old.detail, old.script, old.date_text, old.earned_on, old.note, old.record_id,
          old.interaction_id, old.dedupe_key, old.source, old.created_at, old.created_by, old.voided_at, old.voided_by, old.void_reason) then
    return new;
  end if;
  if (new.player_id, new.kind, new.points, new.detail, new.script, new.date_text, new.earned_on, new.note, new.record_id,
      new.interaction_id, new.dedupe_key, new.source, new.created_at, new.created_by)
     is distinct from (old.player_id, old.kind, old.points, old.detail, old.script, old.date_text, old.earned_on, old.note,
      old.record_id, old.interaction_id, old.dedupe_key, old.source, old.created_at, old.created_by)
     or (old.voided_at is not null and new.voided_at is distinct from old.voided_at) then
    raise exception 'LEDGER_APPEND_ONLY' using errcode='P0001';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 點數規則、獎勵、任務
-- ---------------------------------------------------------------------------------------------

create function public.admin_record_settings(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare c jsonb := public._sf_record_config();
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return jsonb_build_object('live',(select source from public.record_state) = 'supabase',
    'settings',(select jsonb_agg(jsonb_build_object('key',k,'value',coalesce(s.value, c->>k)) order by o)
      from unnest(array['基本點數','心得點數','心得字數門檻','首玩點數','首探點數','新手好運點數','介紹人點數','被介紹點數',
        '每日上限筆數','讚點數','讚點數上限','精選點數','雙倍日','雙倍日文案','回歸禮資格日','LINE上線日','補登寬限天數'])
        with ordinality t(k,o) left join public.record_settings s on s.key = t.k),
    'rewards',coalesce((select jsonb_agg(jsonb_build_object('id',id,'track',track,'name',name,'cost',cost,'note',note,'active',active,'sort',sort)
      order by sort, name) from public.record_rewards),'[]'),
    'quests',coalesce((select jsonb_agg(jsonb_build_object('id',id,'label',label,'goal',goal,'points',points,'active',active)
      order by sort, id) from public.record_quests),'[]'));
end $$;

-- 數字設定 0–1000 的整數；日期設定是可辨認的日期或留空；雙倍日／文案是文字。只影響之後的新點數（點數固定）。
create function public.admin_save_setting(p_actor uuid, p_key text, p_value text) returns jsonb
language plpgsql set search_path='' as $$
declare v text := left(public._sf_js_trim(coalesce(p_value,'')),200);
begin
  perform public._sf_store_write(p_actor);
  if p_key not in ('基本點數','心得點數','心得字數門檻','首玩點數','首探點數','新手好運點數','介紹人點數','被介紹點數',
      '每日上限筆數','讚點數','讚點數上限','精選點數','雙倍日','雙倍日文案','回歸禮資格日','LINE上線日','補登寬限天數') then
    raise exception 'INVALID_SETTING' using errcode='P0001'; end if;
  if p_key in ('基本點數','心得點數','心得字數門檻','首玩點數','首探點數','新手好運點數','介紹人點數','被介紹點數',
      '每日上限筆數','讚點數','讚點數上限','精選點數','補登寬限天數')
     and (v !~ '^\d{1,4}$' or lpad(v,4,'0') > '1000') then
    raise exception 'INVALID_SETTING' using errcode='P0001'; end if;
  if p_key in ('回歸禮資格日','LINE上線日') and v <> '' and public._sf_parse_play_date(v) is null then
    raise exception 'INVALID_SETTING' using errcode='P0001'; end if;
  if p_key in ('回歸禮資格日','LINE上線日') and v <> '' then v := public._sf_date_text(v); end if;
  insert into public.record_settings(key,value,updated_at) values (p_key,v,now())
    on conflict (key) do update set value=excluded.value, updated_at=now();
  perform public._sf_audit(p_actor,'records.setting','record_state',null,jsonb_build_object('key',p_key,'value',v));
  return public.admin_record_settings(p_actor);
end $$;

-- 獎勵：p_id 空白＝新增。下架用 active=false（申請中的兌換照樣可以核准）。
create function public.admin_save_reward(p_actor uuid, p_id uuid, p_track text, p_name text, p_cost integer, p_note text,
  p_active boolean, p_sort integer default null) returns jsonb language plpgsql set search_path='' as $$
declare n text := left(public._sf_js_trim(coalesce(p_name,'')),60);
begin
  perform public._sf_store_write(p_actor);
  if n = '' or p_cost is null or p_cost not between 1 and 10000 then raise exception 'INVALID_REWARD' using errcode='P0001'; end if;
  if p_id is null then
    insert into public.record_rewards(sort,track,name,cost,note,active)
      values (coalesce(p_sort,(select coalesce(max(sort),0)+1 from public.record_rewards)),left(public._sf_js_trim(coalesce(p_track,'')),20),
        n,p_cost,left(public._sf_js_trim(coalesce(p_note,'')),200),coalesce(p_active,true));
  else
    update public.record_rewards set track=left(public._sf_js_trim(coalesce(p_track,'')),20), name=n, cost=p_cost,
      note=left(public._sf_js_trim(coalesce(p_note,'')),200), active=coalesce(p_active,true), sort=coalesce(p_sort,sort)
      where id = p_id;
    if not found then raise exception 'REWARD_NOT_FOUND' using errcode='P0001'; end if;
  end if;
  perform public._sf_audit(p_actor,'records.reward','record_state',null,jsonb_build_object('name',n,'cost',p_cost,'active',p_active));
  return public.admin_record_settings(p_actor);
end $$;

-- 任務：只有「場次／心得／新本／揪團」四種有進度。說明裡的 {目標} 會換成目標數字。
create function public.admin_save_quest(p_actor uuid, p_id text, p_label text, p_goal integer, p_points integer, p_active boolean)
returns jsonb language plpgsql set search_path='' as $$
begin
  perform public._sf_store_write(p_actor);
  if p_id not in ('場次','心得','新本','揪團') or p_goal is null or p_goal not between 0 and 100
     or p_points is null or p_points not between 0 and 1000 then raise exception 'INVALID_QUEST' using errcode='P0001'; end if;
  insert into public.record_quests(id,sort,label,goal,points,active)
    values (p_id,array_position(array['場次','心得','新本','揪團'],p_id),left(public._sf_js_trim(coalesce(p_label,'')),100),p_goal,p_points,
      coalesce(p_active,true))
    on conflict (id) do update set label=excluded.label, goal=excluded.goal, points=excluded.points, active=excluded.active;
  perform public._sf_audit(p_actor,'records.quest','record_state',null,jsonb_build_object('id',p_id,'goal',p_goal,'points',p_points));
  return public.admin_record_settings(p_actor);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 月報（buildMonthlyReport_）：依遊玩日的月份。場次＝同劇本同日；週六日算假日；新玩家＝第一次出現的月份；
-- 回訪間隔＝同一人與上一場相差的天數（計入較晚那場的月份）；發出／兌換點數依帳本日期（作廢的不算）。
-- 隱藏的記錄不算。
-- ---------------------------------------------------------------------------------------------
create function public.admin_records_report(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return coalesce((
    with plays as (
      select r.player_id, r.script, r.played_on, r.date_text, r.referrer,
        to_char(r.played_on,'YYYY/MM') m,
        r.played_on - lag(r.played_on) over (partition by r.player_id order by r.played_on, r.submitted_at) gap,
        row_number() over (partition by r.player_id order by r.played_on, r.submitted_at) nth
      from public.play_records r where not r.hidden and r.played_on is not null),
    months as (
      select m,
        count(distinct (script, played_on)) sessions,
        count(*) responses,
        count(distinct (script, played_on)) filter (where extract(dow from played_on) not in (0,6)) weekday,
        count(distinct (script, played_on)) filter (where extract(dow from played_on) in (0,6)) weekend,
        count(distinct player_id) active,
        count(*) filter (where nth = 1) new_players,
        round(avg(gap) filter (where gap > 0)) avg_gap,
        count(*) filter (where public._sf_js_trim(referrer) <> '') referrals
      from plays group by m),
    pts as (
      select to_char(earned_on,'YYYY/MM') m, coalesce(sum(points) filter (where points >= 0),0) earned,
        coalesce(-sum(points) filter (where points < 0),0) redeemed
      from public.point_ledger where voided_at is null and earned_on is not null group by 1),
    allm as (select m from months union select m from pts)
    select jsonb_agg(jsonb_build_object('month',a.m,'sessions',coalesce(x.sessions,0),'responses',coalesce(x.responses,0),
      'perSession',case when coalesce(x.sessions,0) > 0 then round(x.responses::numeric / x.sessions, 1) else 0 end,
      'weekday',coalesce(x.weekday,0),'weekend',coalesce(x.weekend,0),
      'weekdayPct',case when coalesce(x.sessions,0) > 0 then round(x.weekday * 100.0 / x.sessions) end,
      'active',coalesce(x.active,0),'newPlayers',coalesce(x.new_players,0),'avgGap',x.avg_gap,'referrals',coalesce(x.referrals,0),
      'earned',coalesce(p.earned,0),'redeemed',coalesce(p.redeemed,0)) order by a.m desc)
    from allm a left join months x on x.m = a.m left join pts p on p.m = a.m), '[]');
end $$;

-- ---------------------------------------------------------------------------------------------
-- 隱藏的記錄：不在公開心得、不算場次與最後遊玩日、不能按讚（0036 的三個函式加上 not hidden）
-- ---------------------------------------------------------------------------------------------

create or replace function public.public_play_records(p_script text default null) returns jsonb
language sql stable set search_path='' as $$
  select case when (select source from public.record_state) = 'supabase' then coalesce((
    select jsonb_agg(jsonb_build_object('name',r.name,'date',r.date_text,'script',r.script,'character',r.role,
      'rating',coalesce(r.rating::text,''),'comment',r.comment) order by r.submitted_at, r.id)
    from public.play_records r
    where not r.hidden and (p_script is null or regexp_replace(r.script,'[\t\n\v\f\r  　]+','','g')
                               = regexp_replace(p_script,'[\t\n\v\f\r  　]+','','g'))), '[]') end
$$;

create or replace function public._sf_records_summary() returns jsonb
language plpgsql stable set search_path='' as $$
declare now_tp timestamp := now() at time zone 'Asia/Taipei';
  m0 date := date_trunc('month', now_tp)::date; m1 date := (date_trunc('month', now_tp) + interval '1 month')::date;
  qids text[];
begin
  select coalesce(array_agg(id order by sort, id), '{}') into qids from public.record_quests where active and goal > 0;
  return coalesce((
    with led as (
      select player_id,
        coalesce(sum(points) filter (where points >= 0),0) earned,
        coalesce(sum(-points) filter (where points < 0),0) redeemed,
        coalesce(sum(points) filter (where points > 0 and earned_on >= m0 and earned_on < m1),0) month_earned
      from public.point_ledger where voided_at is null group by player_id),
    rec as (
      select player_id, count(distinct (script, date_text)) plays,
        (array_agg(date_text order by played_on desc nulls last, submitted_at desc))[1] last_date,
        count(*) filter (where status='earn' and played_on >= m0 and played_on < m1) m_plays,
        count(*) filter (where status='earn' and long_comment and played_on >= m0 and played_on < m1) m_comments,
        count(*) filter (where status='earn' and first_play and played_on >= m0 and played_on < m1) m_new
      from public.play_records where not hidden group by player_id),
    ref as (
      select referrer_id player_id, count(*) m_refs from public.play_records
      where referrer_id is not null and status='earn' and not hidden and played_on >= m0 and played_on < m1 group by referrer_id),
    rows as (
      select p.*, coalesce(l.earned,0) earned, coalesce(l.redeemed,0) redeemed, coalesce(l.month_earned,0) month_earned,
        coalesce(r.plays,0) plays, coalesce(r.last_date,'') last_date,
        coalesce(r.m_plays,0) m_plays, coalesce(r.m_comments,0) m_comments, coalesce(r.m_new,0) m_new, coalesce(f.m_refs,0) m_refs
      from public.record_players p
      left join led l on l.player_id=p.id left join rec r on r.player_id=p.id left join ref f on f.player_id=p.id
      where l.player_id is not null or r.player_id is not null)
    select jsonb_agg(jsonb_build_object(
      'name',name,'agent',coalesce(agent,''),'earned',earned,'redeemed',redeemed,'balance',earned-redeemed,
      'monthEarned',month_earned,'plays',plays,'last',last_date,
      'questProgress',case when m_plays > 0 or m_refs > 0 then
        (select coalesce(jsonb_object_agg(q, case q when '場次' then m_plays when '心得' then m_comments
           when '新本' then m_new when '揪團' then m_refs else 0 end),'{}') from unnest(qids) q) else '{}' end,
      'gilded',gilded,'title',title,'legend',legend) order by earned-redeemed desc, name)
    from rows), '[]');
end $$;

create or replace function public.submit_review_like(p_script text, p_date text, p_author text, p_liker uuid) returns jsonb
language plpgsql set search_path='' set lock_timeout='4s' as $$
declare c jsonb; s text := public._sf_clean_text(p_script,100); d text := public._sf_date_text(public._sf_clean_text(p_date,20));
  a text := public._sf_clean_text(p_author,30); i public.review_interactions; pid uuid; given integer; add integer; n integer;
begin
  if s = '' or d = '' or public._sf_name_norm(a) = '' or p_liker is null then raise exception 'INVALID_RECORD' using errcode='P0001'; end if;
  if (select source from public.record_state) <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  -- 先確認有這則心得（索引查詢、不鎖），亂按不存在的心得不會卡住其他人的送出；隱藏的心得不能按讚
  if not exists(select 1 from public.play_records r where r.script=s and r.date_text=d and not r.hidden
      and public._sf_name_norm(r.name)=public._sf_name_norm(a)) then
    raise exception 'REVIEW_NOT_FOUND' using errcode='P0001';
  end if;
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  if (select count(*) from public.review_likes where created_at > now()-interval '1 hour') >= 300 then
    raise exception 'TOO_MANY_REQUESTS' using errcode='P0001';
  end if;
  insert into public.review_interactions(script,date_text,author) values (s,d,a)
    on conflict (script,date_text,author_norm) do nothing;
  select * into i from public.review_interactions where script=s and date_text=d and author_norm=public._sf_name_norm(a);
  insert into public.review_likes(interaction_id,liker) values (i.id,p_liker) on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok',true,'likes',i.likes,'duplicate',true); end if;
  update public.review_interactions set likes=likes+1, updated_at=now() where id=i.id returning * into i;
  pid := public._sf_find_player(a);
  if pid is not null and exists(select 1 from public.play_records r where r.script=s and r.date_text=d
      and r.player_id=pid and r.status<>'backfill' and not r.hidden) then
    c := public._sf_record_config();
    given := coalesce((select sum(points) from public.point_ledger where interaction_id=i.id and kind='like' and voided_at is null),0);
    add := least((c->>'讚點數')::int, (c->>'讚點數上限')::int - given);
    if add > 0 then
      insert into public.point_ledger(player_id,kind,points,detail,script,date_text,earned_on,note,interaction_id,dedupe_key,source)
        values (pid,'like',add,'心得獲讚'||add,s,d,public._sf_parse_play_date(d),i.likes||' 個讚',i.id,'like|'||i.id||'|'||i.likes,'web')
        on conflict (dedupe_key) do nothing;
    end if;
  end if;
  return jsonb_build_object('ok',true,'likes',i.likes);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 權限：內部函式只給 service_role（公開 RPC 以呼叫者身分執行）；全部不給 anon／authenticated。
-- ---------------------------------------------------------------------------------------------
do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_store_write','_sf_balance','_sf_held','_sf_today_tp','_sf_player_by_name',
      '_sf_line_player','_sf_redemption_row','_sf_decide_redemption','my_redemptions','request_redemption','cancel_redemption',
      'admin_decide_redemption','admin_redeem','admin_redemptions','admin_adjust_points','admin_void_ledger','admin_hide_record',
      'admin_feature_record','admin_reviews','admin_players','admin_player','admin_set_glory','admin_set_alias','admin_merge_players',
      '_sf_guard_ledger','admin_record_settings','admin_save_setting','admin_save_reward','admin_save_quest','admin_records_report',
      'public_play_records','_sf_records_summary','submit_review_like') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
