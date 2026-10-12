begin;

-- 玩本記錄與點數（第 2 階段：取代網站 GoogleAppsScript_玩本記錄.gs 的計分）。
-- 規則的數字與條件與 Apps Script 相同，差別是「發了就固定」：每筆在送出當下照當時的設定算好、寫進帳本，
-- 之後改設定只影響新的點數，不再整批重算；修正一律另記一筆（作廢／補扣點，第 3 階段）。
-- 切換前（record_state.source='gas'）網站照舊用 Apps Script，這裡只用來匯入、對帳；
-- 店家在 LINE 店家畫面按「切換」後，網站送出、按讚、榮譽牆才改讀寫這裡。

-- ---------------------------------------------------------------------------------------------
-- 與 Apps Script 相同的文字處理（tests/play_records.sql 對照 .gs 的函式驗證過）
-- ---------------------------------------------------------------------------------------------

-- JavaScript 的空白（String.prototype.trim、\s）：ASCII 空白加上下列 Unicode 空白。
create function public._sf_js_trim(p text) returns text
language sql immutable parallel safe set search_path='' as $$
  select regexp_replace(coalesce(p,''),
    '^[\t\n\v\f\r    -     　﻿]+|[\t\n\v\f\r    -     　﻿]+$', '', 'g')
$$;

-- normalizeName_：去掉所有空白、轉小寫。名字比對（歸戶）一律用它。
create function public._sf_name_norm(p text) returns text
language sql immutable parallel safe set search_path='' as $$
  select lower(regexp_replace(coalesce(p,''), '[\t\n\v\f\r    -     　﻿]+', '', 'g'))
$$;

-- clean_：去掉控制字元、去頭尾空白、截長度。
create function public._sf_clean_text(p text, p_max integer) returns text
language sql immutable parallel safe set search_path='' as $$
  select left(public._sf_js_trim(regexp_replace(coalesce(p,''), '[\u0001-\u0008\u000b\u000c\u000e-\u001f]', '', 'g')), p_max)
$$;

-- parseDate_：以 / - . 分成三段以上、每段開頭是數字 → new Date(y, m-1, d)（會進位：2026/2/30 → 2026/3/2，
-- 0–99 年當 19xx 年）。其餘交給 JavaScript 的日期解析，這裡只會遇到 'YYYY/M'（該月 1 日）與 'YYYY'。
create function public._sf_parse_play_date(p text) returns date
language plpgsql immutable parallel safe set search_path='' as $$
declare t text := public._sf_js_trim(p); parts text[]; n int[] := '{}'; x text; y int;
begin
  parts := regexp_split_to_array(t, '[/.-]');
  if coalesce(array_length(parts,1),0) >= 3 then
    foreach x in array parts loop
      -- parseInt：可有前導空白與正負號，接著是數字，後面的字都忽略。
      if x !~ '^[\t\n\v\f\r    -     　﻿]*[+-]?\d' then return null; end if;
      n := n || substring(x from '[+-]?\d+')::int;
    end loop;
    y := case when n[1] between 0 and 99 then n[1]+1900 else n[1] end;
    if y not between 1000 and 9999 or abs(n[2]) > 1200 or abs(n[3]) > 40000 then return null; end if;
    return (make_date(y,1,1) + make_interval(months => n[2]-1, days => n[3]-1))::date;
  end if;
  if t ~ '^\d{4}[/.-]\d{1,3}$' and split_part(regexp_replace(t,'[.-]','/','g'),'/',2)::int between 1 and 12 then
    return make_date(left(t,4)::int, split_part(regexp_replace(t,'[.-]','/','g'),'/',2)::int, 1);
  end if;
  if t ~ '^\d{4}$' and t::int >= 1000 then return make_date(t::int,1,1); end if;
  return null;
end $$;

-- normalizeDate_：不補零的 Y/M/D；不是日期就原樣（去頭尾空白）。榮譽牆與帳本的「日期」都是這個格式。
create function public._sf_date_text(p text) returns text
language sql immutable parallel safe set search_path='' as $$
  select case when d is null then public._sf_js_trim(p)
    else extract(year from d)::int||'/'||extract(month from d)::int||'/'||extract(day from d)::int end
  from (select public._sf_parse_play_date(p) d) x
$$;

-- isDoubleDay_：平日／假日、星期（二、週三、星期四…）、0–6、或指定日期，逗號分隔。
create function public._sf_is_double_day(p_date date, p_text text, p_setting text) returns boolean
language plpgsql immutable parallel safe set search_path='' as $$
declare e text; dow int := case when p_date is null then -1 else extract(dow from p_date)::int end;
  labels text[] := array['日','一','二','三','四','五','六'];
begin
  foreach e in array regexp_split_to_array(public._sf_js_trim(p_setting), '[,，、;；]') loop
    e := public._sf_js_trim(e);
    if e = '' then continue; end if;
    if e ~ '^(平日|平常日|週間|周間)$' then if dow between 1 and 5 then return true; end if; continue; end if;
    if e ~ '^(假日|週末|周末|例假日)$' then if dow in (0,6) then return true; end if; continue; end if;
    if dow >= 0 and regexp_replace(e, '^(每週|每周|週|周|星期|禮拜)', '') = labels[dow+1] then return true; end if;
    if e ~ '^[0-6]$' and dow = e::int then return true; end if;
    if public._sf_date_text(e) = p_text then return true; end if;
  end loop;
  return false;
end $$;

-- charLength_：去掉空白後的字數（中文一字算一字）。
create function public._sf_char_count(p text) returns integer
language sql immutable parallel safe set search_path='' as $$
  select char_length(regexp_replace(coalesce(p,''), '[\t\n\v\f\r    -     　﻿]+', '', 'g'))
$$;

-- ---------------------------------------------------------------------------------------------
-- 資料表
-- ---------------------------------------------------------------------------------------------

-- 切換狀態（單列）。source='gas'：網站仍用 Apps Script；'supabase'：網站讀寫這裡。
create table public.record_state (
  id boolean primary key default true check (id),
  source text not null default 'gas' check (source in ('gas','supabase')),
  switched_at timestamptz,
  switched_by uuid references public.users(id) on delete set null,
  imported_at timestamptz,
  imported_by uuid references public.users(id) on delete set null,
  import_summary jsonb,
  sheet_cutoff timestamptz  -- 匯入時試算表「表單回應 1」最新一列的時間；之後的列由補匯入以新規則計點
);
insert into public.record_state default values;

-- 「設定」分頁（17 項，鍵名與 Apps Script 相同）。沒有的用預設值，讀取時才轉型（_sf_record_config）。
create table public.record_settings (
  key text primary key check (key in ('基本點數','心得點數','心得字數門檻','首玩點數','首探點數','新手好運點數',
    '介紹人點數','被介紹點數','每日上限筆數','讚點數','讚點數上限','精選點數','雙倍日','雙倍日文案',
    '回歸禮資格日','LINE上線日','補登寬限天數')),
  value text not null default '' check (char_length(value) <= 200),
  updated_at timestamptz not null default now()
);

-- 「獎勵」分頁。
create table public.record_rewards (
  id uuid primary key default gen_random_uuid(),
  sort integer not null default 0,
  track text not null default '' check (char_length(track) <= 20),
  name text not null check (char_length(name) between 1 and 60),
  cost integer not null default 0,
  note text not null default '' check (char_length(note) <= 200),
  active boolean not null default true
);

-- 「任務」分頁。id 是進度的種類：場次／心得／新本／揪團（其他 id 沒有進度，與 Apps Script 相同）。
create table public.record_quests (
  id text primary key check (char_length(id) between 1 and 20),
  sort integer not null default 0,
  label text not null default '' check (char_length(label) <= 100),  -- {目標} 會換成目標數字
  goal integer not null default 0,
  points integer not null default 0,
  active boolean not null default true
);

-- 「玩家」分頁：歸戶名（顯示名）、探員編號、加入日期、榮耀軌。名字比對用 name_norm（去空白、小寫）。
create table public.record_players (
  id uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(name) between 1 and 60),
  name_norm text not null unique generated always as (public._sf_name_norm(name)) stored check (name_norm <> ''),
  agent text unique check (agent is null or char_length(agent) between 1 and 20),  -- '#001'，第一筆記錄時給號，之後不變
  joined_on date,  -- 第一筆記錄的遊玩日；回歸禮資格日以它判斷
  gilded boolean not null default false,
  title text not null default '' check (char_length(title) <= 40),
  legend boolean not null default false,
  note text not null default '' check (char_length(note) <= 500),
  source text not null default 'web' check (source in ('web','sheet','store')),
  created_at timestamptz not null default now()
);

-- 別名歸戶：「海星⭐」「Michael」都算「海星」。
create table public.record_aliases (
  alias_norm text primary key check (alias_norm <> ''),
  alias text not null check (char_length(alias) between 1 and 60),
  player_id uuid not null references public.record_players(id) on delete cascade
);
create index record_aliases_player on public.record_aliases(player_id);

-- 一筆玩本記錄（網站送出或從試算表匯入）。status：
--   earn 計點；duplicate 同人同本同日已記過；daily_cap 超過每日上限；backfill 遊玩後太久才送出（補登）。
-- 作廢（voided）只讓點數失效，earn 的那筆仍佔著首玩／首探（店家定案）。
create table public.play_records (
  id uuid primary key default gen_random_uuid(),
  submitted_at timestamptz not null default now(),
  name text not null check (char_length(name) between 1 and 60),  -- 填寫的名字
  player_id uuid not null references public.record_players(id),
  script text not null check (char_length(script) between 1 and 100),  -- 劇本的 reviewKey
  date_text text not null check (char_length(date_text) between 1 and 40),
  played_on date,
  role text not null default '' check (char_length(role) <= 300),
  rating smallint check (rating between 1 and 5),
  comment text not null default '' check (char_length(comment) <= 2000),
  referrer text not null default '' check (char_length(referrer) <= 60),
  referrer_id uuid references public.record_players(id),  -- 介紹成立（介紹人有拿點）才有
  status text not null check (status in ('earn','duplicate','daily_cap','backfill')),
  first_play boolean not null default false,  -- 拿到首玩（算「新本」任務）
  long_comment boolean not null default false,  -- 心得達字數門檻（算「心得」任務）
  points integer not null default 0,  -- 這筆給填寫者的點數（含被介紹），送出時算好
  detail text not null default '' check (char_length(detail) <= 200),
  voided boolean not null default false,
  source text not null default 'web' check (source in ('web','sheet')),
  client_id uuid unique,  -- 網站的送出編號：同一份重送只記一次
  import_key text unique check (import_key is null or import_key ~ '^[0-9a-f]{64}$')  -- 試算表的一列
);
create index play_records_player on public.play_records(player_id, script, date_text);
create index play_records_script on public.play_records(script, status);
create index play_records_recent on public.play_records(submitted_at) where source='web';

-- 心得互動：每則心得（劇本＋日期＋作者）的讚數與精選。
create table public.review_interactions (
  id uuid primary key default gen_random_uuid(),
  script text not null check (char_length(script) between 1 and 100),
  date_text text not null check (char_length(date_text) between 1 and 40),
  author text not null check (char_length(author) between 1 and 60),
  author_norm text not null generated always as (public._sf_name_norm(author)) stored,
  likes integer not null default 0 check (likes >= 0),
  featured boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (script, date_text, author_norm)
);

-- 誰按過讚（每則心得、每個瀏覽器一次；網站不需登入）。
create table public.review_likes (
  interaction_id uuid not null references public.review_interactions(id) on delete cascade,
  liker uuid not null,
  created_at timestamptz not null default now(),
  primary key (interaction_id, liker)
);
create index review_likes_recent on public.review_likes(created_at);

-- 點數帳本（只增不改）。餘額＝未作廢的點數加總；作廢只填 voided_*。
--   record 記錄點數｜referred 被介紹｜referrer 介紹人｜quest 每月任務｜like 心得獲讚｜featured 精選心得
--   bonus 回歸禮｜redeem 兌換（負數）｜adjust 補點／扣點
-- dedupe_key 讓同一件事只發一次（例：quest|玩家|月份|任務、bonus|return|玩家、featured|心得）。
create table public.point_ledger (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.record_players(id),
  kind text not null check (kind in ('record','referred','referrer','quest','like','featured','bonus','redeem','adjust')),
  points integer not null,
  detail text not null default '' check (char_length(detail) <= 200),
  script text not null default '' check (char_length(script) <= 100),
  date_text text not null default '' check (char_length(date_text) <= 40),  -- 帳本的「日期」
  earned_on date,  -- 「本月點數」依這天的月份；回歸禮沒有日期，不算進本月
  note text not null default '' check (char_length(note) <= 300),
  record_id uuid references public.play_records(id),
  interaction_id uuid references public.review_interactions(id),
  dedupe_key text not null unique check (char_length(dedupe_key) between 1 and 300),
  source text not null check (source in ('web','sheet','line','store')),
  created_at timestamptz not null default now(),
  created_by uuid references public.users(id) on delete set null,
  voided_at timestamptz,
  voided_by uuid references public.users(id) on delete set null,
  void_reason text not null default '' check (char_length(void_reason) <= 200)
);
create index point_ledger_player on public.point_ledger(player_id) where voided_at is null;
create index point_ledger_record on public.point_ledger(record_id);
create index point_ledger_interaction on public.point_ledger(interaction_id);

-- 帳本只增不改：只能填作廢欄位；刪除只在切換前的整批重新匯入時允許。
create function public._sf_guard_ledger() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op = 'DELETE' then
    if (select source from public.record_state) <> 'gas' then raise exception 'LEDGER_APPEND_ONLY' using errcode='P0001'; end if;
    return old;
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
create trigger guard_ledger before update or delete on public.point_ledger
  for each row execute function public._sf_guard_ledger();

do $$ declare t text;
begin
  foreach t in array array['record_state','record_settings','record_rewards','record_quests','record_players','record_aliases',
    'play_records','review_interactions','review_likes','point_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public,anon,authenticated', t);
    execute format('grant select,insert,update,delete on public.%I to service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 設定、名字歸戶、探員編號
-- ---------------------------------------------------------------------------------------------

-- readConfig_：預設值＋「設定」覆寫；數值項轉數字（不是數字當 0），每日上限 0 當 99。
create function public._sf_record_config() returns jsonb
language plpgsql stable set search_path='' as $$
declare c jsonb := jsonb_build_object('基本點數','10','心得點數','5','心得字數門檻','15','首玩點數','5','首探點數','10',
    '新手好運點數','20','介紹人點數','10','被介紹點數','10','每日上限筆數','3','讚點數','2','讚點數上限','10','精選點數','20',
    '雙倍日','平日','雙倍日文案','平日開本，點數兩倍','回歸禮資格日','2026/10/06','LINE上線日','','補登寬限天數','7');
  k text; v text;
begin
  select c || coalesce(jsonb_object_agg(key, value), '{}') into c from public.record_settings;
  foreach k in array array['基本點數','心得點數','心得字數門檻','首玩點數','首探點數','新手好運點數','介紹人點數','被介紹點數',
    '每日上限筆數','讚點數','讚點數上限','精選點數','補登寬限天數'] loop
    v := public._sf_js_trim(c->>k);
    c := c || jsonb_build_object(k, case when v = '' then 0 when v ~ '^[+-]?(\d+\.?\d*|\.\d+)$' then round(v::numeric)::int else 0 end);
  end loop;
  if (c->>'每日上限筆數')::int = 0 then c := c || '{"每日上限筆數":99}'; end if;
  return c;
end $$;

-- canonicalName_：別名優先（Apps Script 第二輪別名會蓋過顯示名），其次顯示名；都沒有就是新玩家（null）。
create function public._sf_find_player(p_name text) returns uuid
language sql stable set search_path='' as $$
  select coalesce(
    (select player_id from public.record_aliases where alias_norm = public._sf_name_norm(p_name)),
    (select id from public.record_players where name_norm = public._sf_name_norm(p_name)))
$$;

-- 下一個探員編號：現有編號數字的最大值 +1，補到 3 位（#001）。
create function public._sf_next_agent() returns text
language sql stable set search_path='' as $$
  select '#'||lpad((coalesce(max(nullif(regexp_replace(agent,'[^0-9]','','g'),'')::bigint),0)+1)::text, 3, '0')
  from public.record_players where agent is not null
$$;

-- 找到或建立玩家。新玩家以填寫的名字（去頭尾空白）為歸戶名，並發探員編號、記加入日期。
-- 已有玩家但還沒有編號（店家為了設別名手動加的列）：這時補發編號，加入日期空白才補（assignAgentNumbers_）。
create function public._sf_ensure_player(p_name text, p_joined date, p_source text) returns uuid
language plpgsql set search_path='' as $$
declare pid uuid := public._sf_find_player(p_name); n text := left(public._sf_js_trim(p_name), 60);
begin
  if pid is not null then
    update public.record_players set agent = public._sf_next_agent(), joined_on = coalesce(joined_on, p_joined)
      where id = pid and agent is null;
    return pid;
  end if;
  if public._sf_name_norm(n) = '' then raise exception 'INVALID_RECORD' using errcode='P0001'; end if;
  insert into public.record_players(name, agent, joined_on, source) values (n, public._sf_next_agent(), p_joined, p_source)
    returning id into pid;
  return pid;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 計分（rebuildPoints_ 的規則，改成送出當下算一次）
-- ---------------------------------------------------------------------------------------------

-- 所有會寫帳本的動作都先鎖這一列，同時送出不會互相蓋掉首玩／首探、每日上限。
create function public._sf_records_lock() returns text
language sql set search_path='' as $$
  select source from public.record_state where id for update
$$;

-- 每月任務：本月（遊玩日的月份）進度達標就發一次，之後不收回（去重鍵：玩家＋月份＋任務）。
-- 場次＝計點的記錄數；心得＝其中達字數門檻的；新本＝其中拿到首玩的；揪團＝介紹成立的新玩家數。
create function public._sf_award_quests(p_player uuid, p_month date, p_kinds text[], p_source text) returns jsonb
language plpgsql set search_path='' as $$
declare q record; prog integer; out jsonb := '[]';
  m1 date := (p_month + interval '1 month')::date; mk text := to_char(p_month, 'YYYY/MM');
begin
  for q in select * from public.record_quests where active and goal > 0 and points > 0 and id = any(p_kinds) order by sort, id loop
    prog := case q.id
      when '場次' then (select count(*) from public.play_records where player_id=p_player and status='earn' and played_on>=p_month and played_on<m1)
      when '心得' then (select count(*) from public.play_records where player_id=p_player and status='earn' and long_comment and played_on>=p_month and played_on<m1)
      when '新本' then (select count(*) from public.play_records where player_id=p_player and status='earn' and first_play and played_on>=p_month and played_on<m1)
      when '揪團' then (select count(*) from public.play_records where referrer_id=p_player and status='earn' and played_on>=p_month and played_on<m1)
    end;
    if prog >= q.goal then
      insert into public.point_ledger(player_id,kind,points,detail,date_text,earned_on,note,dedupe_key,source)
        values (p_player,'quest',q.points,left(replace(q.label,'{目標}',q.goal::text)||' +'||q.points,200),mk,p_month,
          '每月任務達成（'||prog||'/'||q.goal||'）','quest|'||p_player||'|'||to_char(p_month,'YYYY-MM')||'|'||q.id,p_source)
        on conflict (dedupe_key) do nothing;
      if found then out := out || jsonb_build_array(jsonb_build_object('quest',q.id,'points',q.points)); end if;
    end if;
  end loop;
  return out;
end $$;

-- 一筆玩本記錄：判斷補登／重複／每日上限，算點數（基本、心得、首玩、首探、新手好運、雙倍日）、介紹、每月任務，
-- 全部寫進帳本。p_legacy：照 Apps Script 舊規則重播歷史資料（只算狀態、不寫帳本，帳本另外原樣匯入）。
-- 呼叫前要先 _sf_records_lock()。
create function public._sf_add_play_record(p jsonb, p_source text, p_submitted_at timestamptz, p_legacy boolean default false)
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
  v_day date := (p_submitted_at at time zone 'Asia/Taipei')::date;
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
  if v_date = '' then v_date := '—'; end if;  -- 舊表單偶有空白日期：照樣記錄（不會進任何月份）
  pid := public._sf_ensure_player(v_name, v_played, p_source);

  if launch is not null and v_played is not null and v_day >= launch
     and v_day - v_played > (c->>'補登寬限天數')::int then
    v_status := 'backfill';  -- 只記錄不給點，也不佔首玩、首探、介紹、每日上限、任務
  elsif exists(select 1 from public.play_records where player_id=pid and script=v_script and date_text=v_date
                 and status in ('earn','daily_cap')) then
    v_status := 'duplicate';
  elsif (select count(*) from public.play_records where player_id=pid and date_text=v_date
           and status in ('earn','daily_cap')) >= (c->>'每日上限筆數')::int then
    v_status := 'daily_cap';
  else
    v_status := 'earn';
    pts := (c->>'基本點數')::int; parts := parts || ('基本'||(c->>'基本點數'));
    if public._sf_char_count(v_comment) >= (c->>'心得字數門檻')::int then
      long_c := true; pts := pts + (c->>'心得點數')::int; parts := parts || ('心得'||(c->>'心得點數'));
    end if;
    if not exists(select 1 from public.play_records where player_id=pid and script=v_script and status='earn') then
      fp := true; pts := pts + (c->>'首玩點數')::int; parts := parts || ('首玩'||(c->>'首玩點數'));
    end if;
    if not exists(select 1 from public.play_records where script=v_script and status='earn') then
      pts := pts + (c->>'首探點數')::int; parts := parts || ('首探'||(c->>'首探點數'));
    end if;
    if not exists(select 1 from public.play_records where player_id=pid and status='earn') then
      ever := true; pts := pts + (c->>'新手好運點數')::int; parts := parts || ('新手好運'||(c->>'新手好運點數'));
    end if;
    if public._sf_is_double_day(v_played, v_date, c->>'雙倍日') then
      dbl := true; pts := pts * 2; parts := parts || '雙倍日 x2'::text;
    end if;
    -- 介紹人：只在被介紹者第一筆計點記錄結算一次，雙方都不加倍。
    -- 新規則（店家定案）：介紹人必須是已有的玩家，亂填的只記錄不給點。舊資料照 Apps Script 當時的判斷。
    if ever and v_referrer <> '' then
      ref_id := public._sf_find_player(v_referrer);
      if ref_id is null and p_legacy then  -- 舊規則：亂填的介紹人也拿點（點數總覽裡有這個名字，但沒有探員編號）
        insert into public.record_players(name, source) values (left(v_referrer,60), p_source) returning id into ref_id;
      end if;
      if ref_id = pid then ref_id := null; end if;
      if ref_id is not null then referred := (c->>'被介紹點數')::int; end if;
    end if;
  end if;

  insert into public.play_records(id,submitted_at,name,player_id,script,date_text,played_on,role,rating,comment,referrer,referrer_id,
      status,first_play,long_comment,points,detail,source,client_id,import_key)
    values (rid,p_submitted_at,v_name,pid,v_script,v_date,v_played,v_role,
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

-- 網站送出（不需登入，與 Apps Script 相同）。切換前回 RECORDS_NOT_LIVE，網站改送 Apps Script。
-- p_client_id：網站的送出編號，同一份重送不會記兩次。防灌：全站 10 分鐘 30 筆、一天 200 筆。
create function public.submit_play_record(p_record jsonb, p_client_id uuid default null) returns jsonb
language plpgsql set search_path='' as $$
declare r public.play_records;
begin
  if jsonb_typeof(p_record) is distinct from 'object' then raise exception 'INVALID_RECORD' using errcode='P0001'; end if;
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  if p_client_id is not null then
    select * into r from public.play_records where client_id = p_client_id;
    if found then
      return jsonb_build_object('id',r.id,'status',r.status,'duplicate',true,
        'award',case when r.status='earn' then jsonb_build_object('points',
          (select points from public.point_ledger where record_id=r.id and kind='record'),'detail',r.detail,'script',r.script) end);
    end if;
  end if;
  if (select count(*) from public.play_records where source='web' and submitted_at > now()-interval '10 minutes') >= 30
     or (select count(*) from public.play_records where source='web' and submitted_at > now()-interval '1 day') >= 200 then
    raise exception 'TOO_MANY_REQUESTS' using errcode='P0001';
  end if;
  return public._sf_add_play_record(p_record || jsonb_build_object('client_id',p_client_id), 'web', now());
end $$;

-- 心得按讚（recordLike_）：每讚給作者 2 點、每則最多 10 點；同一個瀏覽器（liker）對同一則只算一次。
-- 修掉舊問題：必須真的有這則記錄才算（以前對不存在的心得按讚也加點）；只有補登的記錄得讚不給點（與舊規則相同）。
create function public.submit_review_like(p_script text, p_date text, p_author text, p_liker uuid) returns jsonb
language plpgsql set search_path='' as $$
declare c jsonb; s text := public._sf_clean_text(p_script,100); d text := public._sf_date_text(public._sf_clean_text(p_date,20));
  a text := public._sf_clean_text(p_author,30); i public.review_interactions; pid uuid; given integer; add integer; n integer;
begin
  if s = '' or d = '' or public._sf_name_norm(a) = '' or p_liker is null then raise exception 'INVALID_RECORD' using errcode='P0001'; end if;
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  if not exists(select 1 from public.play_records r where r.script=s and r.date_text=d and public._sf_name_norm(r.name)=public._sf_name_norm(a)) then
    raise exception 'REVIEW_NOT_FOUND' using errcode='P0001';
  end if;
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
      and r.player_id=pid and r.status<>'backfill') then
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

-- 回歸禮（店家核准老玩家綁定時）：每個歸戶名一次（含已作廢的也不再發），加入日期早於「回歸禮資格日」才發。
-- 日期留空：不算進榮譽牆的「本月點數」。取代 Apps Script 的 grant_bonus，結果寫回綁定的 bonus_status。
create function public.grant_record_return_bonus(p_user_id uuid, p_points integer) returns jsonb
language plpgsql set search_path='' as $$
declare b public.player_bindings; pl public.record_players; c jsonb; cutoff date; st text;
begin
  if p_points is null or p_points not between 1 and 500 then raise exception 'INVALID_POINTS' using errcode='P0001'; end if;
  if public._sf_records_lock() <> 'supabase' then raise exception 'RECORDS_NOT_LIVE' using errcode='P0001'; end if;
  select * into b from public.player_bindings where user_id=p_user_id and status='approved' for update;
  if not found then raise exception 'BINDING_NOT_FOUND' using errcode='P0001'; end if;
  if b.bonus_status <> 'none' then return public._sf_binding_row(b); end if;
  select * into pl from public.record_players where id = public._sf_find_player(b.record_name);
  if not found then raise exception 'NAME_NOT_FOUND' using errcode='P0001'; end if;
  c := public._sf_record_config();
  cutoff := public._sf_parse_play_date(c->>'回歸禮資格日');
  if exists(select 1 from public.point_ledger where dedupe_key='bonus|return|'||pl.id) then st := 'already';
  elsif cutoff is not null and (pl.joined_on is null or pl.joined_on >= cutoff) then st := 'ineligible';
  else
    insert into public.point_ledger(player_id,kind,points,detail,note,dedupe_key,source)
      values (pl.id,'bonus',p_points,'老玩家回歸禮（LINE 綁定）','LINE 綁定','bonus|return|'||pl.id,'line');
    st := 'granted';
  end if;
  return public.mark_binding_bonus(p_user_id, st);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 公開資料（buildPublicPayload_ 的同一個 JSON 格式，網站與 LINE 會員卡讀它）
-- ---------------------------------------------------------------------------------------------

-- 每位玩家：累積、已兌換、餘額、本月點數、場次（同人同本同日算一場）、最後遊玩日、本月任務進度、榮耀軌。
-- 列出的玩家＝有記錄或有未作廢帳本的人（與點數總覽相同）。本月以台北時間計。
-- 修掉舊問題：本月任務進度的月份格式對不上，以前一直是空的。
create function public._sf_records_summary() returns jsonb
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
      from public.play_records group by player_id),
    ref as (
      select referrer_id player_id, count(*) m_refs from public.play_records
      where referrer_id is not null and status='earn' and played_on >= m0 and played_on < m1 group by referrer_id),
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

create function public._sf_records_payload() returns jsonb
language plpgsql stable set search_path='' as $$
declare c jsonb := public._sf_record_config(); now_tp timestamp := now() at time zone 'Asia/Taipei'; rules jsonb;
begin
  select coalesce(jsonb_agg(x order by n),'[]') into rules from (values
    (1, jsonb_build_object('label','完成一筆玩本記錄','points',c->'基本點數')),
    (2, jsonb_build_object('label','心得寫滿 '||(c->>'心得字數門檻')||' 字','points',c->'心得點數')),
    (3, jsonb_build_object('label','第一次玩這個劇本','points',c->'首玩點數')),
    (4, jsonb_build_object('label','全店第一個玩這個劇本','points',c->'首探點數')),
    (5, jsonb_build_object('label','生涯第一筆記錄（新手好運）','points',c->'新手好運點數')),
    (6, jsonb_build_object('label','介紹新朋友來（雙方各得）','points',c->'介紹人點數')),
    (7, jsonb_build_object('label','心得每被按一個讚','points',c->'讚點數','note','單則最多 '||(c->>'讚點數上限')||' 點')),
    (8, jsonb_build_object('label','心得被選為精選','points',c->'精選點數'))) v(n, x)
  where (x->>'points')::int > 0;
  if public._sf_js_trim(c->>'雙倍日') <> '' then
    rules := rules || jsonb_build_array(jsonb_build_object('label',coalesce(nullif(c->>'雙倍日文案',''),'雙倍點數日'),
      'multiplier',2,'note','當天所有點數加倍'));
  end if;
  return jsonb_build_object(
    'ok', true,
    'updatedAt', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'monthKey', extract(year from now_tp)::int||'/'||extract(month from now_tp)::int,
    'doubleDayNote', coalesce(c->>'雙倍日文案',''),
    'summary', public._sf_records_summary(),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('track',track,'name',name,'cost',cost,'note',note,'active',true)
       order by sort, name) from public.record_rewards where active),'[]'),
    'mystery', coalesce((select jsonb_agg(jsonb_build_object('name',p.name,'prize',substr(l.note,4),'date',l.date_text)
       order by l.created_at, l.id) from public.point_ledger l join public.record_players p on p.id=l.player_id
       where l.voided_at is null and l.note like '開出：%'),'[]'),
    'interactions', coalesce((select jsonb_agg(jsonb_build_object('script',script,'date',date_text,'author',author,
       'likes',likes,'featured',featured) order by script, date_text, author) from public.review_interactions),'[]'),
    'quests', coalesce((select jsonb_agg(jsonb_build_object('id',id,'label',replace(label,'{目標}',goal::text),'goal',goal,'points',points)
       order by sort, id) from public.record_quests where active and goal > 0),'[]'),
    'rules', rules);
end $$;

-- 網站的點數總覽：切換後才由這裡產生；切換前回 null（api 照舊用 Apps Script 的副本）。
create function public.public_records_payload() returns jsonb
language sql stable set search_path='' as $$
  select case when (select source from public.record_state) = 'supabase' then public._sf_records_payload() end
$$;

-- 榮譽牆與劇本頁的玩家心得（取代 Google 發布的 CSV）：只給畫面需要的欄位，不給填寫時間與介紹人。
-- 順序與試算表相同（送出順序）；評價給文字（網站與 CSV 一樣讀字串）。p_script 比對時忽略空白（劇本頁以檔名找）。
create function public.public_play_records(p_script text default null) returns jsonb
language sql stable set search_path='' as $$
  select case when (select source from public.record_state) = 'supabase' then coalesce((
    select jsonb_agg(jsonb_build_object('name',r.name,'date',r.date_text,'script',r.script,'character',r.role,
      'rating',coalesce(r.rating::text,''),'comment',r.comment) order by r.submitted_at, r.id)
    from public.play_records r
    where p_script is null or regexp_replace(r.script,'[\t\n\v\f\r \u00a0\u3000]+','','g')
                               = regexp_replace(p_script,'[\t\n\v\f\r \u00a0\u3000]+','','g')), '[]') end
$$;

-- 目前網站讀寫哪一邊（api 依它分流：名字清單、會員卡、取名、回歸禮、自動補匯入）。
create function public.records_source() returns text
language sql stable set search_path='' as $$ select source from public.record_state $$;

-- LINE：名字清單（老玩家綁定的選單）、會員卡、取新名字前的檢查。切換前回 null，api 照舊讀 Apps Script 的副本。
create function public.record_names() returns jsonb
language sql stable set search_path='' as $$
  select case when (select source from public.record_state) = 'supabase' then coalesce((
    select jsonb_agg(jsonb_build_object('name',x->>'name','agent',x->>'agent','plays',(x->>'plays')::int,'last',x->>'last'))
    from jsonb_array_elements(public._sf_records_summary()) x), '[]') end
$$;

create function public.record_card(p_name text) returns jsonb
language sql stable set search_path='' as $$
  select case when (select source from public.record_state) = 'supabase' then jsonb_build_object(
    'card', (select x from jsonb_array_elements(public._sf_records_summary()) x where x->>'name' = public._sf_js_trim(p_name)),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('track',track,'name',name,'cost',cost,'note',note) order by sort, name)
       from public.record_rewards where active),'[]')) end
$$;

-- 這個名字（含別名、大小寫與空白不同的寫法）是否已屬於某位玩家：新玩家取名時不能取到別人的點數。
create function public.record_name_taken(p_name text) returns boolean
language sql stable set search_path='' as $$
  select public._sf_find_player(p_name) is not null
$$;

-- ---------------------------------------------------------------------------------------------
-- 店家：匯入、對帳、切換
-- ---------------------------------------------------------------------------------------------

-- 從「玩本記錄」試算表整批匯入（只在切換前；每次都整批取代，可以重複匯入到對帳一致為止）。
-- api 以服務帳戶讀取試算表後整理成：
--   config [{key,value}]、rewards [{track,name,cost,note,active}]、quests [{id,label,goal,points,active}]、
--   players [{name,aliases[],agent,joined,note,gilded,title,legend}]、
--   responses [{key,stamp,name,date,script,role,rating,comment,referrer}]（表單回應 1，試算表順序）、
--   ledger [{stamp,player,type,points,detail,script,date,source,status,note,key}]（點數帳本，試算表順序）、
--   interactions [{script,date,author,likes,featured,updated}]（心得互動）。
-- 帳本照 Apps Script 已算好的點數原樣搬（固定）；記錄的狀態（計點／重複／每日上限／補登）與首玩、心得、介紹
-- 依舊規則重播一次，供切換後的首玩／首探、每日上限、每月任務接著判斷。
create function public._sf_import_play_records(p_actor uuid, p jsonb) returns jsonb
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

  delete from public.point_ledger; delete from public.review_likes; delete from public.review_interactions;
  delete from public.play_records; delete from public.record_aliases; delete from public.record_players;
  delete from public.record_settings; delete from public.record_rewards; delete from public.record_quests;

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
      coalesce((x->>'stamp')::timestamptz, now()), true);
    n_records := n_records + 1;
  end loop;

  -- 點數帳本：原樣搬。玩家以「歸戶名」（空白時用玩家名）的顯示名對應（點數總覽就是這樣分人）；找不到就建一位。
  for x, i in select e, o from jsonb_array_elements(p->'ledger') with ordinality t(e,o) loop
    k := left(public._sf_js_trim(coalesce(nullif(public._sf_js_trim(x->>'player'),''), x->>'name')),60);
    if public._sf_name_norm(k) = '' then continue; end if;
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

  select max((e->>'stamp')::timestamptz) into cutoff from jsonb_array_elements(p->'responses') e;
  update public.record_state set imported_at=now(), imported_by=p_actor, sheet_cutoff=cutoff,
    import_summary=jsonb_build_object('players',(select count(*) from public.record_players),'records',n_records,
      'ledger',n_ledger,'interactions',n_inter,'anomalies',jsonb_array_length(anomalies));
  perform public._sf_audit(p_actor,'records.import','record_state',null,
    jsonb_build_object('records',n_records,'ledger',n_ledger,'players',n_players));
  return jsonb_build_object('players',(select count(*) from public.record_players),'records',n_records,'ledger',n_ledger,
    'interactions',n_inter,'anomalies',anomalies,'sheetCutoff',cutoff);
end $$;

create function public.admin_import_play_records(p_actor uuid, p_data jsonb) returns jsonb
language plpgsql set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return public._sf_import_play_records(p_actor, p_data);
end $$;

-- 切換後，網站連不上預約系統時會改送 Apps Script：把試算表裡「匯入之後」的新列補進來，以新規則計點。
-- 依送出時間順序；已匯入過的列（去重鍵）略過。
create function public._sf_import_new_play_records(p_actor uuid, p_rows jsonb) returns jsonb
language plpgsql set search_path='' as $$
declare x jsonb; st public.record_state; added integer := 0; skipped integer := 0; res jsonb;
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
    exception when others then skipped := skipped + 1;  -- 一列壞掉不擋其他列
    end;
  end loop;
  if added > 0 then
    perform public._sf_audit(p_actor,'records.import_new','record_state',null,jsonb_build_object('added',added,'skipped',skipped));
  end if;
  return jsonb_build_object('added',added,'skipped',skipped);
end $$;

create function public.admin_import_new_play_records(p_actor uuid, p_rows jsonb) returns jsonb
language plpgsql set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return public._sf_import_new_play_records(p_actor, p_rows);
end $$;

create function public.system_import_new_play_records(p_rows jsonb) returns jsonb
language sql set search_path='' as $$ select public._sf_import_new_play_records(null, p_rows) $$;

-- 對帳：每位玩家的累積、已兌換、餘額、場次、最後遊玩日、探員編號，與 Apps Script 最後一次的點數總覽（play_record_snapshot）逐一比對。
create function public.admin_records_reconcile(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare gas jsonb; mine jsonb; diffs jsonb; only_gas jsonb; only_mine jsonb; snap public.play_record_snapshot;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into snap from public.play_record_snapshot where id=1;
  gas := coalesce(snap.payload->'summary','[]');
  mine := public._sf_records_summary();
  with g as (select x->>'name' n, x from jsonb_array_elements(gas) x where coalesce(x->>'name','')<>''),
       s as (select x->>'name' n, x from jsonb_array_elements(mine) x),
       f(field) as (values ('earned'),('redeemed'),('balance'),('plays'),('last'),('agent'))
  select coalesce(jsonb_agg(jsonb_build_object('name',g.n,'field',f.field,'gas',g.x->f.field,'supabase',s.x->f.field)
           order by g.n, f.field),'[]')
    into diffs from g join s on s.n=g.n cross join f
    where case when f.field in ('earned','redeemed','balance','plays')
      then coalesce((g.x->>f.field)::numeric,0) <> coalesce((s.x->>f.field)::numeric,0)
      else coalesce(g.x->>f.field,'') <> coalesce(s.x->>f.field,'') end;
  select coalesce(jsonb_agg(x->>'name' order by x->>'name'),'[]') into only_gas from jsonb_array_elements(gas) x
    where coalesce(x->>'name','')<>'' and not exists(select 1 from jsonb_array_elements(mine) y where y->>'name'=x->>'name');
  select coalesce(jsonb_agg(x->>'name' order by x->>'name'),'[]') into only_mine from jsonb_array_elements(mine) x
    where not exists(select 1 from jsonb_array_elements(gas) y where y->>'name'=x->>'name');
  return jsonb_build_object('snapshotAt',snap.fetched_at,'gasPlayers',jsonb_array_length(gas),'supabasePlayers',jsonb_array_length(mine),
    'differences',diffs,'onlyGas',only_gas,'onlySupabase',only_mine,
    'matched',jsonb_array_length(diffs)=0 and jsonb_array_length(only_gas)=0 and jsonb_array_length(only_mine)=0
      and jsonb_array_length(gas)>0);
end $$;

create function public.admin_records_status(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare st public.record_state;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into st from public.record_state;
  return jsonb_build_object('source',st.source,'switchedAt',st.switched_at,'importedAt',st.imported_at,'importSummary',st.import_summary,
    'sheetCutoff',st.sheet_cutoff,'players',(select count(*) from public.record_players),'records',(select count(*) from public.play_records),
    'webRecords',(select count(*) from public.play_records where source='web'),
    'ledger',(select count(*) from public.point_ledger),'snapshotAt',(select fetched_at from public.play_record_snapshot where id=1));
end $$;

-- 切換：'supabase' 之後網站讀寫這裡；切回 'gas' 只用於緊急退回（切換後在這裡新增的記錄不會出現在試算表）。
-- 切到 supabase 前必須匯入過，並且對帳一致（p_force 可略過對帳，例如差異已確認是試算表的錯）。
create function public.admin_set_records_source(p_actor uuid, p_source text, p_force boolean default false) returns jsonb
language plpgsql set search_path='' as $$
declare st public.record_state;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  if p_source not in ('gas','supabase') then raise exception 'INVALID_SOURCE' using errcode='P0001'; end if;
  perform public._sf_records_lock();
  select * into st from public.record_state;
  if p_source = 'supabase' and st.imported_at is null then raise exception 'IMPORT_REQUIRED' using errcode='P0001'; end if;
  if p_source = 'supabase' and not coalesce(p_force,false) and not (public.admin_records_reconcile(p_actor)->>'matched')::boolean then
    raise exception 'RECONCILE_MISMATCH' using errcode='P0001';
  end if;
  update public.record_state set source=p_source, switched_at=now(), switched_by=p_actor;
  perform public._sf_audit(p_actor,'records.source','record_state',null,jsonb_build_object('source',p_source,'force',coalesce(p_force,false)));
  return public.admin_records_status(p_actor);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_js_trim','_sf_name_norm','_sf_clean_text','_sf_parse_play_date','_sf_date_text',
      '_sf_is_double_day','_sf_char_count','_sf_guard_ledger','_sf_record_config','_sf_find_player','_sf_next_agent','_sf_ensure_player',
      '_sf_records_lock','_sf_award_quests','_sf_add_play_record','_sf_records_summary','_sf_records_payload','_sf_import_play_records',
      '_sf_import_new_play_records') loop
    execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('submit_play_record','submit_review_like','grant_record_return_bonus',
      'public_records_payload','public_play_records','record_names','record_card','record_name_taken','records_source',
      'admin_import_play_records','admin_import_new_play_records','system_import_new_play_records',
      'admin_records_reconcile','admin_records_status','admin_set_records_source') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
