import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, runScheduledWork, sha256Hex } from '../supabase/functions/api/index.ts';

const base = 'https://example.invalid/functions/v1/api';
const gid = '77777777-7777-4777-8777-777777777777';
const TOKEN = 'ab'.repeat(32);
const payload = { kind: 'group_confirmed', group_id: gid, starts_at: '2026-10-10T05:00:00+00:00', ends_at: '2026-10-10T09:00:00+00:00',
  game_title: '王座', venue: '南港', dm_name: '海星', price_cents: 40000 };
const item = i => ({ id: `n${i}`, line_user_id: `U${i}`, friend_status: 'active', retry_key: `k${i}`, payload });

// Fake PostgREST + LINE. `queue` is how many notifications are waiting; `tokens` are the hashes the database issued.
function backend({ queue = 0, tokens = [], pushStatus = 200, clockStep = 0, background } = {}) {
  const calls = { rpc: [], push: 0, consumed: [] };
  let waiting = queue, now = 1_000;
  const live = new Set(tokens);
  const fetcher = async (url, opts = {}) => {
    if (url === 'https://api.line.me/v2/bot/message/push') { calls.push++; now += clockStep; return new Response('{}', { status: pushStatus }); }
    const name = url.split('/rpc/')[1], args = opts.body ? JSON.parse(opts.body) : {};
    calls.rpc.push(name);
    switch (name) {
      case 'consume_tick_token': calls.consumed.push(args.p_token_hash); return Response.json(live.delete(args.p_token_hash));
      case 'expire_stale_groups': return Response.json(1);
      case 'claim_notifications': {
        const n = Math.min(waiting, args.p_limit); waiting -= n;
        return Response.json(Array.from({ length: n }, (_, i) => item(i)));
      }
      case 'complete_notification': return Response.json({ ok: true });
      default: return new Response('{}', { status: 404 });
    }
  };
  return { calls, left: () => waiting, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k',
    allowedOrigins: [], lineAccessToken: 'line-token', fetcher, now: () => now, background } };
}
const tick = (settings, token) => handleApi(new Request(`${base}/hooks/tick`, { method: 'POST',
  headers: token === undefined ? {} : { 'X-Tick-Token': token } }), settings);

test('tick: only a token the database issued wakes it, and only once', async () => {
  const b = backend({ queue: 2, tokens: [await sha256Hex(TOKEN)] });
  for (const token of [undefined, '', 'not-hex', 'AB'.repeat(32), 'ab'.repeat(33)]) {
    const res = await tick(b.settings, token);
    assert.deepEqual([res.status, (await res.json()).error], [401, 'INVALID_TOKEN'], String(token));
  }
  assert.equal(b.calls.consumed.length, 0, 'malformed tokens never reach the database');
  const wrong = await tick(b.settings, 'cd'.repeat(32));
  assert.equal(wrong.status, 401);
  assert.equal(b.calls.push, 0, 'nothing is sent for a refused token');

  const ok = await tick(b.settings, TOKEN);
  assert.deepEqual([ok.status, await ok.json()], [202, { ok: true }]);
  assert.equal(b.calls.consumed.at(-1), await sha256Hex(TOKEN), 'only the hash is sent to the database');
  assert.equal(b.calls.push, 2, 'queued notifications went out');
  assert.ok(b.calls.rpc.includes('expire_stale_groups'), 'past groups are expired on schedule too');
  const again = await tick(b.settings, TOKEN);
  assert.equal(again.status, 401, 'a spent token is refused');
});

test('tick answers at once and does the work after the response', async () => {
  const later = [];
  const b = backend({ queue: 3, tokens: [await sha256Hex(TOKEN)], background: w => later.push(w) });
  const res = await tick(b.settings, TOKEN);
  assert.equal(res.status, 202);
  assert.equal(later.length, 1, 'work handed to the background');
  await Promise.all(later);
  assert.equal(b.calls.push, 3);
});

test('scheduled work drains the queue in batches of 20, at most 5 batches per tick', async () => {
  const small = backend({ queue: 45 });
  assert.deepEqual(await runScheduledWork(small.settings), { expired: 1, sent: 45, skipped: 0, failed: 0 });
  assert.equal(small.calls.rpc.filter(n => n === 'claim_notifications').length, 3, '20 + 20 + 5, then the queue is empty');

  const big = backend({ queue: 250 });
  assert.equal((await runScheduledWork(big.settings)).sent, 100);
  assert.equal(big.left(), 150, 'the rest waits for the next tick');
});

test('scheduled work stops starting new batches after 30 seconds', async () => {
  const slow = backend({ queue: 100, clockStep: 1_000 });  // each push takes a second
  const result = await runScheduledWork(slow.settings);
  assert.equal(result.sent, 40, 'the second batch ends past 30 s, so no third batch');
});

test('failed pushes are recorded for retry and do not stop the tick', async () => {
  const down = backend({ queue: 3, pushStatus: 503 });
  assert.deepEqual(await runScheduledWork(down.settings), { expired: 1, sent: 0, skipped: 0, failed: 3 });
});

test('a database outage during the tick is swallowed after the 202 (the next tick retries)', async () => {
  const b = backend({ tokens: [await sha256Hex(TOKEN)] });
  const fetcher = b.settings.fetcher;
  b.settings.fetcher = async (url, opts) => url.endsWith('/claim_notifications') ? new Response('oops', { status: 500 }) : fetcher(url, opts);
  const res = await tick(b.settings, TOKEN);
  assert.equal(res.status, 202);
});
