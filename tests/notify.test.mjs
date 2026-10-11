import test from 'node:test';
import assert from 'node:assert/strict';
import { deliverNotifications, handleApi, notificationText, sha256Hex } from '../supabase/functions/api/index.ts';

const gid = '66666666-6666-4666-8666-666666666666';
const facts = { group_id: gid, starts_at: '2026-10-10T05:00:00+00:00', ends_at: '2026-10-10T09:00:00+00:00',
  game_title: '王座', organizer_name: '阿明', capacity: 6, filled: 6, joiner_name: '小華', venue: '南港',
  dm_name: '海星', price_cents: 40000, cancel_reason: 'DM 生病' };

test('every notification names the session in Taipei time and links to its group page', () => {
  const kinds = ['group_created', 'member_joined', 'group_full', 'group_full_members', 'group_confirmed', 'event_cancelled', 'group_dissolved'];
  for (const kind of kinds) {
    const text = notificationText({ ...facts, kind }, 'LIFF-ID');
    assert.ok(text.includes('13:00–17:00'), `${kind}: Taipei time`);
    assert.ok(text.includes(`https://liff.line.me/LIFF-ID?group=${gid}`), `${kind}: link`);
  }
  assert.match(notificationText({ ...facts, kind: 'group_confirmed' }), /場地：南港[\s\S]*DM：海星[\s\S]*每人 NT\$400/);
  assert.match(notificationText({ ...facts, kind: 'event_cancelled' }), /原因：DM 生病/);
  assert.match(notificationText({ ...facts, kind: 'member_joined' }), /小華 加入[\s\S]*6\/6[\s\S]*已滿團/);
  assert.ok(!notificationText({ ...facts, kind: 'member_joined', filled: 3 }).includes('已滿團'));
  assert.equal(notificationText({ ...facts, kind: 'something_else' }), null);
});

function line(statusFor) {
  const calls = { push: [], complete: [], claimed: 0 };
  const batch = [
    { id: 'n1', line_user_id: 'U1', friend_status: 'active', retry_key: 'k1', payload: { ...facts, kind: 'group_confirmed' } },
    { id: 'n2', line_user_id: 'U2', friend_status: 'blocked', retry_key: 'k2', payload: { ...facts, kind: 'group_confirmed' } },
    { id: 'n3', line_user_id: 'U3', friend_status: 'unknown', retry_key: 'k3', payload: { ...facts, kind: 'group_confirmed' } },
  ];
  const fetcher = async (url, opts = {}) => {
    if (url === 'https://api.line.me/v2/bot/message/push') {
      const body = JSON.parse(opts.body);
      calls.push.push({ to: body.to, key: opts.headers['X-Line-Retry-Key'], auth: opts.headers.Authorization, text: body.messages[0].text });
      return new Response('{}', { status: statusFor(body.to) });
    }
    const name = url.split('/rpc/')[1];
    const args = JSON.parse(opts.body);
    if (name === 'claim_notifications') { calls.claimed++; return Response.json(calls.claimed === 1 ? batch : []); }
    if (name === 'complete_notification') { calls.complete.push([args.p_id, args.p_result, args.p_error]); return Response.json({ ok: true }); }
    if (name === 'resolve_session') return Response.json({ user_id: 'u', display_name: 'x', is_admin: true, expires_at: 'x' });
    return Response.json({ group_id: gid, created: true });
  };
  return { calls, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
    lineAccessToken: 'line-token', fetcher } };
}

test('delivery: sent on 200 or 409, retried on 429/5xx, skipped for blocked or rejected users', async () => {
  const { calls, settings } = line(to => ({ U1: 200, U3: 400 })[to]);
  assert.deepEqual(await deliverNotifications(settings), { sent: 1, skipped: 2, failed: 0 });
  assert.deepEqual(calls.push.map(p => p.to), ['U1', 'U3'], 'blocked user never pushed');
  assert.deepEqual(calls.push[0].key, 'k1');
  assert.equal(calls.push[0].auth, 'Bearer line-token');
  assert.deepEqual(calls.complete, [['n1', 'sent', null], ['n2', 'skipped', 'BLOCKED'], ['n3', 'skipped', 'HTTP_400']]);
  for (const [status, result] of [[409, 'sent'], [429, 'failed'], [503, 'failed']]) {
    const run = line(() => status);
    await deliverNotifications(run.settings);
    assert.equal(run.calls.complete[0][1], result, `HTTP ${status}`);
  }
  const offline = line(() => { throw new Error('network down'); });
  assert.deepEqual(await deliverNotifications(offline.settings), { sent: 0, skipped: 1, failed: 2 });
  assert.deepEqual(offline.calls.complete.map(c => c[2]), ['NETWORK', 'BLOCKED', 'NETWORK']);
});

test('nothing is claimed without a channel token; a successful change triggers delivery in the background', async () => {
  const none = line(() => 200);
  delete none.settings.lineAccessToken;
  await deliverNotifications(none.settings);
  assert.equal(none.calls.claimed, 0);

  const live = line(() => 200);
  const session = 'S'.repeat(43);
  const base = live.settings.fetcher;
  live.settings.fetcher = async (url, opts) => url.endsWith('/resolve_session')
    ? Response.json(JSON.parse(opts.body).p_session_hash === await sha256Hex(session)
      ? { user_id: 'u', display_name: 'x', is_admin: true, expires_at: 'x' } : null) : base(url, opts);
  const pending = [];
  live.settings.background = work => pending.push(work);
  const res = await handleApi(new Request(`https://x/functions/v1/api/groups/${gid}/cancel`, { method: 'POST',
    headers: { Authorization: `Bearer ${session}` } }), live.settings);
  assert.equal(res.status, 200);
  assert.equal(pending.length, 1, 'delivery scheduled after the response');
  await Promise.all(pending);
  assert.equal(live.calls.claimed, 1);
});

// Store notifications go through the store's own OA when its token is set; players' notifications never do.
function twoOas({ adminStatus = 200, playerStatus = 200, adminToken = 'admin-token', friendStatus = 'active' } = {}) {
  const pushes = [], complete = [];
  const batch = [
    { id: 's1', line_user_id: 'Uadmin', friend_status: friendStatus, retry_key: 'k1', payload: { ...facts, kind: 'group_full' } },
    { id: 's2', line_user_id: 'Uadmin', friend_status: friendStatus, retry_key: 'k2', payload: { kind: 'binding_requested', record_name: '阿明', display_name: '明' } },
    { id: 'p1', line_user_id: 'Uplayer', friend_status: 'active', retry_key: 'k3', payload: { ...facts, kind: 'group_confirmed' } },
  ];
  let claimed = 0;
  const fetcher = async (url, opts = {}) => {
    if (url === 'https://api.line.me/v2/bot/message/push') {
      const token = opts.headers.Authorization.slice(7);
      pushes.push({ to: JSON.parse(opts.body).to, token, key: opts.headers['X-Line-Retry-Key'] });
      return new Response('{}', { status: token === 'admin-token' ? adminStatus : playerStatus });
    }
    const name = url.split('/rpc/')[1], args = JSON.parse(opts.body);
    if (name === 'claim_notifications') return Response.json(claimed++ ? [] : batch);
    if (name === 'complete_notification') { complete.push([args.p_id, args.p_result, args.p_error]); return Response.json({ ok: true }); }
    return Response.json({});
  };
  return { pushes, complete, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
    lineAccessToken: 'player-token', adminLineAccessToken: adminToken, fetcher } };
}

test('store notifications use the store OA; player notifications stay on the players OA', async () => {
  const run = twoOas();
  assert.deepEqual(await deliverNotifications(run.settings), { sent: 3, skipped: 0, failed: 0 });
  assert.deepEqual(run.pushes.map(p => [p.to, p.token]),
    [['Uadmin', 'admin-token'], ['Uadmin', 'admin-token'], ['Uplayer', 'player-token']]);
  assert.deepEqual(run.complete.map(c => c[2]), [null, null, null]);

  const single = twoOas({ adminToken: null });
  await deliverNotifications(single.settings);
  assert.ok(single.pushes.every(p => p.token === 'player-token'), 'without a store OA everything goes through the players OA');
});

test('a store OA that cannot reach the admin falls back to the players OA instead of dropping the message', async () => {
  // Not a friend / another provider (400 403 404), a revoked token (401), the monthly quota used up (429).
  for (const status of [400, 401, 403, 404, 429]) {
    const run = twoOas({ adminStatus: status });
    assert.deepEqual(await deliverNotifications(run.settings), { sent: 3, skipped: 0, failed: 0 }, `HTTP ${status}`);
    assert.deepEqual(run.pushes.slice(0, 2).map(p => [p.token, p.key]), [['admin-token', 'k1'], ['player-token', 'k1']]);
    assert.deepEqual(run.complete.slice(0, 2).map(c => c.slice(1)),
      [['sent', `VIA_PLAYER_OA_${status}`], ['sent', `VIA_PLAYER_OA_${status}`]]);
  }
  // A temporary LINE failure is retried later, not rerouted.
  const busy = twoOas({ adminStatus: 503 });
  await deliverNotifications(busy.settings);
  assert.deepEqual(busy.complete[0], ['s1', 'failed', 'HTTP_503']);
  assert.equal(busy.pushes.filter(p => p.key === 'k1').length, 1);
  // An admin who blocked the players OA still hears from the store OA, with no fallback to the blocked one.
  const blocked = twoOas({ friendStatus: 'blocked', adminStatus: 404 });
  await deliverNotifications(blocked.settings);
  assert.deepEqual(blocked.pushes.filter(p => p.to === 'Uadmin').map(p => p.token), ['admin-token', 'admin-token']);
  assert.deepEqual(blocked.complete[0], ['s1', 'skipped', 'HTTP_404']);
});

test('line-health tells the admin which OA can reach them', async () => {
  const session = 'S'.repeat(43);
  const probe = (adminProfile, playerProfile = 200, token = 'admin-token') => handleApi(new Request('https://x/functions/v1/api/admin/line-health',
    { headers: { Authorization: `Bearer ${session}` } }), { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k',
    allowedOrigins: [], lineAccessToken: 'player-token', adminLineAccessToken: token,
    fetcher: async (url, opts = {}) => {
      if (url.startsWith('https://api.line.me/v2/bot/profile/')) {
        assert.ok(url.endsWith('/Uadmin'));
        return new Response('{}', { status: opts.headers.Authorization === 'Bearer admin-token' ? adminProfile : playerProfile });
      }
      const name = url.split('/rpc/')[1];
      if (name === 'resolve_session') return Response.json({ user_id: 'u', display_name: 'x', is_admin: true, expires_at: 'x' });
      if (name === 'user_line_identity') return Response.json({ line_user_id: 'Uadmin', oa_friend_status: 'active' });
      return Response.json(null);
    } }).then(r => r.json());
  assert.deepEqual(await probe(200), { playerOa: 'ok', adminOa: 'ok' });
  assert.deepEqual(await probe(404), { playerOa: 'ok', adminOa: 'unreachable' });
  assert.deepEqual(await probe(401, 404), { playerOa: 'unreachable', adminOa: 'bad_token' });
  assert.deepEqual(await probe(200, 200, null), { playerOa: 'ok', adminOa: 'not_configured' });
});
