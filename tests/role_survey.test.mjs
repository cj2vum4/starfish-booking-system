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
  const rpcs = [], googleCalls = [];
  const fetcher = async (url, opts = {}) => {
    if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'g', expires_in: 3600 });
    if (url.startsWith('https://sheets.googleapis.com/')) {
      googleCalls.push(decodeURIComponent(url));
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
  return { rpcs, google: googleCalls, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k',
    allowedOrigins: [SITE], lineAccessToken: 'line', fetcher } };
}
const call = (settings, path, { method = 'GET', body, origin, auth = true, type } = {}) => handleApi(new Request(`https://x/functions/v1/api${path}`,
  { method, body, headers: { ...(auth ? { Authorization: `Bearer ${session}` } : {}), ...(origin ? { Origin: origin } : {}),
    ...(type ? { 'Content-Type': type } : {}) } }), settings);

test('the website posts answers as text/plain JSON with its 送出編號; any page can read the reply', async () => {
  const b = backend();
  const fields = [{ label: 'Line名稱', value: '阿明' }, { label: '喜歡', value: ['推理', '情感'] }];
  const id = 'A1B2C3D4-0000-4000-8000-000000000001';
  const res = await call(b.settings, '/public/role-survey', { method: 'POST', auth: false, origin: SITE,
    type: 'text/plain;charset=UTF-8', body: JSON.stringify({ script: '王座', fields, website: '', id }) });
  assert.deepEqual([res.status, await res.json()], [201, { ok: true }]);
  assert.equal(res.headers.get('access-control-allow-origin'), '*',
    'a page that cannot read a saved answer would resend it to the old Apps Script');
  assert.deepEqual(b.rpcs.find(r => r[0] === 'submit_role_survey')[1], { p_script: '王座', p_fields: fields, p_client_id: id.toLowerCase() });
  assert.ok(!b.rpcs.some(r => r[0] === 'claim_notifications'), 'no notification run after a public post');

  await call(b.settings, '/public/role-survey', { method: 'POST', auth: false, body: JSON.stringify({ script: '王座', fields, id: 'nope' }) });
  assert.equal(b.rpcs.filter(r => r[0] === 'submit_role_survey').at(-1)[1].p_client_id, null);
  const big = await call(b.settings, '/public/role-survey', { method: 'POST', auth: false,
    body: JSON.stringify({ script: '王座', fields: [{ label: 'a', value: '字'.repeat(17000) }] }) });
  assert.equal(big.status, 413, 'answers are capped at 16 KB per post');
  const pre = await call(b.settings, '/public/role-survey', { method: 'OPTIONS', auth: false, origin: 'https://other.example' });
  assert.deepEqual([pre.status, pre.headers.get('access-control-allow-origin')], [204, '*']);
  // Store pages keep the strict origin list.
  const admin = await call(b.settings, '/admin/role-surveys', { origin: 'https://evil.example' });
  assert.equal(admin.headers.get('access-control-allow-origin'), null);
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
  const lastId = '22222222-2222-4222-8222-222222222222';
  await call(b.settings, `/admin/role-surveys/responses?script=%E7%8E%8B%E5%BA%A7&before=2026-10-01T00:00:00Z&beforeId=${lastId}`);
  assert.deepEqual(b.rpcs.at(-1), ['admin_role_survey_responses', { p_actor: 'owner', p_script: '王座', p_limit: 30,
    p_before: '2026-10-01T00:00:00Z', p_before_id: lastId }]);
  assert.equal((await call(b.settings, '/admin/role-surveys/responses?script=x&before=nope')).status, 400);
  assert.equal((await call(b.settings, '/admin/role-surveys/responses?script=x&before=2026-10-01T00:00:00Z&beforeId=x')).status, 400);
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

test('a sheet tab becomes answers: exact times, store columns, 送出編號, keys that survive edits', async () => {
  const id = 'a1b2c3d4-0000-4000-8000-000000000001';
  const shown = [['時間戳記', 'Line名稱', '喜歡', '送出編號', '分配角色', '備註'],
    ['2026/10/7 下午 3:04:05', '阿明', '推理, 情感', id, '', ''], [], ['2026/10/8', '', '', '', '', ''],
    ['亂打的時間', '小華', '', '', '', ''], ['2026/10/7 下午 3:04:05', '小華', '', '', '雷神', '同秒貼上的表單列']];
  const serials = [['時間戳記'], [46302.6278], [], [46303], ['亂打的時間'], [46302.6278]];
  const first = await surveyRowsFromSheet('王座', shown, serials, 'Asia/Taipei');
  assert.equal(first.rows.length, 2);
  assert.equal(first.skipped, 1, 'a row without a readable time is skipped, not guessed');
  assert.deepEqual(first.rows[0].fields, [{ label: 'Line名稱', value: '阿明' }, { label: '喜歡', value: '推理, 情感' }]);
  assert.equal(first.rows[0].client_id, id, 'the website fallback row is tied to its 送出編號');
  assert.equal(first.rows[0].submitted_at, sheetSerialToIso(46302.6278));
  assert.deepEqual([first.rows[1].assigned_role, first.rows[1].store_note, first.rows[1].client_id], ['雷神', '同秒貼上的表單列', undefined],
    'columns the store added become the assigned role and note, not player answers');
  assert.deepEqual(first.rows[1].fields, [{ label: 'Line名稱', value: '小華' }]);
  assert.notEqual(first.rows[0].import_key, first.rows[1].import_key, 'two rows from the same second stay apart');
  // Fixing a typo or assigning a role in the sheet afterwards keeps the same key: no second copy on re-import.
  const edited = shown.map(r => [...r]); edited[1][1] = '阿銘'; edited[1][4] = '洛基';
  const again = await surveyRowsFromSheet('王座', edited, serials, 'Asia/Taipei');
  assert.deepEqual(again.rows.map(r => r.import_key), first.rows.map(r => r.import_key));
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

test('the 5-minute tick imports answers the website left in the old sheet, at most every 6 hours', async () => {
  const claims = [];
  const b = backend({ answer: (name, args) => name === 'claim_scheduled_job' ? (claims.push(args), Response.json(claims.length === 1)) : undefined,
    sheets: { meta: { properties: { timeZone: 'Asia/Taipei' }, sheets: [{ properties: { title: '王座' } }] },
      shown: { valueRanges: [{ values: [['時間戳記', 'Line名稱'], ['x', '阿明']] }] },
      serials: { valueRanges: [{ values: [['時間戳記'], [46302.5]] }] } } });
  b.settings.google = google;
  const { runScheduledWork } = await import('../supabase/functions/api/index.ts');
  await runScheduledWork(b.settings);
  await runScheduledWork(b.settings);
  assert.deepEqual(claims[0], { p_name: 'role-survey-import', p_every: '6 hours' });
  assert.equal(b.rpcs.filter(r => r[0] === 'system_import_role_surveys').length, 1, 'only the claimed run imports');
  assert.equal(b.rpcs.filter(r => r[0] === 'admin_import_role_surveys').length, 0);
  // Without Google configured nothing is attempted.
  const none = backend();
  await runScheduledWork(none.settings);
  assert.ok(!none.rpcs.some(r => r[0] === 'claim_scheduled_job'));
});

// ---- 配對：群星的角色分配表 ----
const Q = { name: '您在社群裡的名字是？', gender: '您的性別是？', dream: '你希望夢境內容是關於家鄉還是遠方',
  sky: '當你抬頭看向天空時，你希望看到的是太陽還是星空呢', letter: '當你拿著這封信時，你希望這是家人寄來的還是戀人寄來的呢?',
  partner: '群星計劃中有您的另一半嗎？如有請留下他/她在社群裡的名字' };
const answer = (id, name, gender, dream, sky, letter, partner = '') => ({ id, fields: [
  { label: Q.name, value: name }, { label: Q.gender, value: gender }, { label: Q.partner, value: partner },
  { label: Q.dream, value: dream }, { label: Q.sky, value: sky }, { label: Q.letter, value: letter }] });

test('群星: every player gets the role whose 歸屬／天空／羈絆 match, men and women kept apart', async () => {
  const { matchRoles, ROLE_MATCH_RULES } = await import('../supabase/functions/api/index.ts');
  const result = matchRoles(ROLE_MATCH_RULES['群星'], [
    answer('a', '阿北', '男', '家鄉', '星空', '戀人', '小貝'),
    answer('b', '小貝', '女', '家鄉', '星空', '戀人', '阿北'),
    answer('c', '伊伊', '男', '遠方', '太陽', '家人'),
    answer('d', '索索', '女', '遠方', '太陽', '戀人'),
    answer('e', '馬哥', '男', '家鄉', '太陽', '家人'),
    answer('f', '莉莉', '女', '遠方', '星空', '家人'),
  ]);
  assert.deepEqual(result.assignments.map(a => [a.name, a.role]),
    [['阿北', '張北斗'], ['小貝', '貝斯'], ['伊伊', '伊萬'], ['索索', '索菲亞'], ['馬哥', '馬斯克'], ['莉莉', '達莉婭']]);
  assert.ok(result.assignments.every(a => a.checks.length === 3 && a.checks.every(c => c.ok) && !a.genderNote));
  assert.equal(result.assignments[0].partner, '小貝', 'the partner answer is shown to the store');
  assert.deepEqual(result.unusedRoles, []);
});

test('群星: a player who accepts cross-play takes the other gender only when that fits better; others are never forced unless roles run out', async () => {
  const { matchRoles, ROLE_MATCH_RULES } = await import('../supabase/functions/api/index.ts');
  const rule = ROLE_MATCH_RULES['群星'];
  // 4 women, 2 men: one woman must play a man. The one who accepts it does, even though another woman matches 伊萬 better.
  const r = matchRoles(rule, [
    answer('a', 'A', '女', '遠方', '太陽', '家人'),
    answer('b', 'B', '女，可接受玩男角', '家鄉', '星空', '家人'),
    answer('c', 'C', '女', '遠方', '星空', '家人'),
    answer('d', 'D', '女', '家鄉', '星空', '戀人'),
    answer('e', 'E', '男', '遠方', '太陽', '家人'),
    answer('f', 'F', '男', '家鄉', '太陽', '戀人'),
  ]);
  const by = Object.fromEntries(r.assignments.map(a => [a.name, a]));
  assert.equal(by.B.role, '張北斗');
  assert.equal(by.B.genderNote, '反串（玩家可接受）');
  assert.deepEqual([by.A.role, by.C.role, by.D.role, by.E.role, by.F.role], ['索菲亞', '達莉婭', '貝斯', '伊萬', '馬斯克']);
  // 5 women, nobody accepting: someone is still placed, flagged so the store can talk to them.
  const forced = matchRoles(rule, ['a', 'b', 'c', 'd', 'e'].map(id => answer(id, id, '女', '遠方', '星空', '家人'))
    .concat(answer('m', 'm', '男', '遠方', '太陽', '家人')));
  assert.equal(forced.assignments.filter(a => a.genderNote === '性別不合（角色不夠分）').length, 2);
  assert.ok(forced.assignments.every(a => a.role));
});

test('群星: fewer answers than roles leave roles open; extra answers (a duplicate) get none; blanks never crash', async () => {
  const { matchRoles, ROLE_MATCH_RULES } = await import('../supabase/functions/api/index.ts');
  const rule = ROLE_MATCH_RULES['群星'];
  const few = matchRoles(rule, [answer('a', 'A', '男', '遠方', '太陽', '家人')]);
  assert.deepEqual([few.assignments[0].role, few.unusedRoles.length], ['伊萬', 5]);
  assert.deepEqual(few.assignments[0].alternatives, [], 'no other role fits him on every answer');
  const many = matchRoles(rule, Array.from({ length: 7 }, (_, i) => answer(String(i), 'P' + i, i < 3 ? '男' : '女', '遠方', '星空', '家人')));
  assert.equal(many.assignments.filter(a => !a.role).length, 1);
  assert.equal(new Set(many.assignments.map(a => a.role).filter(Boolean)).size, 6, 'no role is given twice');
  const blank = matchRoles(rule, [{ id: 'x', fields: [{ label: 'other', value: '1' }] }]);
  assert.ok(blank.assignments[0].role);
  assert.equal(blank.assignments[0].name, '');
});

test('store pages: sessions say whether a script can be matched; match picks by date or ticked answers; assign applies all at once', async () => {
  const picked = [answer('11111111-1111-4111-8111-111111111111', '阿北', '男', '家鄉', '星空', '戀人')];
  const b = backend({ answer: name => name === 'admin_role_survey_sessions'
    ? Response.json({ players: 6, sessions: [{ play_date: '2026-10-25', total: 6, unassigned: 6 }] })
    : name === 'admin_role_survey_pick' ? Response.json(picked) : name === 'admin_assign_role_surveys' ? Response.json({ updated: 1 }) : undefined });
  const s = await (await call(b.settings, '/admin/role-surveys/sessions?script=%E7%BE%A4%E6%98%9F')).json();
  assert.deepEqual(s, { players: 6, sessions: [{ playDate: '2026-10-25', total: 6, unassigned: 6 }], rule: true });
  assert.equal((await (await call(b.settings, '/admin/role-surveys/sessions?script=x')).json()).rule, false);

  const m = await (await call(b.settings, '/admin/role-surveys/match', { method: 'POST', body: JSON.stringify({ script: '群星', date: '2026-10-25' }) })).json();
  assert.deepEqual(b.rpcs.filter(r => r[0] === 'admin_role_survey_pick').at(-1)[1],
    { p_actor: 'owner', p_script: '群星', p_play_date: '2026-10-25', p_ids: null });
  assert.equal(m.match.assignments[0].role, '張北斗');
  const ids = [picked[0].id];
  await call(b.settings, '/admin/role-surveys/match', { method: 'POST', body: JSON.stringify({ script: '群星', ids }) });
  assert.deepEqual(b.rpcs.filter(r => r[0] === 'admin_role_survey_pick').at(-1)[1], { p_actor: 'owner', p_script: '群星', p_play_date: null, p_ids: ids });
  const none = await (await call(b.settings, '/admin/role-surveys/match', { method: 'POST', body: JSON.stringify({ script: '王座', ids }) })).json();
  assert.equal(none.match, null, 'a script without a rule still lists the answers');
  for (const body of [{ script: '群星' }, { script: '群星', date: '2026-10-25', ids }, { script: '群星', date: '10/25' },
    { script: '群星', ids: ['x'] }, { script: '群星', ids: Array(31).fill(ids[0]) }]) {
    assert.equal((await call(b.settings, '/admin/role-surveys/match', { method: 'POST', body: JSON.stringify(body) })).status, 400, JSON.stringify(body));
  }

  const ok = await call(b.settings, '/admin/role-surveys/assign', { method: 'POST',
    body: JSON.stringify({ assignments: [{ id: ids[0], role: '張北斗', extra: 1 }] }) });
  assert.deepEqual(await ok.json(), { updated: 1 });
  assert.deepEqual(b.rpcs.filter(r => r[0] === 'admin_assign_role_surveys').at(-1)[1], { p_actor: 'owner', p_assignments: [{ id: ids[0], role: '張北斗' }] });
  for (const body of [{}, { assignments: [] }, { assignments: [{ id: 'x', role: 'a' }] }, { assignments: [{ id: ids[0] }] }]) {
    assert.equal((await call(b.settings, '/admin/role-surveys/assign', { method: 'POST', body: JSON.stringify(body) })).status, 400);
  }
});

test('a full session is announced to the store from the store OA with a link to the suggestion', async () => {
  const { notificationText, ADMIN_NOTIFICATION_KINDS } = await import('../supabase/functions/api/index.ts');
  const text = notificationText({ kind: 'role_survey_complete', script: '群星', play_date: '2026-10-25', count: 6, players: 6 });
  assert.equal(text, '【角色問卷收齊】《群星》10/25（週日）場次的問卷收到 6 份了（6 人本）\n'
    + `看配對建議：https://liff.line.me/2011840025-6cuU9x8P?view=surveys&script=${encodeURIComponent('群星')}&date=2026-10-25`);
  assert.ok(text.includes('看配對建議'));
  assert.ok(notificationText({ kind: 'role_survey_complete', script: '王座', play_date: '2026-10-25', count: 7, players: 7 }).includes('看回覆'));
  assert.ok(ADMIN_NOTIFICATION_KINDS.has('role_survey_complete'));
});
