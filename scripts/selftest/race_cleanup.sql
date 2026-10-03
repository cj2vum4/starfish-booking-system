-- P6 live race self-test, final step (commit): report, then remove every self-test row.
begin;
create temp table st_users on commit drop as select id from public.users where line_user_id like 'Ufeedfacefeedface%';
create temp table st_games on commit drop as select id from public.games where slug like 'qa-stress-%';
create temp table st_events on commit drop as select id from public.events where game_id in (select id from st_games);
create temp table st_groups on commit drop as select id from public.groups
  where organizer_user_id in (select id from st_users) or game_id in (select id from st_games);
delete from public.notification_logs where user_id in (select id from st_users) or group_id in (select id from st_groups);
delete from public.invite_tokens where group_id in (select id from st_groups) or created_by_user_id in (select id from st_users);
delete from public.booking_participants where event_id in (select id from st_events);
delete from public.bookings where event_id in (select id from st_events) or booker_user_id in (select id from st_users);
update public.groups set slot_id=null where id in (select id from st_groups);
update public.events set slot_id=null where id in (select id from st_events);
delete from public.time_slots where group_id in (select id from st_groups) or event_id in (select id from st_events);
delete from public.group_members where group_id in (select id from st_groups);
delete from public.events where id in (select id from st_events);
delete from public.groups where id in (select id from st_groups);
delete from public.players where user_id in (select id from st_users) or created_by_user_id in (select id from st_users);
delete from public.app_sessions where user_id in (select id from st_users);
delete from public.audit_logs where actor_user_id in (select id from st_users);
delete from public.users where id in (select id from st_users);
delete from public.games where id in (select id from st_games);
commit;
select (select count(*) from public.users where line_user_id like 'Ufeedfacefeedface%') as left_users,
  (select count(*) from public.games where slug like 'qa-stress-%') as left_games;
