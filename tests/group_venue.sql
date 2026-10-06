-- Run in Supabase SQL Editor after 202610070031_group_venue_share.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare org uuid; other uuid; g uuid; gid uuid; gid2 uuid; r jsonb; msg text; sat date;
begin
  delete from public.calendar_busy;  -- isolation from real data; rolled back
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d7b1','主揪') returning id into org;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d7b2','路人') returning id into other;
  insert into public.games(slug,title,min_players,max_players,duration_minutes,players_label,source_url,video_url)
    values ('qa-venue','QA 場地本',2,6,240,'3男3女','https://site.example/qa.html','https://youtu.be/qa') returning id into g;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;

  -- 開團帶場地；沒帶就是南港。
  gid := (public.create_group(org,gen_random_uuid(),(sat+time '09:00') at time zone 'Asia/Taipei',6,g,'{}','','private','新竹交大')->>'group_id')::uuid;
  gid2 := (public.create_group(org,gen_random_uuid(),(sat+time '14:00') at time zone 'Asia/Taipei',6,g)->>'group_id')::uuid;
  if (select venue from public.groups where id=gid)<>'新竹交大' or (select venue from public.groups where id=gid2)<>'南港' then raise exception 'venue not stored'; end if;
  begin perform public.create_group(org,gen_random_uuid(),(sat+time '19:00') at time zone 'Asia/Taipei',6,g,'{}','','private','  '); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'INVALID_VENUE' then raise exception 'blank venue: %', msg; end if; end;

  -- 分享訊息需要的資料都在揪團摘要裡。
  r := public.get_group(org,gid);
  if r->>'venue'<>'新竹交大' or r->>'game_players_label'<>'3男3女' or r->>'game_source_url'<>'https://site.example/qa.html'
    or r->>'game_video_url'<>'https://youtu.be/qa' or not (r ? 'game_price_cents') then raise exception 'summary missing share facts: %', r; end if;

  -- 只有主揪能在成團前改場地（可自選地點）。
  r := public.set_group_venue(org,gid,'  松山文創園區 ');
  if r->>'venue'<>'松山文創園區' or (select venue from public.groups where id=gid)<>'松山文創園區' then raise exception 'venue change wrong: %', r; end if;
  begin perform public.set_group_venue(other,gid,'北車'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'GROUP_NOT_FOUND' then raise exception 'stranger changed venue: %', msg; end if; end;
  begin perform public.set_group_venue(org,gid,repeat('地',61)); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'INVALID_VENUE' then raise exception 'long venue: %', msg; end if; end;
  perform public.cancel_group(org,gid2);
  begin perform public.set_group_venue(org,gid2,'北車'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'GROUP_CLOSED' then raise exception 'closed group changed: %', msg; end if; end;

  -- 劇本同步帶影片連結，只收 https。
  perform public._sf_apply_catalog(null,'[{"slug":"qa-venue","title":"QA 場地本","min_players":2,"max_players":6,"duration_minutes":240,"video_url":"javascript:alert(1)"}]'::jsonb,'qa');
  if (select video_url from public.games where slug='qa-venue') is not null then raise exception 'unsafe video kept'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.set_group_venue(uuid,uuid,text)','EXECUTE')
      or has_function_privilege(r,'public.create_group(uuid,uuid,timestamptz,integer,uuid,text[],text,text,text)','EXECUTE')
      then raise exception 'venue RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: venue stored and defaulted, share facts in summary, organizer-only change before confirmation, https-only video, privileges' as result;
rollback;
