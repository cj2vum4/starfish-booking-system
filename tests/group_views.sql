-- Run in Supabase SQL Editor after 202610030006_group_views.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  org uuid; u2 uuid; stranger uuid; g uuid; gid uuid; r jsonb; msg text; sat date; t1 timestamptz;
  h_join text := encode(sha256(convert_to('qa-view-join','UTF8')),'hex');
  h_seat text := encode(sha256(convert_to('qa-view-seat','UTF8')),'hex');
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f001','主揪小明') returning id into org;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f002','小華') returning id into u2;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f003','路人') returning id into stranger;
  insert into public.games(slug,title,min_players,max_players,price_cents,active)
    values ('qa-view-game','QA 劇本',2,6,60000,true) returning id into g;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date in (sat)) loop sat:=sat+7; end loop;
  t1 := (sat+time '14:00') at time zone 'Asia/Taipei';

  r := public.create_group(org,gen_random_uuid(),t1,6,g,'{推理,還原}','第一次玩','private');
  gid := (r->>'group_id')::uuid;
  perform public.create_group_invite(org,gid,h_join,now()+interval '3 days');
  perform public.reserve_group_seat(org,gid,'涵涵',h_seat,now()+interval '3 days');

  -- 主揪看得到完整座位與名字。
  r := public.get_group(org,gid);
  if not (r->>'is_organizer')::boolean or jsonb_array_length(r->'seats')<>6 or (r->>'filled')::int<>2
    or r->>'game_title'<>'QA 劇本' or (r->>'starts_at')::timestamptz<>t1
    or (r->>'ends_at')::timestamptz<>t1+interval '4 hours' then raise exception 'organizer view wrong: %', r; end if;
  if not exists(select 1 from jsonb_array_elements(r->'seats') s where s->>'name'='涵涵' and s->>'status'='reserved')
    then raise exception 'reserved seat name missing'; end if;

  -- 私人團：沒加入的人不能看；拿到邀請的人只看到摘要，看不到座位名字。
  begin
    perform public.get_group(stranger,gid);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_NOT_FOUND' then raise exception 'stranger saw private group: %', msg; end if;
  end;
  r := public.preview_invite(stranger,h_join);
  if r->>'purpose'<>'join_group' or not (r->>'usable')::boolean or r->>'organizer_name'<>'主揪小明'
    or (r->>'filled')::int<>2 or r ? 'seats' then raise exception 'invite preview wrong: %', r; end if;
  r := public.preview_invite(stranger,h_seat);
  if r->>'purpose'<>'claim_group_seat' or r->>'reserved_for'<>'涵涵' then raise exception 'seat preview wrong: %', r; end if;

  -- 加入後成為成員，看得到座位；我的揪團列出這團。
  perform public.claim_invite(u2,h_join);
  r := public.get_group(u2,gid);
  if not (r->>'is_member')::boolean or (r->>'is_organizer')::boolean or r->'seats' is null then raise exception 'member view wrong'; end if;
  if (select count(*) from jsonb_array_elements(r->'seats') s where (s->>'is_me')::boolean)<>1 then raise exception 'is_me wrong'; end if;
  if jsonb_array_length(public.list_my_groups(u2))<>1 or jsonb_array_length(public.list_my_groups(org))<>1
    or jsonb_array_length(public.list_my_groups(stranger))<>0 then raise exception 'my groups wrong'; end if;

  -- 已被認領的保留位不可再用；解散後邀請不可用、我的揪團不再列出。
  perform public.claim_invite(stranger,h_seat);
  r := public.preview_invite(u2,h_seat);
  if (r->>'usable')::boolean then raise exception 'used seat invite still usable'; end if;
  if not (public.preview_invite(stranger,h_seat)->>'claimed_by_me')::boolean then raise exception 'claimed_by_me wrong'; end if;
  perform public.cancel_group(org,gid);
  if (public.preview_invite(stranger,h_join)->>'usable')::boolean then raise exception 'invite usable after cancel'; end if;
  if jsonb_array_length(public.list_my_groups(org))<>0 then raise exception 'cancelled group listed'; end if;

  if jsonb_array_length(public.list_active_games())<1 then raise exception 'games not listed'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.get_group(uuid,uuid)','EXECUTE')
      or has_function_privilege(r,'public.preview_invite(uuid,text)','EXECUTE')
      or has_function_privilege(r,'public.list_my_groups(uuid)','EXECUTE')
      then raise exception 'group view exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: organizer view, private visibility, invite preview, member view, my groups, used and cancelled invites' as result;
rollback;
