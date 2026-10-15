-- Run in Supabase SQL Editor after 202610150042_referrer_from_list.sql. All synthetic records are rolled back.
-- A website first record naming a referrer who is not a player is sent back whole (REFERRER_NOT_FOUND);
-- a listed referrer (any spacing or case, or an alias) pays as before; a returning player's referrer is ignored;
-- a spreadsheet catch-up row with an unknown referrer is still recorded without referral points.
begin;
set local role service_role;
do $$
declare
  r jsonb;
  today text := to_char(now() at time zone 'Asia/Taipei', 'YYYY/FMMM/FMDD');
begin
  insert into public.games(slug,title,min_players,max_players,price_cents,review_key)
    values ('rl-test-a','rl-test A',1,8,0,'RLA'), ('rl-test-b','rl-test B',1,8,0,'RLB');
  update public.record_quests set active = false where true;
  update public.record_state set source='supabase', went_live_at=now() where id;
  perform public.submit_play_record(jsonb_build_object('name','rl Amy','date',today,'script','RLA','role','A','rating','5'));

  -- Unknown referrer: nothing written, not even the new player.
  begin
    perform public.submit_play_record(jsonb_build_object('name','rl新人','date',today,'script','RLA','role','A','rating','5','referrer','rl打錯字'));
    raise exception 'unknown referrer accepted';
  exception when others then if sqlerrm <> 'REFERRER_NOT_FOUND' then raise; end if; end;
  if exists(select 1 from public.record_players where name in ('rl新人','rl打錯字')) then raise exception 'rejected record left a player'; end if;

  -- Listed referrer, written differently: both get the referral points.
  r := public.submit_play_record(jsonb_build_object('name','rl新人','date',today,'script','RLA','role','A','rating','5','referrer','RLAMY'));
  if not exists(select 1 from jsonb_array_elements(r->'award'->'extra') x where x->>'detail' like '被介紹%') then raise exception 'listed referrer not paid %', r; end if;
  if not exists(select 1 from public.point_ledger l join public.record_players p on p.id = l.player_id where p.name = 'rl Amy' and l.kind = 'referrer') then
    raise exception 'referrer not paid'; end if;

  -- A returning player's referrer is ignored, even an unknown one (an old page may still send it).
  r := public.submit_play_record(jsonb_build_object('name','rl新人','date',today,'script','RLB','role','A','rating','5','referrer','rl打錯字'));
  if r->>'status' <> 'earn' or exists(select 1 from jsonb_array_elements(r->'award'->'extra') x where x->>'detail' like '被介紹%') then
    raise exception 'returning player referral %', r; end if;

  -- A spreadsheet catch-up row (the website fell back to the Apps Script) is recorded, no referral points.
  r := public._sf_add_play_record(jsonb_build_object('name','rl表單新人','date',today,'script','RLA','role','A','rating','4','referrer','rl打錯字'), 'sheet', now());
  if r->>'status' <> 'earn' or exists(select 1 from public.point_ledger l join public.record_players p on p.id = l.player_id
      where p.name = 'rl表單新人' and l.kind = 'referred') then raise exception 'sheet row with unknown referrer %', r; end if;
end $$;
reset role;
select 'PASS: referrer from the list (unknown sent back, spacing/case, returning player, sheet catch-up)' as result;
rollback;
