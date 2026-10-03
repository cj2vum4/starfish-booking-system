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
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
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

for (const file of ['tests/database.sql', 'tests/booking_core.sql', 'tests/booking_rpc.sql', 'tests/sessions.sql', 'tests/slots.sql', 'tests/group_views.sql', 'tests/game_catalog.sql', 'tests/confirm.sql', 'tests/cancel_event.sql', 'tests/notifications.sql', 'tests/public_groups.sql', 'tests/history.sql', 'tests/report.sql', 'tests/friend_gate.sql']) {
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
