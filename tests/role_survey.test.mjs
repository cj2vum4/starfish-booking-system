import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { handleApi, sheetSerialToIso, surveyRowsFromSheet, sha256Hex } from '../supabase/functions/api/index.ts';

const SITE = 'https://cj2vum4.github.io';
const session = 'S'.repeat(43);
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const google = { clientEmail: 'sa@test.iam.gserviceaccount.com', calendarId: 'owner@example.com',
  privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) };

// Fake PostgREST + Google. `rpcs` records every call; `answer(name, args)` may override a result.
function backend({ isAdmin = true, answer = () => undefined, sheets = {} } = {}) {
  const rpcs = [], google = [];
  const fetcher = async (url, opts = {}) => {
    if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'g', expires_in: 3600 });
    if (url.startsWith('https://sheets.googleapis.com/')) {
      google.push(decodeURIComponent(url));
      if (sheets.status) return Response.json({ error: sheets.error ?? {} }, { status: sheets.status });
      if (url.includes('?fields=')) return Response.json(sheets.meta);
      return Response.json(url.includes('UNFORMATTED_VALUE') ? sheets.serials : sheets.shown);
    }
    const name = url.split('/rpc/')[1], args = opts.body ? JSON.parse(opts.body) : {};
    rpcs.push([name, args]);
    const custom = answer(name, args);
    if (custom) return custom;
    if (name === 'resolve_session') return Response.json(args.p_session_hash === await sha256Hex(session)
      ? { user_id: 'owner', display_name: '店長', is_admin: isAdmin, expires_at: 'x' } : null);
    if (name === 'submit_role_survey') return Response.json({ id: 'r1' });
    if (name === 'admin_import_role_surveys') return Response.json({ imported: args.p_rows.length, skipped: 0 });
    return Response.json([]);
  };
  return { rpcs, google, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k',
    allowedOrigins: [SITE], lineAccessToken: 'line', google: { ...google }, fetcher } };
}
const call = (settings, path, { method = 'GET', body, origin, auth = true, type } = {}) => handleApi(new Request(`https://x/functions/v1/api${path}`,
  { method, body, headers: { ...(auth ? { Authorization: `Bearer ${session}` } : {}), ...(origin ? { Origin: origin } : {}),
    ...(type ? { 'Content-Type': type } : {}) } }), settings);

test('the website posts answers as text/plain JSON and gets CORS headers for the site only', async () => {
  const b = backend();
  const fields = [{ label: 'Line名稱', value: '阿明' }, { label: '喜歡', value: ['推理', '情感'] }];
  const res = await call(b.settings, '/public/role-survey', { method: 'POST', auth: false, origin: SITE,
    type: 'text/plain;charset=UTF-8', body: JSON.stringify({ script: '王座', fields, website: '' }) });
  assert.deepEqual([res.status, await res.json()], [201, { ok: true }]);
  assert.equal(res.headers.get('access-control-allow-origin'), SITE);
  assert.deepEqual(b.rpcs.find(r => r[0] === 'submit_role_survey')[1], { p_script: '王座', p_fields: fields });
  assert.ok(!b.rpcs.some(r => r[0] === 'claim_notifications'), 'no notification run after a public post');

  const other = await call(b.settings, '/public/role-survey', { method: 'POST', auth: false, origin: 'https://evil.example',
    body: JSON.stringify({ script: '王座', fields }) });
  assert.equal(other.headers.get('access-control-allow-origin'), null, 'other sites cannot read the answer');
});

test('bots filling the honeypot are told ok and nothing is saved; bad posts get a code', async () => {
  const b = backend();
  const res = await call(b.settings, '/public/role-survey', { method: 'POST', auth: false,
    body: JSON.stringify({ script: '王座', fields: [{ label: 'a', value: 'b' }], website: 'http://spam' }) });
  assert.deepEqual([res.status, await res.json()], [200, { ok: true }]);
  assert.ok(!b.rpcs.some(r => r[0] === 'submit_role_survey'));
  assert.equal((await call(b.settings, '/public/role-survey', { method: 'POST', auth: false, body: 'not json' })).status, 400);

  for (const [code, status] of [['INVALID_SURVEY', 400], ['TOO_MANY_REQUESTS', 429]]) {
    const failing = backend({ answer: name => name === 'submit_role_survey' ? Response.json({ code: 'P0001', message: code }, { status: 400 }) : undefined });
    const r = await call(failing.settings, '/public/role-survey', { method: 'POST', auth: false,
      body: JSON.stringify({ script: '王座', fields: [] }) });
    assert.deepEqual([r.status, (await r.json()).error], [status, code]);
  }
});

test('store pages need a session; answers, edits and deletes go through the store-only RPCs', async () => {
  const b = backend();
  assert.equal((await call(b.settings, '/admin/role-surveys', { auth: false })).status, 401);
  await call(b.settings, '/admin/role-surveys/responses?script=%E7%8E%8B%E5%BA%A7&before=2026-10-01T00:00:00Z');
  assert.deepEqual(b.rpcs.at(-1), ['admin_role_survey_responses', { p_actor: 'owner', p_script: '王座', p_limit: 30, p_before: '2026-10-01T00:00:00Z' }]);
  assert.equal((await call(b.settings, '/admin/role-surveys/responses?script=x&before=nope')).status, 400);
  const id = '11111111-1111-4111-8111-111111111111';
  await call(b.settings, `/admin/role-surveys/responses/${id}`, { method: 'POST', body: JSON.stringify({ assignedRole: '雷神', storeNote: '備選洛基' }) });
  const last = name => b.rpcs.filter(r => r[0] === name).at(-1);
  assert.deepEqual(last('admin_update_role_survey'), ['admin_update_role_survey', { p_actor: 'owner', p_id: id, p_assigned_role: '雷神', p_store_note: '備選洛基' }]);
  await call(b.settings, `/admin/role-surveys/responses/${id}/delete`, { method: 'POST' });
  assert.deepEqual(last('admin_delete_role_survey'), ['admin_delete_role_survey', { p_actor: 'owner', p_id: id }]);

  const player = backend({ isAdmin: false, answer: name => name.startsWith('admin_') ? Response.json({ code: 'P0001', message: 'NOT_ADMIN' }, { status: 400 }) : undefined });
  assert.equal((await call(player.settings, '/admin/role-surveys')).status, 403);
  assert.equal((await call(player.settings, '/admin/role-surveys/import', { method: 'POST' })).status, 403);
  assert.equal(player.google.length, 0, 'a player never makes the system read Google');
});

test('Sheets serial times are read in the spreadsheet time zone', () => {
  assert.equal(sheetSerialToIso(46306.5), '2026-10-11T04:00:00.000Z');  // 2026/10/11 12:00 in Taipei
  assert.equal(sheetSerialToIso(46306.5, 'UTC'), '2026-10-11T12:00:00.000Z');
  assert.equal(sheetSerialToIso(46306.5, 'America/New_York'), '2026-10-11T16:00:00.000Z');  // EDT
});

test('a sheet tab becomes answers with exact times and stable import keys', async () => {
  const shown = [['時間戳記', 'Line名稱', '喜歡', '分配角色'], ['2026/10/7 下午 3:04:05', '阿明', '推理, 情感', ''], [], ['2026/10/8', '', '', ''],
    ['亂打的時間', '小華', '', '']];
  const serials = [['時間戳記'], [46302.6278], [], [46303], ['亂打的時間']];
  const first = await surveyRowsFromSheet('王座', shown, serials, 'Asia/Taipei');
  assert.equal(first.rows.length, 1);
  assert.equal(first.skipped, 1, 'a row without a readable time is skipped, not guessed');
  assert.deepEqual(first.rows[0].fields, [{ label: 'Line名稱', value: '阿明' }, { label: '喜歡', value: '推理, 情感' }]);
  assert.equal(first.rows[0].submitted_at, sheetSerialToIso(46302.6278));
  const again = await surveyRowsFromSheet('王座', shown, serials, 'Asia/Taipei');
  assert.equal(again.rows[0].import_key, first.rows[0].import_key);
  assert.match(first.rows[0].import_key, /^[0-9a-f]{64}$/);
});

test('import reads every tab read-only and tells the store when the sheet is not shared', async () => {
  const b = backend({ sheets: { meta: { properties: { timeZone: 'Asia/Taipei' }, sheets: [{ properties: { title: '王座' } }, { properties: { title: "O'Neil" } }] },
    shown: { valueRanges: [{ values: [['時間戳記', 'Line名稱'], ['x', '阿明']] }, { values: [['時間戳記']] }] },
    serials: { valueRanges: [{ values: [['時間戳記'], [46302.5]] }, { values: [['時間戳記']] }] } } });
  b.settings.google = google;
  const res = await call(b.settings, '/admin/role-surveys/import', { method: 'POST' });
  assert.deepEqual(await res.json(), { tabs: [{ script: '王座', rows: 1 }], imported: 1, skipped: 0 });
  assert.ok(b.google.every(u => !/:batchUpdate|:append|values\/.*:clear/.test(u)), 'nothing is written to Google');
  assert.ok(b.google.some(u => u.includes("ranges='O''Neil'!A1:CZ")), 'tab names are quoted for the range');
  const rows = b.rpcs.find(r => r[0] === 'admin_import_role_surveys')[1].p_rows;
  assert.deepEqual(rows.map(r => [r.script, r.submitted_at]), [['王座', '2026-10-07T04:00:00.000Z']]);

  for (const [status, error, code] of [[403, {}, 'SHEET_NOT_SHARED'], [404, {}, 'SHEET_NOT_FOUND'],
    [403, { message: 'Google Sheets API has not been used in project 1' }, 'SHEETS_API_DISABLED']]) {
    const denied = backend({ sheets: { status, error } });
    denied.settings.google = google;
    const r = await call(denied.settings, '/admin/role-surveys/import', { method: 'POST' });
    assert.deepEqual([r.status, (await r.json()).error], [503, code]);
  }
});
