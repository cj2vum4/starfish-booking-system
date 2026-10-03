import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, root), 'utf8');
const roles = read('tests/database.test.mjs').match(/const supabaseRoles = `([\s\S]*?)`;/)[1];

test('live race self-test scripts: setup leaves one seat, guard accepts only synthetic data, cleanup removes everything', async () => {
  const db = new PGlite();
  await db.exec(roles);
  for (const f of readdirSync(new URL('supabase/migrations/', root)).sort()) await db.exec(read(`supabase/migrations/${f}`));
  // Real-looking data that must survive the cleanup untouched.
  await db.exec(`insert into public.users(line_user_id) values ('U${'a'.repeat(32)}');
    insert into public.games(slug,title,min_players,max_players) values ('real-game','真劇本',2,6);`);
  const setup = await db.exec(read('scripts/selftest/race_setup.sql'));
  const row = setup.at(-1).rows[0];
  assert.equal(row.seats_taken, 1);
  assert.equal(row.racers.length, 20);
  const ok = await db.query('select public.selftest_targets_ok($1::uuid[],$2,$3) as ok', [row.racers, row.game_id, row.event_id]);
  assert.equal(ok.rows[0].ok, true);
  const real = await db.query(`select (select id from public.users where line_user_id=$1) as u, (select id from public.games where slug='real-game') as g`, ['U' + 'a'.repeat(32)]);
  const mixed = await db.query('select public.selftest_targets_ok($1::uuid[],$2,$3) as ok', [[...row.racers, real.rows[0].u], row.game_id, row.event_id]);
  assert.equal(mixed.rows[0].ok, false, 'a real player in the list is refused');
  const realGame = await db.query('select public.selftest_targets_ok($1::uuid[],$2,null) as ok', [row.racers, real.rows[0].g]);
  assert.equal(realGame.rows[0].ok, false, 'a real script is refused');
  // Racers book (sequentially here; the live run is concurrent), plus a self-test group.
  for (const u of row.racers.slice(0, 3)) {
    await db.query('select public.join_event($1,$2,gen_random_uuid())', [u, row.event_id]).catch(() => {});
  }
  await db.exec(`do $$ declare sat date := (now() at time zone 'Asia/Taipei')::date+60; begin
    sat := sat+((6-extract(dow from sat)::int+7)%7);
    perform public.create_group((select id from public.users where line_user_id like 'Ufeedfacefeedface%' limit 1),
      gen_random_uuid(),(sat+time '10:00') at time zone 'Asia/Taipei',2,null);
  end $$;`);
  const taken = await db.query(`select count(*)::int as n from public.booking_participants where event_id=$1 and status<>'cancelled'`, [row.event_id]);
  assert.equal(taken.rows[0].n, 2, 'never more than capacity');
  const clean = await db.exec(read('scripts/selftest/race_cleanup.sql'));
  assert.deepEqual(clean.at(-1).rows[0], { left_users: 0, left_games: 0 });
  const survivors = await db.query(`select (select count(*)::int from public.users) as users, (select count(*)::int from public.games) as games,
    (select count(*)::int from public.time_slots) as slots, (select count(*)::int from public.notification_logs) as notices`);
  assert.deepEqual(survivors.rows[0], { users: 1, games: 1, slots: 0, notices: 0 });
  await db.close();
});
