-- Run in Supabase SQL Editor after 202610050021_member_menu.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare adm uuid; a uuid; b uuid; g uuid; ev uuid; absent uuid; ids jsonb;
begin
  delete from public.calendar_busy;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d1ad','店長') returning id into adm;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d1a1','出席') returning id into a;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000d1a2','缺席') returning id into b;
  insert into public.admin_users(user_id) values (adm);
  insert into public.games(slug,title,min_players,max_players,duration_minutes) values ('qa-menu','QA 選單本',2,6,240) returning id into g;
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name)
    values (g,now()+interval '1 day',4,40000,'南港','海星') returning id into ev;
  perform public.join_event(a,ev,gen_random_uuid());
  perform public.join_event(b,ev,gen_random_uuid());
  ids := public.member_menu_line_ids();
  if ids ? 'U0000000000000000000000000000d1a1' then raise exception 'member before playing'; end if;
  update public.events set starts_at=now()-interval '1 day' where id=ev;
  select bp.id into absent from public.booking_participants bp join public.players p on p.id=bp.player_id where bp.event_id=ev and p.user_id=b;
  perform public.admin_complete_event(adm,ev,array[absent]);
  ids := public.member_menu_line_ids();
  if not ids ? 'U0000000000000000000000000000d1a1' then raise exception 'attended player missing: %', ids; end if;
  if ids ? 'U0000000000000000000000000000d1a2' then raise exception 'absent player listed'; end if;
  if exists(select 1 from jsonb_array_elements_text(ids) x where x like 'Ufeedfacefeedface%') then raise exception 'self-test listed'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.member_menu_line_ids()','EXECUTE') then raise exception 'exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: attended players get the member menu, absent and self-test do not, privileges' as result;
rollback;
