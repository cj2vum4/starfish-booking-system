import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, richMenuDefinition } from '../supabase/functions/api/index.ts';

test('rich menus: six cells tiling 2500x1686 exactly; new and member menus open the agreed pages', () => {
  const site = 'https://cj2vum4.github.io/starfishlarp/';
  const liff = 'https://liff.line.me/LIFF-ID';
  for (const kind of ['new', 'member']) {
    const menu = richMenuDefinition(kind, 'LIFF-ID');
    assert.deepEqual(menu.size, { width: 2500, height: 1686 });
    assert.equal(menu.areas.length, 6);
    assert.equal(menu.areas.reduce((a, x) => a + x.bounds.width * x.bounds.height, 0), 2500 * 1686, 'cells cover the image');
    for (const a of menu.areas) for (const b of menu.areas) if (a !== b) {
      const overlap = a.bounds.x < b.bounds.x + b.bounds.width && b.bounds.x < a.bounds.x + a.bounds.width
        && a.bounds.y < b.bounds.y + b.bounds.height && b.bounds.y < a.bounds.y + a.bounds.height;
      assert.ok(!overlap, 'cells overlap');
    }
  }
  assert.deepEqual(richMenuDefinition('new', 'LIFF-ID').areas.map(a => a.action.uri), [
    site + encodeURIComponent('主持人資訊.html'), site, liff, liff + '?view=open', liff + '?view=guide', liff + '?view=veteran']);
  assert.deepEqual(richMenuDefinition('member', 'LIFF-ID').areas.map(a => a.action.uri), [
    liff, liff + '?view=open', site + encodeURIComponent('新增玩本記錄.html'), liff + '?view=card', site, site + encodeURIComponent('榮譽牆.html')]);
});

function lineFake(existing = [], members = []) {
  const calls = [];
  const fetcher = async (url, opts = {}) => {
    calls.push({ url, method: opts.method ?? 'GET', type: opts.headers?.['Content-Type'], body: opts.body });
    if (url.startsWith('https://img.example/')) return new Response(new Uint8Array(1000), { headers: { 'content-type': 'image/jpeg' } });
    if (url.endsWith('/rpc/member_menu_line_ids')) return Response.json(members);
    if (url.endsWith('/rpc/resolve_session')) return Response.json({ user_id: 'adm', display_name: '店長', is_admin: true });
    if (url.endsWith('/rpc/admin_complete_event')) return Response.json({ completed: true });
    if (url.endsWith('/rpc/claim_notifications')) return Response.json([]);
    if (url.endsWith('/richmenu/list')) return Response.json({ richmenus: existing });
    if (url === 'https://api.line.me/v2/bot/richmenu') {
      return Response.json({ richMenuId: JSON.parse(opts.body).name.endsWith('新玩家') ? 'new-id' : 'member-id' });
    }
    return new Response('{}', { headers: { 'content-type': 'application/json' } });
  };
  return { calls, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
    catalogSyncSecret: 'maint-secret', lineAccessToken: 'line-token', fetcher,
    richMenuImageUrls: { new: 'https://img.example/new.jpg', member: 'https://img.example/member.jpg' } } };
}
const lineSteps = calls => calls.filter(c => c.url.includes('line.me'))
  .map(c => `${c.method} ${c.url.replace(/^https:\/\/api(-data)?\.line\.me\/v2\/bot/, '')}`);

test('setup is secret-protected, creates both menus, defaults to the new-player one, links members, removes old copies', async () => {
  const run = async (secretHeader, existing, members) => {
    const { calls, settings } = lineFake(existing, members);
    const res = await handleApi(new Request('https://x/functions/v1/api/hooks/richmenu-setup', { method: 'POST',
      headers: secretHeader ? { 'X-Sync-Secret': secretHeader } : {} }), settings);
    return { status: res.status, data: await res.json(), calls };
  };
  const denied = await run('wrong');
  assert.equal(denied.status, 401);
  assert.equal(denied.calls.length, 0);
  const members = Array.from({ length: 501 }, (_, i) => 'U' + String(i).padStart(32, '0'));
  const ok = await run('maint-secret', [{ richMenuId: 'old-1', name: '海星預約選單' }, { richMenuId: 'old-2', name: '海星選單・老玩家' },
    { richMenuId: 'other', name: '別人的選單' }], members);
  assert.deepEqual([ok.status, ok.data], [200, { newMenuId: 'new-id', memberMenuId: 'member-id', membersLinked: 501, replaced: 2 }]);
  assert.deepEqual(lineSteps(ok.calls), ['GET /richmenu/list', 'POST /richmenu', 'POST /richmenu/new-id/content',
    'POST /richmenu', 'POST /richmenu/member-id/content', 'POST /user/all/richmenu/new-id',
    'POST /richmenu/bulk/link', 'POST /richmenu/bulk/link', 'DELETE /richmenu/old-1', 'DELETE /richmenu/old-2']);
  const links = ok.calls.filter(c => c.url.endsWith('/bulk/link')).map(c => JSON.parse(c.body));
  assert.deepEqual(links.map(l => [l.richMenuId, l.userIds.length]), [['member-id', 500], ['member-id', 1]]);
  assert.ok(ok.calls.filter(c => c.url.endsWith('/content')).every(c => c.type === 'image/jpeg'));
});

test('recording attendance moves players to the member menu', async () => {
  const { calls, settings } = lineFake([{ richMenuId: 'member-id', name: '海星選單・老玩家' }], ['U' + 'a'.repeat(32)]);
  const res = await handleApi(new Request('https://x/functions/v1/api/admin/events/11111111-1111-4111-8111-111111111111/complete', {
    method: 'POST', headers: { Authorization: 'Bearer ' + 'S'.repeat(43), 'Content-Type': 'application/json' },
    body: JSON.stringify({ absent: [] }) }), settings);
  assert.equal(res.status, 200);
  const link = calls.find(c => c.url.endsWith('/bulk/link'));
  assert.deepEqual(JSON.parse(link.body), { richMenuId: 'member-id', userIds: ['U' + 'a'.repeat(32)] });
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
