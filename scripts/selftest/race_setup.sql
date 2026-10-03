-- P6 live race self-test, step 1 (commit): synthetic script, 1-seat-left event, 20 players.
-- Everything uses the self-test markers (slug qa-stress-*, LINE IDs Ufeedfacefeedface…)
-- and is removed again by race_cleanup.sql.
begin;
do $$
declare g uuid; ev uuid; u uuid; i integer; first uuid; sat date;
begin
  if exists(select 1 from public.games where slug='qa-stress-race') then raise exception 'previous self-test not cleaned up'; end if;
  insert into public.games(slug,title,min_players,max_players,duration_minutes,active)
    values ('qa-stress-race','壓力測試（自動清除）',2,6,240,false) returning id into g;
  for i in 0..20 loop
    insert into public.users(line_user_id,display_name)
      values ('Ufeedfacefeedface'||lpad(to_hex(i),16,'0'),'壓測玩家'||i) returning id into u;
    if i=0 then first:=u; end if;
  end loop;
  -- A Wednesday (closed day) far ahead: the store's real calendar is never touched.
  sat := (now() at time zone 'Asia/Taipei')::date+200; sat := sat+((3-extract(dow from sat)::int+7)%7);
  insert into public.events(game_id,starts_at,capacity,price_cents,venue,dm_name,visibility)
    values (g,(sat+time '10:00') at time zone 'Asia/Taipei',2,0,'壓力測試','壓力測試','public') returning id into ev;
  perform public.join_event(first,ev,gen_random_uuid());   -- 1 of 2 seats taken: one seat left
end $$;
commit;
select g.id as game_id, e.id as event_id,
  (select json_agg(id order by line_user_id) from public.users where line_user_id like 'Ufeedfacefeedface%' and display_name<>'壓測玩家0') as racers,
  (select count(*) from public.booking_participants bp where bp.event_id=e.id and bp.status<>'cancelled') as seats_taken
from public.games g join public.events e on e.game_id=g.id where g.slug='qa-stress-race';
