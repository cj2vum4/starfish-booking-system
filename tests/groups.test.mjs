import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, sha256Hex } from '../supabase/functions/api/index.ts';

const base = 'https://example.invalid/functions/v1/api';
const session = 'S'.repeat(43);
const groupId = '22222222-2222-4222-8222-222222222222';
const seatId = '33333333-3333-4333-8333-333333333333';

function backend(rpcFailure) {
  const calls = [];
  const fetcher = async (url, opts) => {
    const name = url.split('/rpc/')[1];
    const args = JSON.parse(opts.body);
    calls.push({ url, name, args, body: opts.body });
    if (name === 'resolve_session') {
      return Response.json(args.p_session_hash === await sha256Hex(session)
        ? { user_id: 'user-1', display_name: 'QA', is_admin: false, expires_at: '2026-10-03T00:00:00Z' } : null);
    }
    if (rpcFailure?.[name]) return Response.json({ code: 'P0001', message: rpcFailure[name] }, { status: 400 });
    if (name === 'get_group') return Response.json({ group_id: groupId, is_organizer: true, starts_at: 'x',
      seats: [{ seat_id: seatId, seat_number: 1, is_me: true }] });
    if (name === 'reserve_group_seat') return Response.json({ seat_number: 2 });
    return Response.json({ ok: true });
  };
  return { calls, settings: { loginChannelId: '2000000000', supabaseUrl: 'https://db.invalid', serviceKey: 'k',
    allowedOrigins: [], now: () => Date.parse('2026-10-02T04:00:00Z'), fetcher } };
}
const req = (path, method = 'GET', body) => new Request(`${base}${path}`, { method,
  headers: { Authorization: `Bearer ${session}`, 'Content-Type': 'application/json' },
  body: body ? JSON.stringify(body) : undefined });
const last = calls => calls[calls.length - 1];

test('group detail is camelCased and scoped to the session user', async () => {
  const { calls, settings } = backend();
  const response = await handleApi(req(`/groups/${groupId}`), settings);
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(data.isOrganizer, true);
  assert.deepEqual(data.seats[0], { seatId, seatNumber: 1, isMe: true });
  assert.deepEqual(last(calls).args, { p_actor: 'user-1', p_group_id: groupId });
});

test('share links and seat reservations return a fresh token; only its hash reaches the database', async () => {
  for (const [action, body] of [['share-link'], ['reserve', { displayName: '涵涵' }]]) {
    const { calls, settings } = backend();
    const response = await handleApi(req(`/groups/${groupId}/${action}`, 'POST', body), settings);
    assert.equal(response.status, 201);
    const { token } = await response.json();
    assert.match(token, /^[A-Za-z0-9_-]{43}$/);
    const call = last(calls);
    assert.equal(call.args.p_token_hash, await sha256Hex(token));
    assert.ok(!call.body.includes(token), 'raw token sent to database');
    assert.equal(call.args.p_actor, 'user-1');
    assert.equal(call.args.p_expires_at, '2026-10-09T04:00:00.000Z');
  }
});

test('invites are previewed and claimed by POST body token, hashed before use', async () => {
  const token = 'T'.repeat(43);
  for (const path of ['/invites/preview', '/invites/claim']) {
    const { calls, settings } = backend();
    const response = await handleApi(req(path, 'POST', { token }), settings);
    assert.equal(response.status, 200);
    assert.equal(last(calls).args.p_token_hash, await sha256Hex(token));
    assert.ok(!calls.some(c => c.url.includes(token)));
  }
  const { settings } = backend();
  assert.equal((await handleApi(req('/invites/claim', 'POST', { token: 'short' }), settings)).status, 400);
});

test('business errors map to friendly HTTP codes for the LIFF page', async () => {
  const cases = [['join_group', 'GROUP_FULL', 409], ['claim_invite', 'INVITE_USED', 409],
    ['get_group', 'GROUP_NOT_FOUND', 404], ['leave_group_seat', 'ORGANIZER_CANNOT_LEAVE', 409]];
  for (const [name, code, status] of cases) {
    const { settings } = backend({ [name]: code });
    const path = { join_group: `/groups/${groupId}/join`, claim_invite: '/invites/claim',
      get_group: `/groups/${groupId}`, leave_group_seat: `/seats/${seatId}/leave` }[name];
    const response = await handleApi(req(path, name === 'get_group' ? 'GET' : 'POST',
      name === 'claim_invite' ? { token: 'T'.repeat(43) } : undefined), settings);
    assert.equal(response.status, status, name);
    assert.deepEqual(await response.json(), { error: code });
  }
});

test('routes require a session and reject malformed ids', async () => {
  const { calls, settings } = backend();
  const anonymous = await handleApi(new Request(`${base}/groups/${groupId}`), settings);
  assert.equal(anonymous.status, 401);
  assert.equal((await handleApi(req('/groups/not-a-uuid'), settings)).status, 404);
  assert.equal((await handleApi(req(`/groups/${groupId}/delete`, 'POST'), settings)).status, 404);
  assert.ok(!calls.some(c => c.name === 'get_group'));
});
