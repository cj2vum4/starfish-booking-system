-- Run in Supabase SQL Editor after 202610020005_time_slots.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  adm uuid; org uuid; u2 uuid; g uuid; r jsonb; msg text; n integer;
  d0 date := (now() at time zone 'Asia/Taipei')::date + 1;
  sun date; s_sun14 uuid; s_sun18 uuid; s_busy uuid; s_next uuid; ev uuid;
begin
  insert into public.users(line_user_id) values ('U0000000000000000000000000000e0ad') returning id into adm;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000e001') returning id into org;
  insert into public.users(line_user_id) values ('U0000000000000000000000000000e002') returning id into u2;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,price_cents)
    values ('qa-slot-game','QA 劇本',2,6,60000) returning id into g;

  -- 每週規則：週日 14:00、18:00；週一、四、五 19:00；每場 240 分鐘。
  insert into public.slot_rules(weekday,start_time) values (0,'14:00'),(0,'18:00'),(1,'19:00'),(4,'19:00'),(5,'19:00');
  begin
    perform public.admin_generate_slots(org,d0,d0+13);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'NOT_ADMIN' then raise exception 'non-admin generate: %', msg; end if;
  end;
  r := public.admin_generate_slots(adm,d0,d0+13);
  -- Two full weeks: 2 Sundays x 2 + 2 x (Mon, Thu, Fri) = 10 slots.
  if (r->>'created')::int<>10 then raise exception 'expected 10 slots, got %', r->>'created'; end if;
  r := public.admin_generate_slots(adm,d0,d0+13);
  if (r->>'created')::int<>0 then raise exception 'regenerate created duplicates'; end if;

  -- Times are Asia/Taipei wall-clock and last 4 hours.
  sun := d0 + ((7-extract(dow from d0)::int)%7);
  select id into s_sun14 from public.time_slots where starts_at=(sun+time '14:00') at time zone 'Asia/Taipei';
  select id into s_sun18 from public.time_slots where starts_at=(sun+time '18:00') at time zone 'Asia/Taipei';
  if s_sun14 is null or s_sun18 is null then raise exception 'Sunday slots missing or wrong timezone'; end if;
  if (select ends_at-starts_at from public.time_slots where id=s_sun14)<>interval '240 minutes'
    then raise exception 'wrong slot length'; end if;
  if exists(select 1 from public.time_slots where extract(dow from starts_at at time zone 'Asia/Taipei') in (2,3,6))
    then raise exception 'slot created on a closed weekday'; end if;

  -- 同一時段只能一場：重疊的時段無法建立。
  begin
    insert into public.time_slots(starts_at,ends_at)
      values ((sun+time '16:00') at time zone 'Asia/Taipei',(sun+time '20:00') at time zone 'Asia/Taipei');
    raise exception 'MISSING';
  exception when exclusion_violation then null;
  end;

  -- Google 日曆的私人行程（例如家庭聚餐）讓重疊時段自動不開放。
  select id into s_busy from public.time_slots where id<>s_sun14 and id<>s_sun18 order by starts_at limit 1;
  perform public.sync_calendar_busy(now(),now()+interval '30 days',jsonb_build_array(jsonb_build_object(
    'start',(select starts_at+interval '1 hour' from public.time_slots where id=s_busy),
    'end',(select starts_at+interval '3 hours' from public.time_slots where id=s_busy))));
  r := public.list_available_slots(now(),now()+interval '30 days');
  if jsonb_array_length(r)<>9 or r::text like '%'||s_busy||'%' then raise exception 'busy slot still listed'; end if;
  begin
    perform public.create_group(org,gen_random_uuid(),s_busy,4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'busy slot bookable: %', msg; end if;
  end;
  -- Re-syncing the window replaces old busy periods: the dinner was cancelled.
  perform public.sync_calendar_busy(now(),now()+interval '30 days','[]');
  if jsonb_array_length(public.list_available_slots(now(),now()+interval '30 days'))<>10
    then raise exception 'busy sync did not replace window'; end if;

  -- 開團佔住時段，第二團不能選同一時段；解散後時段釋出。
  r := public.create_group(org,gen_random_uuid(),s_sun14,4,g);
  if (select status from public.time_slots where id=s_sun14)<>'held'
    or (select desired_start_at from public.groups where id=(r->>'group_id')::uuid)
       <>(select starts_at from public.time_slots where id=s_sun14)
    then raise exception 'slot not held by group'; end if;
  begin
    perform public.create_group(u2,gen_random_uuid(),s_sun14,4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'double hold: %', msg; end if;
  end;
  perform public.cancel_group(org,(r->>'group_id')::uuid);
  if (select status from public.time_slots where id=s_sun14)<>'open' then raise exception 'slot not released'; end if;
  r := public.create_group(u2,gen_random_uuid(),s_sun14,4,g);
  r := public.admin_confirm_group_event(adm,(r->>'group_id')::uuid,'QA 場館','QA DM');
  if (select status from public.time_slots where id=s_sun14)<>'booked' then raise exception 'slot not booked'; end if;

  -- 店家直接開缺人場次也佔用時段；已關閉或已使用的時段不可再用。
  r := public.admin_create_event(adm,s_sun18,g,6,'QA 場館','QA DM');
  ev := (r->>'event_id')::uuid;
  if (select slot_id from public.events where id=ev)<>s_sun18 then raise exception 'event not linked to slot'; end if;
  begin
    perform public.admin_create_event(adm,s_sun18,g,6,'QA 場館','QA DM');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'slot reused: %', msg; end if;
  end;
  begin
    perform public.admin_close_slot(adm,s_sun18);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_IN_USE' then raise exception 'closed a booked slot: %', msg; end if;
  end;
  select id into s_next from public.time_slots where status='open' order by starts_at limit 1;
  perform public.admin_close_slot(adm,s_next);
  if exists(select 1 from jsonb_array_elements(public.list_available_slots(now(),now()+interval '30 days')) e
      where (e->>'slot_id')::uuid=s_next) then raise exception 'closed slot still listed'; end if;

  -- Past slots cannot be generated or used.
  insert into public.time_slots(starts_at,ends_at,status)
    values (now()-interval '3 days',now()-interval '3 days'+interval '4 hours','open') returning id into s_next;
  begin
    perform public.create_group(org,gen_random_uuid(),s_next,4);
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'SLOT_UNAVAILABLE' then raise exception 'past slot bookable: %', msg; end if;
  end;
end $$;
reset role;
do $$
declare t text; r text;
begin
  foreach t in array array['slot_rules','time_slots','calendar_busy'] loop
    if not (select relrowsecurity from pg_class where oid=('public.'||t)::regclass)
      then raise exception 'RLS missing on %', t; end if;
    foreach r in array array['anon','authenticated'] loop
      if has_table_privilege(r,'public.'||t,'SELECT,INSERT,UPDATE,DELETE') then raise exception '% exposed to %', t, r; end if;
      if has_function_privilege(r,'public.list_available_slots(timestamptz,timestamptz)','EXECUTE')
        or has_function_privilege(r,'public.sync_calendar_busy(timestamptz,timestamptz,jsonb)','EXECUTE')
        then raise exception 'slot RPC exposed to %', r; end if;
    end loop;
  end loop;
end $$;
select 'PASS: weekly rules, Taipei time, no overlap, calendar busy, hold, release, confirm, admin event, close, past' as result;
rollback;
