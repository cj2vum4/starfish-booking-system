// 玩本記錄 on Supabase (stage 2): the website's public routes, the cutover flag deciding where names, cards and the
// 回歸禮 come from, the store's import / reconcile / switch routes, and reading the 玩本記錄 spreadsheet.
import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { handleApi, playRecordsFromSheet, runScheduledWork, sha256Hex } from '../supabase/functions/api/index.ts';

const SITE = 'https://cj2vum4.github.io';
const SCRIPT = 'https://script.example/exec';
const session = 'S'.repeat(43);
const userId = '44444444-4444-4444-8444-444444444444';
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const google = { clientEmail: 'sa@test.iam.gserviceaccount.com', calendarId: 'owner@example.com',
  privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const PAYLOAD = { ok: true, updatedAt: '2026-10-12T00:00:00.000Z', monthKey: '2026/10', doubleDayNote: '平日開本，點數兩倍',
  summary: [{ name: '阿明', agent: '#001', earned: 120, redeemed: 20, balance: 100, monthEarned: 10, plays: 9, last: '2026/9/20',
    questProgress: { 場次: 1 }, gilded: false, title: '', legend: false }], rewards: [], mystery: [], interactions: [], quests: [], rules: [] };

// Fake PostgREST + Apps Script + Google. `live` is the cutover flag; `answer(name, args)` may override a result.
function backend({ live = false, isAdmin = true, binding = null, answer = () => undefined, sheets = null, scriptSummary = PAYLOAD } = {}) {
  const rpcs = [], posts = [];
  let current = binding;
  const fetcher = async (url, opts = {}) => {
    if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'g', expires_in: 3600 });
    if (url.startsWith('https://sheets.googleapis.com/')) {
      if (url.includes('?fields=')) return Response.json(sheets.meta);
      return Response.json(sheets.values);
    }
    if (url === `${SCRIPT}?action=summary`) return Response.json(scriptSummary);
    if (url === SCRIPT) { posts.push(opts.body); return Response.json({ ok: true, granted: true }); }
    if (url.includes('line.me')) return Response.json({ richmenus: [] });
    const name = url.split('/rpc/')[1], args = opts.body ? JSON.parse(opts.body) : {};
    rpcs.push([name, args]);
    const custom = answer(name, args);
    if (custom) return custom;
    const notLive = () => Response.json({ code: 'P0001', message: 'RECORDS_NOT_LIVE' }, { status: 400 });
    switch (name) {
      case 'resolve_session': return Response.json(args.p_session_hash === await sha256Hex(session)
        ? { user_id: userId, display_name: '店長', is_admin: isAdmin, expires_at: 'x' } : null);
      case 'records_source': return Response.json(live ? 'supabase' : 'gas');
      case 'submit_play_record': return live ? Response.json({ id: 'r1', status: 'earn', player: '阿明',
        award: { points: 45, detail: '基本10＋首玩5＋首探10＋新手好運20', script: '年輪', extra: [] } }) : notLive();
      case 'submit_review_like': return live ? Response.json({ ok: true, likes: 3 }) : notLive();
      case 'public_play_records': return Response.json(live ? [{ name: '阿明', date: '2026/9/1', script: '年輪', character: '甲',
        rating: '5', comment: '好玩' }] : null);
      case 'public_records_payload': return Response.json(live ? PAYLOAD : null);
      case 'get_record_snapshot': return Response.json({ payload: PAYLOAD, fetched_at: new Date(Date.now() - 1000).toISOString() });
      case 'record_names': return Response.json(live ? [{ name: '阿明', agent: '#001', plays: 9, last: '2026/9/20' }] : null);
      case 'record_card': return Response.json(live ? { card: PAYLOAD.summary[0], rewards: [{ track: '保底', name: '折抵', cost: 50, note: '' }] } : null);
      case 'record_name_taken': return Response.json(args.p_name.includes('明'));
      case 'bound_record_names': return Response.json([]);
      case 'my_binding': return Response.json(current);
      case 'my_record_account': return Response.json(null);
      case 'claim_record_name': return Response.json({ record_name: args.p_name.trim() });
      case 'request_binding': return Response.json({ user_id: userId, record_name: args.p_name.trim(), status: 'pending', bonus_status: 'none' });
      case 'admin_decide_binding': current = { ...current, status: 'approved' }; return Response.json(current);
      case 'grant_record_return_bonus': current = { ...current, bonus_status: 'granted' }; return Response.json(current);
      case 'mark_binding_bonus': current = { ...current, bonus_status: args.p_status }; return Response.json(current);
      case 'admin_records_status': return Response.json({ source: live ? 'supabase' : 'gas', imported_at: null, players: 0 });
      case 'admin_import_play_records': return Response.json({ players: args.p_data.players.length, records: args.p_data.responses.length,
        ledger: args.p_data.ledger.length, interactions: 0, anomalies: [] });
      case 'admin_import_new_play_records': case 'system_import_new_play_records':
        return Response.json({ added: args.p_rows.length, skipped: 0 });
      case 'admin_records_reconcile': return Response.json({ matched: true, differences: [] });
      case 'admin_set_records_source': return Response.json({ source: args.p_source });
      case 'put_record_snapshot': case 'expire_record_snapshot': return Response.json({ ok: true });
      case 'claim_scheduled_job': return Response.json(args.p_name === 'records-catch-up');
      case 'expire_stale_groups': return Response.json(0);
      default: return Response.json([]);
    }
  };
  return { rpcs, posts, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [SITE],
    playRecordUrl: SCRIPT, playRecordSecret: 'bonus-secret', lineAccessToken: 'line', google, fetcher, now: () => Date.now() } };
}
const call = (settings, path, { method = 'GET', body, origin, auth = true } = {}) => handleApi(new Request(`https://x/functions/v1/api${path}`,
  { method, body: body == null ? undefined : typeof body === 'string' ? body : JSON.stringify(body),
    headers: { ...(auth ? { Authorization: `Bearer ${session}` } : {}), ...(origin ? { Origin: origin } : {}) } }), settings);
const rpcArgs = (b, name) => b.rpcs.filter(r => r[0] === name).map(r => r[1]);

test('before the cutover the website is told to keep using the Apps Script', async () => {
  const b = backend({ live: false });
  const post = await call(b.settings, '/public/play-records', { method: 'POST', auth: false, origin: SITE,
    body: { id: 'A1B2C3D4-0000-4000-8000-000000000001', name: '阿明', date: '2026/10/5', script: '年輪', character: '甲', rating: '5' } });
  assert.equal(post.status, 503);
  assert.deepEqual(await post.json(), { ok: false, error: 'RECORDS_NOT_LIVE', live: false });
  assert.equal(post.headers.get('access-control-allow-origin'), '*', 'the page must read the answer to fall back');
  const like = await call(b.settings, '/public/likes', { method: 'POST', auth: false,
    body: { script: '年輪', date: '2026/9/1', author: '阿明', liker: '00000000-0000-4000-8000-0000000000a1' } });
  assert.deepEqual([like.status, (await like.json()).live], [503, false]);
  const list = await call(b.settings, '/public/play-records', { auth: false });
  assert.deepEqual([list.status, (await list.json()).live], [503, false]);
  // Points still come from the Apps Script copy.
  const records = await call(b.settings, '/public/records', { auth: false });
  assert.equal((await records.json()).summary[0].name, '阿明');
  assert.ok(rpcArgs(b, 'get_record_snapshot').length, 'served from the saved Apps Script copy');
  const pre = await call(b.settings, '/public/play-records', { method: 'OPTIONS', auth: false, origin: 'https://any.example' });
  assert.deepEqual([pre.status, pre.headers.get('access-control-allow-origin')], [204, '*']);
});

test('after the cutover the website writes and reads the booking system', async () => {
  const b = backend({ live: true });
  const res = await call(b.settings, '/public/play-records', { method: 'POST', auth: false,
    body: JSON.stringify({ id: 'A1B2C3D4-0000-4000-8000-000000000001', name: ' 阿明 ', date: '2026/10/5', script: '年輪',
      character: '甲', rating: 5, comment: '好玩', referrer: '小美', scriptLabel: '年輪', timestamp: 'x' }) });
  assert.equal(res.status, 201);
  const data = await res.json();
  assert.deepEqual([data.ok, data.live, data.status, data.award.points], [true, true, 'earn', 45]);
  // The canonical name would reveal which leaderboard name an alias belongs to.
  assert.deepEqual(Object.keys(data).sort(), ['award', 'live', 'ok', 'status']);
  assert.deepEqual(rpcArgs(b, 'submit_play_record')[0], { p_record: { name: ' 阿明 ', date: '2026/10/5', script: '年輪', role: '甲',
    rating: '5', comment: '好玩', referrer: '小美' }, p_client_id: 'a1b2c3d4-0000-4000-8000-000000000001' });
  assert.ok(!rpcArgs(b, 'claim_notifications').length, 'no notification run after a public post');
  // Honeypot: ok, nothing saved.
  const bot = await call(b.settings, '/public/play-records', { method: 'POST', auth: false, body: { name: 'x', website: 'http://spam' } });
  assert.deepEqual([bot.status, await bot.json()], [200, { ok: true }]);
  assert.equal(rpcArgs(b, 'submit_play_record').length, 1);
  // Likes need the browser's own ID.
  assert.equal((await call(b.settings, '/public/likes', { method: 'POST', auth: false, body: { script: '年輪', date: '2026/9/1', author: '阿明' } })).status, 400);
  const like = await call(b.settings, '/public/likes', { method: 'POST', auth: false,
    body: { script: '年輪', date: '2026/9/1', author: '阿明', liker: '00000000-0000-4000-8000-0000000000A1' } });
  assert.deepEqual(await like.json(), { ok: true, likes: 3, live: true });
  assert.equal(rpcArgs(b, 'submit_review_like')[0].p_liker, '00000000-0000-4000-8000-0000000000a1');
  // The review list replaces the CSV; the summary is computed by the database.
  const list = await call(b.settings, '/public/play-records?script=%E5%B9%B4%E8%BC%AA', { auth: false });
  assert.equal(list.headers.get('cache-control'), 'public, max-age=30');
  const body = await list.json();
  assert.deepEqual([body.ok, body.live, body.records[0].character, body.records[0].rating], [true, true, '甲', '5']);
  assert.equal(rpcArgs(b, 'public_play_records')[0].p_script, '年輪');
  const records = await call(b.settings, '/public/records', { auth: false });
  assert.deepEqual(await records.json(), { ...PAYLOAD, live: true });
  assert.ok(!rpcArgs(b, 'get_record_snapshot').length, 'not served from the Apps Script copy');
  assert.deepEqual(await (await call(b.settings, '/health/records', { auth: false })).json(), { ok: true, source: 'supabase', players: 1 });
});

test('after the cutover names, naming and the member card come from the database', async () => {
  const b = backend({ live: true });
  const names = await (await call(b.settings, '/records/names')).json();
  assert.deepEqual(names.names, [{ name: '阿明', agent: '#001', plays: 9, last: '2026/9/20' }]);
  // A name matching a player or alias (spaces and case ignored) cannot be taken by a new player.
  const taken = await call(b.settings, '/me/survey/name', { method: 'POST', body: { name: '阿 明' } });
  assert.deepEqual([taken.status, (await taken.json()).error], [409, 'NAME_EXISTS']);
  const fresh = await call(b.settings, '/me/survey/name', { method: 'POST', body: { name: '新朋友' } });
  assert.deepEqual([fresh.status, (await fresh.json()).recordName], [201, '新朋友']);
  assert.ok(!b.rpcs.some(r => r[0] === 'get_record_snapshot'), 'the Apps Script copy is not consulted');
  const missing = await call(b.settings, '/me/binding', { method: 'POST', body: { name: '不存在' } });
  assert.equal(missing.status, 404);
  assert.equal((await call(b.settings, '/me/binding', { method: 'POST', body: { name: '阿明' } })).status, 201);

  // An approved binding: the 回歸禮 is granted by the database at once, then the card is read from it.
  const card = backend({ live: true, binding: { user_id: userId, record_name: '阿明', status: 'approved', bonus_status: 'none' } });
  const data = await (await call(card.settings, '/me/binding')).json();
  assert.equal(data.binding.bonusStatus, 'granted');
  assert.deepEqual(rpcArgs(card, 'grant_record_return_bonus')[0], { p_user_id: userId, p_points: 50 });
  assert.equal(card.posts.length, 0, 'no Apps Script grant');
  assert.deepEqual([data.card.balance, data.card.stale, data.rewards[0].name], [100, false, '折抵']);
});

test('the store approving a binding after the cutover grants the 回歸禮 in the database', async () => {
  const b = backend({ live: true, binding: { user_id: userId, record_name: '阿明', status: 'pending', bonus_status: 'none' } });
  const res = await call(b.settings, `/admin/bindings/${userId}/approve`, { method: 'POST' });
  const data = await res.json();
  assert.deepEqual([res.status, data.binding.bonusStatus, data.bonusError], [200, 'granted', null]);
  assert.equal(b.posts.length, 0);
  // Before the cutover the Apps Script grants it, as today.
  const old = backend({ live: false, binding: { user_id: userId, record_name: '阿明', status: 'pending', bonus_status: 'none' } });
  await call(old.settings, `/admin/bindings/${userId}/approve`, { method: 'POST' });
  assert.equal(old.posts.length, 1);
  assert.ok(!rpcArgs(old, 'grant_record_return_bonus').length);
});

test('a database without the stage-2 migration keeps every Apps Script path', async () => {
  const b = backend({ answer: (name) => ['records_source', 'record_names', 'public_records_payload'].includes(name)
    ? new Response('{}', { status: 404 }) : undefined });
  assert.equal((await (await call(b.settings, '/records/names')).json()).names[0].name, '阿明');
  assert.equal((await call(b.settings, '/public/records', { auth: false })).status, 200);
  assert.equal((await call(b.settings, '/me/survey/name', { method: 'POST', body: { name: '新朋友' } })).status, 201);
});

test('after the cutover a database failure is never answered with Apps Script data or "not switched yet"', async () => {
  const broken = (names) => (name) => names.includes(name) ? Response.json({ code: 'XX000', message: 'boom' }, { status: 500 }) : undefined;
  const b = backend({ live: true, answer: broken(['public_play_records', 'public_records_payload']) });
  const list = await call(b.settings, '/public/play-records', { auth: false });
  assert.equal(list.status, 503);
  assert.deepEqual(await list.json(), { ok: false, error: 'RECORDS_UNAVAILABLE' }, 'no live:false, so the website keeps its copy');
  const sum = await call(b.settings, '/public/records', { auth: false });
  assert.equal(sum.status, 503, 'not the Apps Script snapshot');
  assert.ok(!rpcArgs(b, 'get_record_snapshot').length);
  // The switch itself unreadable: no 回歸禮 to the Apps Script, no name check against its stale copy.
  const c = backend({ live: true, binding: { user_id: userId, record_name: '阿明', status: 'pending', bonus_status: 'none' },
    answer: broken(['records_source']) });
  assert.equal((await call(c.settings, '/me/survey/name', { method: 'POST', body: { name: '新朋友' } })).status, 503);
  const approve = await call(c.settings, `/admin/bindings/${userId}/approve`, { method: 'POST' });
  assert.equal(approve.status, 200);
  assert.equal(c.posts.length, 0, 'nothing sent to the Apps Script');
  assert.equal((await approve.json()).bonusError, 'RECORDS_UNAVAILABLE');
});

test('without migration 0036 the website goes straight to the Apps Script', async () => {
  const missing = (name) => ['submit_play_record', 'submit_review_like', 'public_play_records'].includes(name)
    ? Response.json({ code: 'PGRST202', message: 'Could not find the function' }, { status: 404 }) : undefined;
  const b = backend({ answer: missing });
  const post = await call(b.settings, '/public/play-records', { method: 'POST', auth: false, body: { name: 'A' } });
  assert.deepEqual([post.status, (await post.json()).live], [503, false]);
  const like = await call(b.settings, '/public/likes', { method: 'POST', auth: false,
    body: { script: 'X', date: '2026/9/1', author: 'A', liker: '00000000-0000-4000-8000-000000000001' } });
  assert.deepEqual([like.status, (await like.json()).live], [503, false]);
  assert.equal((await (await call(b.settings, '/public/play-records', { auth: false })).json()).live, false);
});

const SHEET = {
  meta: { properties: { timeZone: 'Asia/Taipei' }, sheets: [{ properties: { title: '表單回應 1', sheetId: 463584243 } },
    ...['點數帳本', '玩家', '設定', '獎勵', '任務', '心得互動', '月報'].map((title, i) => ({ properties: { title, sheetId: i + 1 } }))] },
  values: { valueRanges: [
    { values: [['時間戳記', '怎麼稱呼你呢', '日期', '劇本', '角色', '給予評價', '50字以內的心得推薦', '介紹人', '角色 (舊表單)'],
      [46296.5, '阿明', 46296, '年輪', '甲', 5, '好玩', '', ''], [46296.5, '小美', '2026/9/30', '年輪', '', '4', '', '阿明', '乙'],
      ['', '', '', '', '', '', '', '', '']] },
    { values: [['時間戳記', '玩家名', '歸戶名', '類型', '點數', '明細', '劇本', '日期', '來源', '狀態', '備註', '去重鍵'],
      [46296.5, '阿明', '阿明', 'earn', 45, '基本10', '年輪', 46296, '表單', '有效', '', '阿明|年輪|2026/9/30']] },
    { values: [['顯示名', '別名', '探員編號', '加入日期', '備註', '鍍金', '自訂稱號', '傳奇殿堂'], ['阿明', 'Ming、明明', '#001', 46296, '', true, '王', 'TRUE']] },
    { values: [['設定項', '值', '說明'], ['基本點數', 10, ''], ['回歸禮資格日', 46301, ''], ['雙倍日', '平日', '']] },
    { values: [['軌道', '品項', '所需點數', '說明', '是否上架'], ['保底', '折抵 50 元', 50, '', false], ['特權', '點播權', 150, '', '']] },
    { values: [['任務ID', '說明', '目標', '點數', '是否啟用'], ['場次', '本月完成 {目標} 場', 3, 20, 'FALSE']] },
    { values: [['劇本', '日期', '作者', '讚數', '精選', '最後更新'], ['年輪', 46296, '阿明', 3, '是', 46297.25]] },
  ] },
};

test('the 玩本記錄 spreadsheet is read as the Apps Script saw it', async () => {
  const tabs = Object.fromEntries(['表單回應 1', '點數帳本', '玩家', '設定', '獎勵', '任務', '心得互動']
    .map((t, i) => [t, SHEET.values.valueRanges[i].values]));
  const data = await playRecordsFromSheet(tabs, '表單回應 1', 'Asia/Taipei');
  assert.equal(data.responses.length, 2, 'blank rows are skipped');
  const [a, b] = data.responses;
  assert.deepEqual([a.stamp, a.date, a.rating, a.role], ['2026-10-01T04:00:00.000Z', '2026/10/1', '5', '甲']);
  assert.deepEqual([b.date, b.role, b.referrer], ['2026/9/30', '乙', '阿明'], 'any 角色… column, date text kept');
  assert.notEqual(a.key, b.key, 'two rows with the same time are still different rows');
  assert.equal(a.key, (await playRecordsFromSheet(tabs, '表單回應 1', 'Asia/Taipei')).responses[0].key, 'keys are stable');
  assert.deepEqual(data.ledger[0], { stamp: '2026-10-01T04:00:00.000Z', name: '阿明', player: '阿明', type: 'earn', points: 45,
    detail: '基本10', script: '年輪', date: '2026/10/1', source: '表單', status: '有效', note: '', key: '阿明|年輪|2026/9/30' });
  assert.deepEqual(data.players[0], { name: '阿明', aliases: ['Ming', '明明'], agent: '#001', joined: '2026/10/1', note: '',
    gilded: true, title: '王', legend: true });
  assert.deepEqual(data.config, [{ key: '基本點數', value: '10' }, { key: '回歸禮資格日', value: '2026/10/6' }, { key: '雙倍日', value: '平日' }]);
  assert.deepEqual(data.rewards.map(r => r.active), [false, true]);
  assert.deepEqual(data.quests[0], { id: '場次', label: '本月完成 {目標} 場', goal: 3, points: 20, active: false });
  assert.deepEqual(data.interactions[0], { script: '年輪', date: '2026/10/1', author: '阿明', likes: 3, featured: true,
    updated: '2026-10-01T22:00:00.000Z' });
  // Review fixes: identical 角色 headers keep every column; a typed text stamp is that day (parseDate_); none stays none;
  // 雙倍日 typed as a weekday digit is that digit, not 1900/1/5.
  const odd = await playRecordsFromSheet({
    '表單回應 1': [['時間戳記', '怎麼稱呼你呢', '日期', '劇本', '角色', '角色', '給予評價'],
      ['2025/3/1 下午 3:04:05', '阿明', '2025/3/1', '年輪', '甲', '', 5],
      ['', '小美', '2025/3/2', '青樓', '', '莫懷', 4]],
    '設定': [['設定項', '值'], ['雙倍日', 6], ['LINE上線日', 46301]] }, '表單回應 1', 'Asia/Taipei');
  assert.deepEqual(odd.responses.map(r => [r.stamp, r.role]), [['2025-02-28T16:00:00.000Z', '甲'], [null, '莫懷']]);
  assert.deepEqual(odd.config, [{ key: '雙倍日', value: '6' }, { key: 'LINE上線日', value: '2026/10/6' }]);
});

test('the store imports, reconciles and switches; only the store may', async () => {
  const b = backend({ sheets: SHEET });
  const status = await (await call(b.settings, '/admin/records')).json();
  assert.deepEqual([status.source, status.serviceAccountEmail], ['gas', google.clientEmail]);
  const imported = await (await call(b.settings, '/admin/records/import', { method: 'POST' })).json();
  assert.deepEqual([imported.players, imported.records, imported.ledger], [1, 2, 1]);
  const reconcile = await (await call(b.settings, '/admin/records/reconcile')).json();
  assert.deepEqual([reconcile.matched, reconcile.snapshotFresh], [true, true]);
  assert.ok(rpcArgs(b, 'put_record_snapshot').length, 'compared against the Apps Script summary read just now');
  const snapshotsBefore = rpcArgs(b, 'put_record_snapshot').length;
  const switched = await (await call(b.settings, '/admin/records/source', { method: 'POST', body: { source: 'supabase' } })).json();
  assert.equal(switched.source, 'supabase');
  assert.equal(rpcArgs(b, 'put_record_snapshot').length, snapshotsBefore + 1, 'the Apps Script summary is read again right before switching');
  assert.deepEqual(rpcArgs(b, 'admin_set_records_source')[0], { p_actor: userId, p_source: 'supabase', p_force: false });
  assert.equal((await call(b.settings, '/admin/records/source', { method: 'POST', body: { source: 'x' } })).status, 400);
  const newRows = await (await call(b.settings, '/admin/records/import-new', { method: 'POST' })).json();
  assert.equal(newRows.added, 2);
  const player = backend({ isAdmin: false, sheets: SHEET });
  assert.equal((await call(player.settings, '/admin/records/import', { method: 'POST' })).status, 403);
  assert.equal(rpcArgs(player, 'admin_import_play_records').length, 0);
});

test('after the cutover the 5-minute schedule brings in records the website sent to the Apps Script', async () => {
  const b = backend({ live: true, sheets: SHEET });
  await runScheduledWork(b.settings);
  assert.equal(rpcArgs(b, 'system_import_new_play_records')[0].p_rows.length, 2);
  const before = backend({ live: false, sheets: SHEET });
  await runScheduledWork(before.settings);
  assert.ok(!rpcArgs(before, 'system_import_new_play_records').length, 'nothing to catch up before the cutover');
  // The spreadsheet no longer shared: the store's screen gets the code instead of silence.
  const unshared = backend({ live: true, sheets: SHEET, answer: () => undefined });
  const fetcher = unshared.settings.fetcher;
  unshared.settings.fetcher = (url, opts) => url.startsWith('https://sheets.googleapis.com/')
    ? Promise.resolve(new Response('{}', { status: 403 })) : fetcher(url, opts);
  await runScheduledWork(unshared.settings);
  assert.equal(rpcArgs(unshared, 'system_records_catch_up_failed').length, 1);
  assert.match(rpcArgs(unshared, 'system_records_catch_up_failed')[0].p_code, /^[A-Z_]+$/);
});
