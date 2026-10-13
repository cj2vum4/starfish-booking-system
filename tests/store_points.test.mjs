// Stage 3 api: redemption requests (player and store), store point tools, notifications and the store OA menu.
import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, notificationText, storeRichMenuDefinition, ADMIN_NOTIFICATION_KINDS } from '../supabase/functions/api/index.ts';

const session = 'S'.repeat(43);
const userId = '55555555-5555-4555-8555-555555555555';
const id = '66666666-6666-4666-8666-666666666666';

function backend({ isAdmin = true, answer = () => undefined, adminToken = 'admin-token' } = {}) {
  const rpcs = [], line = [];
  const fetcher = async (url, opts = {}) => {
    if (url.startsWith('https://api.line.me/') || url.startsWith('https://api-data.line.me/')) {
      line.push({ url, method: opts.method ?? 'GET', auth: opts.headers?.Authorization });
      if (url.endsWith('/richmenu/list')) return Response.json({ richmenus: [{ name: '海星選單・店家', richMenuId: 'old' }, { name: '別的', richMenuId: 'x' }] });
      if (url === 'https://api.line.me/v2/bot/richmenu') return Response.json({ richMenuId: 'store-new' });
      return new Response('{}', { headers: { 'content-type': 'application/json' } });
    }
    if (url.startsWith('https://img.example/')) return new Response(new Uint8Array(500));
    const name = url.split('/rpc/')[1], args = opts.body ? JSON.parse(opts.body) : {};
    rpcs.push([name, args]);
    const custom = answer(name, args);
    if (custom) return custom;
    if (name === 'resolve_session') return Response.json({ user_id: userId, display_name: '店長', is_admin: isAdmin, expires_at: 'x' });
    if (name === 'claim_notifications') return Response.json([]);
    return Response.json({ ok: true, balance_after: 1 });
  };
  return { rpcs, line, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [], lineAccessToken: 'player-token',
    adminLineAccessToken: adminToken, richMenuImageUrls: { store: 'https://img.example/store.jpg' }, fetcher } };
}
const call = (settings, path, { method = 'GET', body } = {}) => handleApi(new Request(`https://x/functions/v1/api${path}`,
  { method, body: body == null ? undefined : JSON.stringify(body), headers: { Authorization: `Bearer ${session}` } }), settings);
const args = (b, name) => b.rpcs.filter(r => r[0] === name).map(r => r[1]);

test('a player requests, lists and cancels redemptions; a resend carries the same key', async () => {
  const b = backend({ isAdmin: false });
  assert.equal((await call(b.settings, '/me/redemptions')).status, 200);
  const res = await call(b.settings, '/me/redemptions', { method: 'POST', body: { rewardId: id, title: '解謎王', requestId: id.toUpperCase() } });
  assert.equal(res.status, 201);
  assert.deepEqual(args(b, 'request_redemption')[0], { p_actor: userId, p_reward_id: id, p_title: '解謎王', p_request_key: `me:${userId}:${id}` });
  assert.equal((await call(b.settings, '/me/redemptions', { method: 'POST', body: { rewardId: 'x' } })).status, 400);
  assert.equal((await call(b.settings, `/me/redemptions/${id}/cancel`, { method: 'POST' })).status, 200);
  assert.deepEqual(args(b, 'cancel_redemption')[0], { p_actor: userId, p_id: id });
  const poor = backend({ isAdmin: false, answer: n => n === 'request_redemption'
    ? Response.json({ code: 'P0001', message: 'NOT_ENOUGH_POINTS' }, { status: 400 }) : undefined });
  const r2 = await call(poor.settings, '/me/redemptions', { method: 'POST', body: { rewardId: id } });
  assert.deepEqual([r2.status, (await r2.json()).error], [409, 'NOT_ENOUGH_POINTS']);
});

test('the store decides, adjusts, redeems, voids, hides, features and edits settings through one RPC each', async () => {
  const b = backend();
  await call(b.settings, `/admin/redemptions/${id}/approve`, { method: 'POST', body: { title: '王', note: 'ok' } });
  await call(b.settings, `/admin/redemptions/${id}/reject`, { method: 'POST', body: { note: '沒開本' } });
  assert.deepEqual(args(b, 'admin_decide_redemption').map(a => [a.p_approve, a.p_title, a.p_note]), [[true, '王', 'ok'], [false, '', '沒開本']]);
  await call(b.settings, '/admin/players/adjust', { method: 'POST', body: { name: '小美', points: -30, reason: '扣錯補回', requestId: id } });
  assert.deepEqual(args(b, 'admin_adjust_points')[0], { p_actor: userId, p_player: '小美', p_points: -30, p_reason: '扣錯補回', p_request_key: `admin:${id}` });
  assert.equal((await call(b.settings, '/admin/players/adjust', { method: 'POST', body: { name: '小美', points: '5', reason: 'x' } })).status, 400);
  await call(b.settings, '/admin/players/redeem', { method: 'POST', body: { name: '小美', rewardId: id, title: '', note: '到店' } });
  assert.equal(args(b, 'admin_redeem')[0].p_reward_id, id);
  await call(b.settings, '/admin/players/glory', { method: 'POST', body: { name: '小美', gilded: true, title: 'x', legend: false } });
  await call(b.settings, '/admin/players/alias', { method: 'POST', body: { name: '小美', alias: '美美', remove: true } });
  await call(b.settings, '/admin/players/merge', { method: 'POST', body: { from: '阿華', into: '小美' } });
  assert.deepEqual(args(b, 'admin_merge_players')[0], { p_actor: userId, p_from: '阿華', p_into: '小美' });
  await call(b.settings, `/admin/ledger/${id}/void`, { method: 'POST', body: { reason: '按錯' } });
  await call(b.settings, `/admin/reviews/${id}/hide`, { method: 'POST', body: { hidden: false } });
  await call(b.settings, `/admin/reviews/${id}/feature`, { method: 'POST', body: { featured: true } });
  assert.deepEqual([args(b, 'admin_hide_record')[0].p_hide, args(b, 'admin_feature_record')[0].p_featured], [false, true]);
  await call(b.settings, '/admin/players?q=%E5%B0%8F');
  await call(b.settings, '/admin/players?name=%E5%B0%8F%E7%BE%8E');
  assert.deepEqual([args(b, 'admin_players')[0].p_query, args(b, 'admin_player')[0].p_name], ['小', '小美']);
  await call(b.settings, '/admin/record-settings', { method: 'POST', body: { type: 'setting', key: '基本點數', value: 12 } });
  await call(b.settings, '/admin/record-settings', { method: 'POST', body: { type: 'reward', name: '點播權', cost: 150, track: '特權' } });
  await call(b.settings, '/admin/record-settings', { method: 'POST', body: { type: 'quest', id: '場次', goal: 3, points: 20 } });
  assert.deepEqual([args(b, 'admin_save_setting')[0].p_value, args(b, 'admin_save_reward')[0].p_id, args(b, 'admin_save_quest')[0].p_goal], ['12', null, 3]);
  assert.equal((await call(b.settings, '/admin/record-settings', { method: 'POST', body: { type: 'nope' } })).status, 400);
  assert.equal((await call(b.settings, '/admin/records/report')).status, 200);
  assert.equal((await call(b.settings, '/admin/reviews?before=bad')).status, 400);
  // No notification run is needed for these: the database queued what is needed and the POST sends it afterwards.
  assert.ok(args(b, 'claim_notifications').length > 0, 'queued redemption notices go out after the store acts');
});

test('redemption notifications: the store hears from its own OA, the player from the players OA, both with links', () => {
  assert.ok(ADMIN_NOTIFICATION_KINDS.has('redemption_requested'));
  assert.match(notificationText({ kind: 'redemption_requested', record_name: '小美', reward: '自訂專屬稱號', cost: 200, balance: 280, title: '解謎王' }, 'L'),
    /小美 想兌換「自訂專屬稱號」（200 點，餘額 280）\n稱號：解謎王\n審核：https:\/\/liff\.line\.me\/L\?view=redemptions/);
  assert.match(notificationText({ kind: 'redemption_approved', reward: '折抵 50 元', cost: 50, balance: 30 }, 'L'), /扣 50 點，目前餘額 30 點/);
  assert.match(notificationText({ kind: 'redemption_rejected', reward: '折抵 50 元', note: '這週沒有開本' }, 'L'), /沒有通過：這週沒有開本。點數沒有扣/);
});

test('the store OA menu: six cells to the store pages, built with the store OA token, older copy removed', async () => {
  const links = storeRichMenuDefinition('L').areas.map(a => a.action.uri);
  assert.deepEqual(links, ['redemptions', 'players', 'reviews', 'admin', 'bindings', null]
    .map(v => 'https://liff.line.me/L' + (v ? '?view=' + v : '')));
  const b = backend();
  const res = await call(b.settings, '/admin/richmenu/store', { method: 'POST' });
  assert.deepEqual(await res.json(), { storeMenuId: 'store-new', replaced: 1 });
  assert.ok(b.line.length > 0 && b.line.every(c => c.auth === 'Bearer admin-token'), 'only the store OA token');
  assert.ok(b.line.some(c => c.method === 'DELETE' && c.url.endsWith('/richmenu/old')));
  assert.ok(!b.line.some(c => c.url.endsWith('/richmenu/x')), 'menus with other names stay');
  const player = backend({ isAdmin: false });
  assert.equal((await call(player.settings, '/admin/richmenu/store', { method: 'POST' })).status, 403);
  const noToken = backend({ adminToken: '' });
  assert.equal((await (await call(noToken.settings, '/admin/richmenu/store', { method: 'POST' })).json()).error, 'ADMIN_OA_NOT_CONFIGURED');
});
