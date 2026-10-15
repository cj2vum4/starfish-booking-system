-- Run in Supabase SQL Editor after 202610150041_point_rules.sql. All synthetic records are rolled back.
-- Point rules from 2026-10-15: a double day doubles only the base points; a first record gets 新手好運 (5) instead of 首玩.
begin;
set local role service_role;
do $$
declare
  r jsonb; rules jsonb;
  today text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/FMMM/FMDD');
begin
  if (public._sf_record_config()->>'新手好運點數')::int <> 5 then raise exception '新手好運 not 5: %', public._sf_record_config()->>'新手好運點數'; end if;
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key)
    values ('pr-test-a','pr-test A',1,8,0,'PRA'), ('pr-test-b','pr-test B',1,8,0,'PRB'), ('pr-test-c','pr-test C',1,8,0,'PRC');
  update public.record_quests set active = false where true;
  insert into public.record_settings(key,value)
    select k, v from (values ('基本點數','10'),('心得點數','5'),('心得字數門檻','15'),('首玩點數','5'),('首探點數','10'),
      ('每日上限筆數','3'),('雙倍日','')) t(k,v)
    on conflict (key) do update set value = excluded.value;
  update public.record_state set source='supabase', went_live_at=now() where id;

  -- First record, no double day: 基本10＋心得5＋首探10＋新手好運5 (no 首玩) = 30.
  r := public.submit_play_record(jsonb_build_object('name','pr新人','date',today,'script','PRA','role','A','rating','5',
    'comment','這是一段超過十五個字的心得內容真的很好玩'));
  if (r->'award'->>'points')::int <> 30 or r->'award'->>'detail' <> '基本10＋心得5＋首探10＋新手好運5' then raise exception 'first record %', r; end if;
  if not (select first_play from public.play_records where id = (r->>'id')::uuid) then raise exception 'first record lost 新本'; end if;

  -- Double day: only the base doubles. Second script: 基本10x2＋心得5＋首玩5＋首探10 = 40.
  update public.record_settings set value = today where key = '雙倍日';
  r := public.submit_play_record(jsonb_build_object('name','pr新人','date',today,'script','PRB','role','A','rating','5',
    'comment','這也是一段超過十五個字的心得內容很推薦'));
  if (r->'award'->>'points')::int <> 40 or r->'award'->>'detail' <> '基本10＋心得5＋首玩5＋首探10＋雙倍日 基本x2' then raise exception 'double day %', r; end if;
  -- A newcomer on a double day: 基本10x2＋首探10＋新手好運5 = 35.
  r := public.submit_play_record(jsonb_build_object('name','pr新人二','date',today,'script','PRC','role','A','rating','4'));
  if (r->'award'->>'points')::int <> 35 then raise exception 'newcomer on a double day %', r; end if;

  rules := public._sf_records_payload()->'rules';
  if not exists(select 1 from jsonb_array_elements(rules) x where x->>'note' = '當天基本點數加倍')
     or not exists(select 1 from jsonb_array_elements(rules) x where x->>'label' = '生涯第一筆記錄（新手好運，取代首玩）' and (x->>'points')::int = 5) then
    raise exception 'rules text %', rules; end if;
end $$;
reset role;
select 'PASS: point rules (double day doubles the base only, 新手好運 5 replaces 首玩)' as result;
rollback;
