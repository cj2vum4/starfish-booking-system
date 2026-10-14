import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');

// Mirrors Supabase defaults: new objects in public are granted to the API roles,
// so migrations must revoke access explicitly.
const supabaseRoles = `
  set timezone to 'UTC';  -- Supabase sessions run in UTC; Taipei handling must be explicit.
  create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
  grant usage on schema public to anon, authenticated, service_role;
  alter default privileges in schema public grant all on tables to anon, authenticated;
  alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
`;

async function migratedDb() {
  const db = new PGlite();
  await db.exec(supabaseRoles);
  const dir = new URL('supabase/migrations/', root);
  for (const file of readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) {
    await db.exec(read(`supabase/migrations/${file}`));
  }
  return db;
}

// Supabase loads safeupdate for API calls: a DELETE or UPDATE without WHERE fails there (21000) but not here,
// which is how 0036's import broke in production. Check every function body as the migrations leave it.
test('no function deletes or updates a whole table without WHERE (Supabase safeupdate)', async () => {
  const db = await migratedDb();
  const { rows } = await db.query(`select p.proname, p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'`);
  const bad = [];
  for (const { proname, prosrc } of rows) {
    const code = prosrc.replace(/--[^\n]*/g, '');
    for (const statement of code.split(';')) {
      const at = statement.search(/\b(delete\s+from|update\s+(public\.)?\w+\s+(\w+\s+)?set)\b/i);
      if (at >= 0 && !/\bwhere\b/i.test(statement.slice(at))) bad.push(`${proname}: ${statement.slice(at).trim().slice(0, 80)}`);
    }
  }
  assert.deepEqual(bad, []);
  await db.close();
});

for (const file of ['tests/database.sql', 'tests/booking_core.sql', 'tests/booking_rpc.sql', 'tests/sessions.sql', 'tests/slots.sql', 'tests/group_views.sql', 'tests/game_catalog.sql', 'tests/confirm.sql', 'tests/cancel_event.sql', 'tests/notifications.sql', 'tests/public_groups.sql', 'tests/history.sql', 'tests/report.sql', 'tests/friend_gate.sql', 'tests/member_menu.sql', 'tests/player_binding.sql', 'tests/record_snapshot.sql', 'tests/review_context.sql', 'tests/expire_groups.sql', 'tests/claim_record_name.sql', 'tests/group_venue.sql', 'tests/confirm_calendar_recheck.sql', 'tests/oa_message_alerts.sql', 'tests/tick_schedule.sql', 'tests/role_survey.sql', 'tests/play_records.sql', 'tests/store_points.sql', 'tests/history_records.sql']) {
  test(`${file} passes on a fresh Postgres`, async () => {
    const db = await migratedDb();
    const results = await db.exec(read(file));
    const pass = results.flatMap((r) => r.rows).find((row) => String(row.result ?? '').startsWith('PASS'));
    assert.ok(pass, 'PASS row missing');
    const leftovers = await db.query('select count(*)::int as n from public.users');
    assert.equal(leftovers.rows[0].n, 0, 'synthetic records were not rolled back');
    await db.close();
  });
}
