// The Supabase port against the real Apps Script (tests/fixtures/gas_parity.json, made by scripts/gas_parity_vectors.cjs
// from starfishlarp/GoogleAppsScript_玩本記錄.gs):
// Each case holds the spreadsheet as the Sheets API returns it; the api's own reader (playRecordsFromSheet) turns it
// into the import, so the whole path — sheet cells, import, scoring, summary — is compared with the Apps Script.
//   import — importing the spreadsheet the Apps Script left behind reproduces its 點數總覽 and public lists exactly;
//   replay — scoring each record once at submit time (in play order, referrers who already played) gives every
//            player the same points as the Apps Script's full recalculation, likes included.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
import { playRecordsFromSheet } from '../supabase/functions/api/index.ts';

const root = new URL('../', import.meta.url);
const read = (path) => readFileSync(new URL(path, root), 'utf8');
const { cases } = JSON.parse(read('tests/fixtures/gas_parity.json'));
const norm = (s) => String(s ?? '').replace(/\s+/g, '').toLowerCase();

let schema;
async function freshDb() {
  const db = new PGlite();
  await db.exec(`set timezone to 'UTC'; create role anon nologin; create role authenticated nologin;
    create role service_role nologin bypassrls; grant usage on schema public to anon, authenticated, service_role;`);
  schema ??= readdirSync(new URL('supabase/migrations/', root)).filter((f) => f.endsWith('.sql')).sort()
    .map((f) => read(`supabase/migrations/${f}`));
  for (const sql of schema) await db.exec(sql);
  const adm = (await db.query(`insert into public.users(line_user_id,display_name) values ('U00000000000000000000000000007c01','店長') returning id`)).rows[0].id;
  await db.query('insert into public.admin_users(user_id) values ($1)', [adm]);
  return { db, adm };
}
const json = async (db, sql, params) => (await db.query(sql, params)).rows[0]?.v;

cases.forEach((c, i) => test(`${c.kind} case ${i + 1}: ${c.sheet['表單回應 1'].length - 1} rows, double day "${c.doubleDay}"`, async () => {
  const { db, adm } = await freshDb();
  const sheet = await playRecordsFromSheet(c.sheet, '表單回應 1', 'Asia/Taipei');
  if (c.kind === 'import') {
    const result = await json(db, 'select public.admin_import_play_records($1,$2) v', [adm, sheet]);
    assert.ok(result.records > 0);
    const payload = await json(db, 'select public._sf_records_payload() v');
    const mine = new Map(payload.summary.map((s) => [s.name, s]));
    assert.deepEqual([...mine.keys()].sort(), c.expected.summary.map((s) => s.name).sort(), 'same players');
    for (const want of c.expected.summary) {
      const got = mine.get(want.name);
      for (const f of ['earned', 'redeemed', 'balance', 'plays', 'last', 'agent', 'gilded', 'title', 'legend']) {
        assert.equal(got[f], want[f], `${want.name} ${f}`);
      }
    }
    const key = (x) => JSON.stringify([x.script, x.date, x.author, x.likes, x.featured]);
    assert.deepEqual(payload.interactions.map(key).sort(), c.expected.interactions.map(key).sort(), 'interactions');
    assert.deepEqual(payload.mystery, c.expected.mystery, 'mystery history');
    assert.deepEqual(payload.quests, c.expected.quests, 'quests');
    assert.deepEqual(payload.rewards.map((r) => [r.track, r.name, r.cost, r.note]), c.expected.rewards.map((r) => [r.track, r.name, r.cost, r.note]));
    assert.deepEqual(payload.rules.map((r) => JSON.stringify(r, Object.keys(r).sort())).sort(),
      c.expected.rules.map((r) => JSON.stringify(r, Object.keys(r).sort())).sort(), 'rules');
    assert.equal(payload.doubleDayNote, c.expected.doubleDayNote);
    // The switch only opens once the copy matches the Apps Script's last summary.
    await db.query(`insert into public.play_record_snapshot(id,payload) values (1,$1)`, [{ ok: true, summary: c.expected.summary }]);
    assert.equal((await json(db, 'select public.admin_records_reconcile($1) v', [adm])).matched, true);
  } else {
    await json(db, 'select public.admin_import_play_records($1,$2) v',
      [adm, { ...sheet, players: [], responses: [], ledger: [], interactions: [] }]);
    await db.exec(`update public.record_state set source='supabase'`);
    for (const r of sheet.responses) {
      await db.query('select public._sf_add_play_record($1, $2, $3)', [r, 'sheet', r.stamp]);
    }
    let liker = 0;
    for (const x of sheet.interactions) {
      for (let k = 0; k < x.likes; k++) {
        const id = `00000000-0000-4000-8000-${String(++liker).padStart(12, '0')}`;
        await db.query('select public.submit_review_like($1,$2,$3,$4)', [x.script, x.date, x.author, id]);
      }
    }
    const summary = await json(db, 'select public._sf_records_summary() v');
    const mine = new Map(summary.map((s) => [norm(s.name), s]));
    assert.equal(mine.size, c.expected.summary.length, 'same number of players');
    for (const want of c.expected.summary) {
      const got = mine.get(norm(want.name));
      assert.ok(got, `player ${want.name}`);
      for (const f of ['earned', 'balance', 'plays', 'last']) assert.equal(got[f], want[f], `${want.name} ${f}`);
    }
  }
  await db.close();
}));
