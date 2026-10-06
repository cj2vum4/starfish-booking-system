import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi } from '../supabase/functions/api/index.ts';

const base = 'https://example.invalid/functions/v1/api';
const SCRIPT = 'https://script.example/exec';
const NOW = 3_000_000_000_000;
const payload = { ok: true, updatedAt: '2026-10-06T09:00:00.000Z', monthKey: '2026/10', doubleDayNote: '',
  summary: [{ name: '阿明', agent: '#007', earned: 120, redeemed: 20, balance: 100, plays: 9, last: '2026/9/20' }],
  rewards: [], mystery: [], interactions: [], quests: [], rules: [] };

function backend(saved) {
  const later = [], calls = [];
  const state = { saved };
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1', allowedOrigins: [],
    playRecordUrl: SCRIPT, playRecordSecret: 'test-secret', now: () => NOW, background: w => later.push(w),
    fetcher: async (url, opts = {}) => {
      if (url === `${SCRIPT}?action=summary`) { calls.push('script'); return Response.json({ ...payload, updatedAt: 'fresh' }); }
      const name = url.split('/rpc/')[1];
      if (name === 'get_record_snapshot') return Response.json(state.saved ?? null);
      if (name === 'put_record_snapshot') {
        state.saved = { payload: JSON.parse(opts.body).p_payload, fetched_at: new Date(NOW).toISOString() };
        calls.push('put');
        return Response.json({ ok: true });
      }
      return Response.json(null);
    } };
  return { settings, later, calls, state };
}
const get = () => new Request(`${base}/public/records`, { headers: { Origin: 'https://someone.example' } });

test('the website reads a fresh copy without waiting on the Apps Script; any origin, short public cache', async () => {
  const b = backend({ payload, fetched_at: new Date(NOW - 60_000).toISOString() });
  const res = await handleApi(get(), b.settings);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.match(res.headers.get('cache-control'), /max-age=30/);
  assert.deepEqual(await res.json(), payload);
  assert.equal(b.later.length, 0);
  assert.deepEqual(b.calls, []);
});

test('an old copy is still answered at once, then refreshed after the response with the whole payload', async () => {
  const b = backend({ payload, fetched_at: new Date(NOW - 10 * 60_000).toISOString() });
  const res = await handleApi(get(), b.settings);
  assert.equal((await res.json()).updatedAt, payload.updatedAt);
  assert.deepEqual(b.calls, []);
  await Promise.all(b.later);
  assert.deepEqual(b.calls, ['script', 'put']);
  assert.equal(b.state.saved.payload.updatedAt, 'fresh');
  assert.ok(Array.isArray(b.state.saved.payload.quests), 'quests and rules are kept for the website');
});

test('with no usable copy (none, or an old summary-only copy) the script is read before answering', async () => {
  for (const saved of [null, { payload: { summary: [], rewards: [] }, fetched_at: new Date(NOW).toISOString() }]) {
    const b = backend(saved);
    const res = await handleApi(get(), b.settings);
    assert.equal(res.status, 200);
    assert.equal((await res.json()).updatedAt, 'fresh');
  }
});

test('the Apps Script ping needs the shared secret and refreshes the copy', async () => {
  const ping = secret => new Request(`${base}/hooks/records-changed`, { method: 'POST',
    headers: secret ? { 'X-Play-Record-Secret': secret } : {} });
  const b = backend({ payload, fetched_at: new Date(NOW).toISOString() });
  assert.equal((await handleApi(ping(), b.settings)).status, 401);
  assert.equal((await handleApi(ping('wrong'), b.settings)).status, 401);
  assert.deepEqual(b.calls, []);
  assert.equal((await handleApi(ping('test-secret'), b.settings)).status, 202);
  await Promise.all(b.later);
  assert.deepEqual(b.calls, ['script', 'put']);
});
