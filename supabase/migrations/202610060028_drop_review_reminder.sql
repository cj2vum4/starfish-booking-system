begin;

-- The store hands out a QR code for the 玩後問卷 at the table and the member Rich Menu links to
-- it, so recording attendance no longer queues a LINE reminder.
drop trigger review_reminder on public.player_game_history;
drop function public._sf_review_reminder();

commit;
