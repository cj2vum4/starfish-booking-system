import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, statusForCode } from '../supabase/functions/api/index.ts';

const base = 'https://example.invalid/functions/v1/api';
const lineUser = 'U' + 'c'.repeat(32);
const groupId = '11111111-1111-4111-8111-111111111111';

// Fake PostgREST + LINE profile API. `profile` is the LINE answer for the stored userId.
function backend({ status = 'unknown', profile = 404, token = 'line-token' } = {}) {
  const calls = [];
  const fetcher = async (url, opts = {}) => {
    calls.push(url);
    if (url.startsWith('https://api.line.me/v2/bot/profile/')) {
      if (profile === 'down') throw new TypeError('network');
      assert.equal(opts.headers.Authorization, 'Bearer line-token');
      return new Response('{}', { status: profile });
    }
    if (url.startsWith('https://api.line.me/')) return new Response('{}', { status: 200 });
    const name = url.split('/rpc/')[1];
    if (name === 'resolve_session') return Response.json({ user_id: 'user-1', display_name: 'QA', is_admin: false });
    if (name === 'user_line_identity') return Response.json({ line_user_id: lineUser, oa_friend_status: status });
    if (name === 'mark_user_followed') { status = 'active'; return Response.json({ ok: true }); }
    if (name === 'join_group') return Response.json({ group_id: groupId, seat_number: 2 });
    if (name === 'claim_invite') return Response.json({ group_id: groupId });
    if (name === 'preview_invite') return Response.json({ group_id: groupId });
    if (name === 'claim_notifications') return Response.json([]);
    return new Response('{}', { status: 404 });
  };
  return { calls, settings: { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1',
    lineAccessToken: token || undefined, fetcher, background: () => {} } };
}
const post = (path, body = {}) => new Request(`${base}${path}`, { method: 'POST',
  headers: { Authorization: 'Bearer ' + 'S'.repeat(43), 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const isRpc = (calls, name) => calls.some(u => u.endsWith(`/rpc/${name}`));

test('non-friends cannot join, claim or open a group; LINE is asked live', async () => {
  for (const [path, body, rpcName] of [[`/groups/${groupId}/join`, {}, 'join_group'],
    ['/invites/claim', { token: 'a'.repeat(43) }, 'claim_invite'],
    ['/groups', { requestId: crypto.randomUUID(), startsAt: '2026-10-10T11:00:00Z', capacity: 4 }, 'create_group']]) {
    const { calls, settings } = backend();
    const response = await handleApi(post(path, body), settings);
    assert.equal(response.status, 403, path);
    assert.equal((await response.json()).error, 'NOT_FRIEND');
    assert.ok(calls.some(u => u === `https://api.line.me/v2/bot/profile/${lineUser}`), 'LINE not asked');
    assert.ok(!isRpc(calls, rpcName), `${rpcName} ran for a non-friend`);
  }
  assert.equal(statusForCode('NOT_FRIEND'), 403);
});

test('a friend LINE confirms is recorded and allowed; recorded friends skip the LINE call', async () => {
  const healed = backend({ profile: 200 });
  assert.equal((await handleApi(post(`/groups/${groupId}/join`), healed.settings)).status, 200);
  assert.ok(isRpc(healed.calls, 'mark_user_followed') && isRpc(healed.calls, 'join_group'));

  const known = backend({ status: 'active' });
  assert.equal((await handleApi(post(`/groups/${groupId}/join`), known.settings)).status, 200);
  assert.ok(!known.calls.some(u => u.includes('/v2/bot/profile/')));
  assert.ok(!isRpc(known.calls, 'mark_user_followed'));
});

test('blocked status is re-checked; LINE outage or missing token does not lock players out', async () => {
  const unblocked = backend({ status: 'blocked', profile: 200 });
  assert.equal((await handleApi(post('/invites/claim', { token: 'a'.repeat(43) }), unblocked.settings)).status, 200);
  for (const opts of [{ profile: 'down' }, { profile: 500 }, { token: '' }]) {
    const { calls, settings } = backend(opts);
    assert.equal((await handleApi(post(`/groups/${groupId}/join`), settings)).status, 200, JSON.stringify(opts));
    assert.ok(!isRpc(calls, 'mark_user_followed'));
  }
});

test('browsing an invite does not require friendship', async () => {
  const { calls, settings } = backend();
  assert.equal((await handleApi(post('/invites/preview', { token: 'a'.repeat(43) }), settings)).status, 200);
  assert.ok(!calls.some(u => u.includes('/v2/bot/profile/')));
});
