-- Run in Supabase SQL Editor after 202610030012_public_groups.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  org uuid; u2 uuid; u3 uuid; g uuid; gid uuid; full_gid uuid; r jsonb; msg text; sat date;
  listed boolean;
begin
  -- Isolation from real data: the busy mirror is cleared and dates skip days with a live
  -- session. Everything here is rolled back at the end.
  delete from public.calendar_busy;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f1b1','主揪') returning id into org;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f1b2','小華') returning id into u2;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000f1b3','小美') returning id into u3;
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-public','QA 公開本',2,6,240) returning id into g;
  sat := (now() at time zone 'Asia/Taipei')::date+1; sat := sat+((6-extract(dow from sat)::int+7)%7);
  while exists(select 1 from public.time_slots where status<>'released' and (starts_at at time zone 'Asia/Taipei')::date=sat)
    loop sat:=sat+7; end loop;

  -- 私人團不出現在缺人場次，陌生人也不能直接加入。
  gid := (public.create_group(org,gen_random_uuid(),(sat+time '09:00') at time zone 'Asia/Taipei',3,g)->>'group_id')::uuid;
  select exists(select 1 from jsonb_array_elements(public.list_public_groups()) x where (x->>'group_id')::uuid=gid) into listed;
  if listed then raise exception 'private group listed'; end if;
  begin
    perform public.join_group(u2,gid);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVITE_INVALID' then raise exception 'private join: %', msg; end if;
  end;

  -- 只有主揪能改公開；改了之後出現在缺人場次、任何人都能直接加入。
  begin
    perform public.set_group_visibility(u2,gid,'public');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_NOT_FOUND' then raise exception 'non-organizer changed visibility: %', msg; end if;
  end;
  r := public.set_group_visibility(org,gid,'public');
  if not (r->>'changed')::boolean then raise exception 'not changed'; end if;
  r := (select x from jsonb_array_elements(public.list_public_groups()) x where (x->>'group_id')::uuid=gid);
  if r is null or (r->>'filled')::int<>1 or r ? 'seats' or r->>'game_title'<>'QA 公開本' then raise exception 'public listing wrong: %', r; end if;
  perform public.join_group(u2,gid);

  -- 滿團後就不在缺人場次；改回私人也會消失。
  perform public.join_group(u3,gid);
  if exists(select 1 from jsonb_array_elements(public.list_public_groups()) x where (x->>'group_id')::uuid=gid)
    then raise exception 'full group still listed'; end if;
  full_gid := gid;
  gid := (public.create_group(org,gen_random_uuid(),(sat+time '14:00') at time zone 'Asia/Taipei',3,g,'{}','','public')->>'group_id')::uuid;
  if not exists(select 1 from jsonb_array_elements(public.list_public_groups()) x where (x->>'group_id')::uuid=gid)
    then raise exception 'public-at-creation not listed'; end if;
  perform public.set_group_visibility(org,gid,'private');
  if exists(select 1 from jsonb_array_elements(public.list_public_groups()) x where (x->>'group_id')::uuid=gid)
    then raise exception 'private again but still listed'; end if;

  -- 已成團或已解散的團不能再改。
  perform public.cancel_group(org,gid);
  begin
    perform public.set_group_visibility(org,gid,'public');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'GROUP_CLOSED' then raise exception 'changed a closed group: %', msg; end if;
  end;
  begin
    perform public.set_group_visibility(org,full_gid,'secret');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_VISIBILITY' then raise exception 'bad visibility: %', msg; end if;
  end;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.list_public_groups()','EXECUTE')
      or has_function_privilege(r,'public.set_group_visibility(uuid,uuid,text)','EXECUTE')
      then raise exception 'public group RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: private hidden, organizer-only toggle, public listed and joinable, full and private delisted, closed locked' as result;
rollback;
