import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, richMenuDefinition } from '../supabase/functions/api/index.ts';

test('rich menu: three full-height areas covering 2500px exactly, each opening the LIFF app', () => {
  const menu = richMenuDefinition('LIFF-ID');
  assert.deepEqual(menu.size, { width: 2500, height: 843 });
  assert.equal(menu.areas.reduce((w, a) => w + a.bounds.width, 0), 2500);
  assert.deepEqual(menu.areas.map(a => a.bounds.x), [0, 833, 1667]);
  assert.deepEqual(menu.areas.map(a => a.action.uri), ['https://liff.line.me/LIFF-ID?view=create',
    'https://liff.line.me/LIFF-ID?view=open', 'https://liff.line.me/LIFF-ID']);
});

test('setup is secret-protected, uploads the image, sets it as default and removes older copies', async () => {
  const run = async (secretHeader, existing = []) => {
    const calls = [];
    const fetcher = async (url, opts = {}) => {
      calls.push({ url, method: opts.method ?? 'GET', type: opts.headers?.['Content-Type'] });
      if (url === 'https://img.example/menu.jpg') return new Response(new Uint8Array(1000), { headers: { 'content-type': 'image/jpeg' } });
      if (url.endsWith('/richmenu/list')) return Response.json({ richmenus: existing });
      if (url === 'https://api.line.me/v2/bot/richmenu') return Response.json({ richMenuId: 'new-id' });
      return new Response('{}', { headers: { 'content-type': 'application/json' } });
    };
    const settings = { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
      catalogSyncSecret: 'maint-secret', lineAccessToken: 'line-token', richMenuImageUrl: 'https://img.example/menu.jpg', fetcher };
    const res = await handleApi(new Request('https://x/functions/v1/api/hooks/richmenu-setup', { method: 'POST',
      headers: secretHeader ? { 'X-Sync-Secret': secretHeader } : {} }), settings);
    return { status: res.status, data: await res.json(), calls };
  };
  const denied = await run('wrong');
  assert.equal(denied.status, 401);
  assert.equal(denied.calls.length, 0);
  const ok = await run('maint-secret', [{ richMenuId: 'old-1', name: '海星預約選單' }, { richMenuId: 'other', name: '別人的選單' }]);
  assert.deepEqual([ok.status, ok.data], [200, { richMenuId: 'new-id', replaced: 1 }]);
  const steps = ok.calls.filter(c => !c.url.includes('/rest/v1/rpc/')).map(c => `${c.method} ${c.url.replace(/^https:\/\/api(-data)?\.line\.me\/v2\/bot/, '')}`);
  assert.deepEqual(steps.slice(1), ['GET /richmenu/list', 'POST /richmenu', 'POST /richmenu/new-id/content',
    'POST /user/all/richmenu/new-id', 'DELETE /richmenu/old-1']);
  assert.equal(ok.calls.find(c => c.url.endsWith('/content')).type, 'image/jpeg');
});

test('race self-test: secret, guard against real data, and parallel attempts tallied', async () => {
  const users = Array.from({ length: 5 }, (_, i) => `aaaaaaaa-aaaa-4aaa-8aaa-00000000000${i}`);
  const run = async ({ secret = 'maint-secret', allowed = true, body } = {}) => {
    const calls = []; let inFlight = 0, maxInFlight = 0, winners = 0;
    const fetcher = async (url, opts = {}) => {
      const name = url.split('/rpc/')[1];
      calls.push(name);
      if (name === 'selftest_targets_ok') return Response.json(allowed);
      inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise(r => setTimeout(r, 20));
      inFlight--;
      return winners++ === 0 ? Response.json({ booking_id: 'b' })
        : Response.json({ code: 'P0001', message: 'SOLD_OUT' }, { status: 400 });
    };
    const settings = { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
      catalogSyncSecret: 'maint-secret', fetcher };
    const res = await handleApi(new Request('https://x/functions/v1/api/hooks/selftest-race', { method: 'POST',
      headers: { 'X-Sync-Secret': secret, 'Content-Type': 'application/json' },
      body: JSON.stringify(body ?? { mode: 'booking', gameId: users[0], eventId: users[1], userIds: users }) }), settings);
    return { status: res.status, data: await res.json(), calls, maxInFlight };
  };
  const ok = await run();
  assert.deepEqual(ok.data, { mode: 'booking', attempts: 5, succeeded: 1, errors: { SOLD_OUT: 4 } });
  assert.equal(ok.maxInFlight, 5, 'requests really run at the same time');
  assert.equal((await run({ secret: 'nope' })).status, 401);
  const refused = await run({ allowed: false });
  assert.equal(refused.status, 403);
  assert.deepEqual(refused.calls, ['selftest_targets_ok'], 'nothing attempted on non-test targets');
  assert.equal((await run({ body: { mode: 'booking', gameId: users[0], userIds: users } })).status, 400);
});
