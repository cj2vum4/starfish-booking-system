import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, parseStarfishCatalog, sha256Hex } from '../supabase/functions/api/index.ts';

// Shape of cj2vum4/starfishlarp scripts.js (trimmed to three entries).
const source = `/* 劇本資料 */
window.SCRIPTS = [
  {"id":"wangzuo","name":"王座","file":"7人/王座.html","players":7,"playersLabel":"4男3女","time":4.5,"difficulty":2,"types":["神話","陣營"],"poster":"https://i.postimg.cc/x.jpg"},
  {"id":"gaoqian","name":"搞錢","file":"8人以上/搞錢.html","players":10,"playersLabel":"7-10人（可反串）","time":5,"difficulty":1,"types":["歡樂"],"poster":"http://insecure.example/x.jpg"},
  {"id":"wuhuang","name":"吾皇在上","file":"8人以上/吾皇在上.html","players":8,"playersLabel":"8-9人","time":6,"difficulty":0,"types":[]}
];

(function syncInitialScriptCount() { document.getElementById('filteredCount'); })();`;

test('catalog is parsed as data: ranges, durations, https-only images, page links', () => {
  const games = parseStarfishCatalog(source, 'https://site.example/');
  assert.equal(games.length, 3);
  assert.deepEqual(games[0], { slug: 'wangzuo', title: '王座', review_key: '王座', min_players: 7, max_players: 7, duration_minutes: 270,
    genres: ['神話', '陣營'], difficulty: '2', players_label: '4男3女', image_url: 'https://i.postimg.cc/x.jpg',
    source_url: 'https://site.example/7%E4%BA%BA/%E7%8E%8B%E5%BA%A7.html' });
  assert.deepEqual([games[1].min_players, games[1].max_players, games[1].image_url], [7, 10, null]);
  assert.deepEqual([games[2].min_players, games[2].max_players, games[2].duration_minutes], [8, 9, 360]);
});

test('anything that is not the expected JSON array is refused, never executed', () => {
  globalThis.__pwned = false;
  for (const bad of ['', 'window.SCRIPTS = (globalThis.__pwned = true, []);', 'window.SCRIPTS = [\n{id: 1}\n];',
    'window.SCRIPTS = [\n];']) {
    assert.throws(() => parseStarfishCatalog(bad), /CATALOG_UNREADABLE/);
  }
  assert.equal(globalThis.__pwned, false);
});

test('sync is admin-only and sends the parsed catalog to the database', async () => {
  const session = 'S'.repeat(43);
  const run = async isAdmin => {
    const calls = [];
    const fetcher = async (url, opts = {}) => {
      calls.push({ url, body: opts.body });
      if (url === 'https://catalog.example/scripts.js') return new Response(source);
      const name = url.split('/rpc/')[1];
      if (name === 'resolve_session') return Response.json(JSON.parse(opts.body).p_session_hash === await sha256Hex(session)
        ? { user_id: 'owner', display_name: 'Owner', is_admin: isAdmin, expires_at: 'x' } : null);
      return Response.json({ synced: 3, deactivated: 0 });
    };
    const settings = { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
      catalogUrl: 'https://catalog.example/scripts.js', fetcher };
    const response = await handleApi(new Request('https://x/functions/v1/api/admin/games/sync',
      { method: 'POST', headers: { Authorization: `Bearer ${session}` } }), settings);
    return { response, calls };
  };
  const denied = await run(false);
  assert.equal(denied.response.status, 403);
  assert.ok(!denied.calls.some(c => c.url.includes('catalog.example')));
  const ok = await run(true);
  assert.equal(ok.response.status, 200);
  assert.deepEqual(await ok.response.json(), { synced: 3, deactivated: 0 });
  const sync = JSON.parse(ok.calls.find(c => c.url.endsWith('/admin_sync_games')).body);
  assert.equal(sync.p_actor, 'owner');
  assert.equal(sync.p_games.length, 3);
});

test('GitHub hook syncs the pushed commit only with the shared secret', async () => {
  const commit = 'c'.repeat(40);
  const run = async (headers, body, secret = 'shared-secret-for-tests') => {
    const calls = [];
    const fetcher = async (url, opts = {}) => {
      calls.push({ url, body: opts.body });
      if (url.startsWith('https://raw.example/')) return new Response(source);
      return Response.json({ synced: 3, deactivated: 0 });
    };
    const settings = { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
      catalogCommitUrl: 'https://raw.example/{commit}/scripts.js', catalogSyncSecret: secret, fetcher };
    const response = await handleApi(new Request('https://x/functions/v1/api/hooks/catalog-sync', { method: 'POST',
      headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) }), settings);
    return { status: response.status, data: await response.json(), calls };
  };
  const ok = await run({ 'X-Sync-Secret': 'shared-secret-for-tests' }, { commit });
  assert.equal(ok.status, 200);
  assert.equal(ok.calls[0].url, `https://raw.example/${commit}/scripts.js`);
  const rpcCall = JSON.parse(ok.calls.find(c => c.url.endsWith('/system_sync_games')).body);
  assert.equal(rpcCall.p_commit, commit);
  assert.equal(rpcCall.p_games.length, 3);
  for (const headers of [{}, { 'X-Sync-Secret': 'wrong' }, { 'X-Sync-Secret': 'shared-secret-for-test' }]) {
    const denied = await run(headers, { commit });
    assert.equal(denied.status, 401);
    assert.equal(denied.calls.length, 0, 'nothing fetched without the secret');
  }
  assert.equal((await run({ 'X-Sync-Secret': 'shared-secret-for-tests' }, { commit: 'main' })).status, 400);
  assert.equal((await run({ 'X-Sync-Secret': 'x' }, { commit }, '')).status, 503);
});
