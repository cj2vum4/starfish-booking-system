import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, notificationText } from '../supabase/functions/api/index.ts';

const base = 'https://example.invalid/functions/v1/api';
const SCRIPT = 'https://script.example/exec';
const userId = '44444444-4444-4444-8444-444444444444';
const summary = [{ name: '阿明', agent: '#007', earned: 120, redeemed: 20, balance: 100, plays: 9, last: '2026/9/20', title: '' },
  { name: '小華', agent: '#012', earned: 30, redeemed: 0, balance: 30, plays: 2, last: '2026/8/1' }];
const rewards = [{ track: '保底', name: '折抵 50 元', cost: 50, note: '直接折抵當場費用', active: true }];

// Fake PostgREST + Apps Script + LINE. `script` decides the grant_bonus answer.
function backend({ admin = false, binding = null, account = null, script = { ok: true, granted: true }, scriptDown = false, now = 0 } = {}) {
  const calls = [];
  let current = binding;
  const fetcher = async (url, opts = {}) => {
    calls.push({ url, method: opts.method ?? 'GET', body: opts.body });
    if (url === `${SCRIPT}?action=summary`) return Response.json({ ok: true, summary, rewards });
    if (url === SCRIPT) {
      if (scriptDown) throw new TypeError('network');
      return Response.json(script);
    }
    if (url.includes('line.me')) {
      if (url.endsWith('/richmenu/list')) return Response.json({ richmenus: [{ richMenuId: 'member-id', name: '海星選單・老玩家' }] });
      return new Response('{}', { headers: { 'content-type': 'application/json' } });
    }
    const name = url.split('/rpc/')[1];
    const args = opts.body ? JSON.parse(opts.body) : {};
    switch (name) {
      case 'resolve_session': return Response.json({ user_id: userId, display_name: 'QA', is_admin: admin });
      case 'bound_record_names': return Response.json(['小華']);
      case 'my_binding': return Response.json(current);
      case 'my_record_account': return Response.json(account);
      case 'claim_record_name': return Response.json({ record_name: args.p_name.trim() });
      case 'request_binding':
        current = { user_id: userId, record_name: args.p_name.trim(), status: 'pending', bonus_status: 'none' };
        return Response.json(current);
      case 'admin_decide_binding':
        if (!admin) return Response.json({ code: 'P0001', message: 'NOT_ADMIN' }, { status: 400 });
        current = { ...current, status: args.p_approve ? 'approved' : 'rejected' };
        return Response.json(current);
      case 'admin_list_bindings': return Response.json(current ? [current] : []);
      case 'mark_binding_bonus':
        current = { ...current, bonus_status: args.p_status };
        return Response.json(current);
      case 'member_menu_line_ids': return Response.json(['U' + 'a'.repeat(32)]);
      case 'claim_notifications': return Response.json([]);
      default: return new Response('{}', { status: 404 });
    }
  };
  return { calls, settings: { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1', allowedOrigins: [],
    playRecordUrl: SCRIPT, playRecordSecret: 'bonus-secret', lineAccessToken: 'line-token', fetcher, now: () => now } };
}
const call = (settings, path, method = 'GET', body) => handleApi(new Request(`${base}${path}`, { method,
  headers: { Authorization: 'Bearer ' + 'S'.repeat(43), 'Content-Type': 'application/json' },
  body: body ? JSON.stringify(body) : undefined }), settings);
const scriptPosts = calls => calls.filter(c => c.url === SCRIPT && c.method === 'POST');

test('names come from the website summary; only names that exist there can be claimed', async () => {
  const { settings } = backend({ now: 1 });
  const res = await call(settings, '/records/names');
  const data = await res.json();
  assert.deepEqual(data.names[0], { name: '阿明', agent: '#007', plays: 9, last: '2026/9/20' });
  assert.ok(!('balance' in data.names[0]), 'balances are not listed for everyone');
  assert.deepEqual(data.bound, ['小華']);
  const unknown = await call(settings, '/me/binding', 'POST', { name: '不存在的人' });
  assert.deepEqual([unknown.status, (await unknown.json()).error], [404, 'NAME_NOT_FOUND']);
  const ok = await call(settings, '/me/binding', 'POST', { name: ' 阿明 ', note: '也用過明明' });
  assert.equal(ok.status, 201);
  assert.equal((await ok.json()).binding.status, 'pending');
});

test('only the store can approve; approval grants the bonus once and switches the menu', async () => {
  const pending = { user_id: userId, record_name: '阿明', status: 'pending', bonus_status: 'none' };
  const player = backend({ binding: pending, now: 2 });
  const denied = await call(player.settings, `/admin/bindings/${userId}/approve`, 'POST');
  assert.equal(denied.status, 403);
  assert.equal(scriptPosts(player.calls).length, 0);

  const store = backend({ admin: true, binding: pending, now: 3 });
  const res = await call(store.settings, `/admin/bindings/${userId}/approve`, 'POST');
  const data = await res.json();
  assert.equal(res.status, 200);
  assert.deepEqual([data.binding.status, data.binding.bonusStatus, data.bonusError], ['approved', 'granted', null]);
  const [post] = scriptPosts(store.calls);
  const form = new URLSearchParams(post.body);
  assert.deepEqual([form.get('action'), form.get('name'), form.get('points'), form.get('secret')],
    ['grant_bonus', '阿明', '50', 'bonus-secret']);
  assert.ok(store.calls.some(c => c.url.endsWith('/richmenu/bulk/link')), 'member menu linked');
  assert.ok(!JSON.stringify(data).includes('bonus-secret'), 'secret never returned');
});

test('bonus outcomes: ineligible and already are recorded; failures leave it to retry', async () => {
  const pending = { user_id: userId, record_name: '阿明', status: 'pending', bonus_status: 'none' };
  for (const [script, expected] of [[{ ok: true, granted: false, reason: 'INELIGIBLE' }, 'ineligible'],
    [{ ok: true, granted: false, reason: 'ALREADY' }, 'already']]) {
    const { settings } = backend({ admin: true, binding: pending, script, now: 4 });
    const data = await (await call(settings, `/admin/bindings/${userId}/approve`, 'POST')).json();
    assert.equal(data.binding.bonusStatus, expected);
  }
  const wrongSecret = backend({ admin: true, binding: pending, script: { ok: false, error: 'INVALID_SECRET' }, now: 5 });
  const data = await (await call(wrongSecret.settings, `/admin/bindings/${userId}/approve`, 'POST')).json();
  assert.deepEqual([data.binding.status, data.binding.bonusStatus, data.bonusError], ['approved', 'none', 'BONUS_SECRET_MISMATCH']);

  // The store can retry; so does the player's next visit to the member card.
  const retry = backend({ admin: true, binding: { ...pending, status: 'approved' }, now: 6 });
  assert.equal((await (await call(retry.settings, `/admin/bindings/${userId}/bonus`, 'POST')).json()).binding.bonusStatus, 'granted');
  const visit = backend({ binding: { ...pending, status: 'approved' }, scriptDown: true, now: 7 });
  const card = await (await call(visit.settings, '/me/binding')).json();
  assert.equal(card.binding.bonusStatus, 'none', 'Apps Script down: still shows the card, bonus retried later');
  assert.equal(card.card.balance, 100);
});

test('member card shows the bound name only, with rewards; unbound players get no card', async () => {
  const bound = backend({ binding: { user_id: userId, record_name: '阿明', status: 'approved', bonus_status: 'granted' }, now: 8 });
  const data = await (await call(bound.settings, '/me/binding')).json();
  const { updatedAt, stale, refreshing, ...card } = data.card;
  assert.deepEqual(card, { name: '阿明', agent: '#007', balance: 100, earned: 120, redeemed: 20, plays: 9, last: '2026/9/20', title: '' });
  assert.equal(stale, false);
  assert.equal(refreshing, false);
  assert.ok(updatedAt);
  assert.deepEqual(data.rewards, [{ track: '保底', name: '折抵 50 元', cost: 50, note: '直接折抵當場費用' }]);
  assert.equal(scriptPosts(bound.calls).length, 0, 'no grant call once granted');
  const pending = backend({ binding: { user_id: userId, record_name: '阿明', status: 'pending', bonus_status: 'none' }, now: 9 });
  assert.equal((await (await call(pending.settings, '/me/binding')).json()).card, null);
});

test('binding notifications link to the right pages', () => {
  assert.match(notificationText({ kind: 'binding_requested', display_name: '小明', record_name: '阿明' }, 'L'), /阿明[\s\S]*view=bindings/);
  assert.match(notificationText({ kind: 'binding_approved', record_name: '阿明' }, 'L'), /50 點[\s\S]*view=card/);
  assert.match(notificationText({ kind: 'binding_rejected', record_name: '阿明' }, 'L'), /view=veteran/);
});

test('new LINE record accounts get a card without a returning-player bonus', async () => {
  const { settings, calls } = backend({ account: '阿明', now: 101 });
  const data = await (await call(settings, '/me/binding')).json();
  assert.equal(data.binding, null);
  assert.equal(data.card.name, '阿明');
  assert.equal(data.card.balance, 100);
  assert.equal(scriptPosts(calls).length, 0);
});

test('records health check reports only a reason code', async () => {
  const ok = backend({ now: 20 });
  const res = await handleApi(new Request(`${base}/health/records`), ok.settings);
  assert.deepEqual(await res.json(), { ok: true, players: 2, rewards: 1 });
  const html = { ...ok.settings, fetcher: async () => new Response('<html>sign in</html>', { headers: { 'content-type': 'text/html' } }) };
  const bad = await handleApi(new Request(`${base}/health/records`), html);
  assert.deepEqual([bad.status, await bad.json()], [503, { ok: false, error: 'NOT_JSON:text/html' }]);
  const down = { ...ok.settings, fetcher: async () => { throw new TypeError('x'); } };
  assert.equal((await (await handleApi(new Request(`${base}/health/records`), down)).json()).error, 'NETWORK');
});

test('slow or failing Apps Script: one retry, then the saved copy (marked stale); fresh copies skip the script', async () => {
  let scriptCalls = 0, saved = null, failures = 0;
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1', allowedOrigins: [],
    playRecordUrl: SCRIPT, now: () => 1_000_000_000 + scriptCalls * 1000 + (saved ? 1 : 0),
    fetcher: async (url, opts = {}) => {
      if (url === `${SCRIPT}?action=summary`) {
        scriptCalls++;
        if (failures-- > 0) return new Response('not found', { status: 404 });
        return Response.json({ ok: true, summary, rewards });
      }
      const name = url.split('/rpc/')[1];
      if (name === 'get_record_snapshot') return Response.json(saved);
      if (name === 'put_record_snapshot') {
        saved = { payload: JSON.parse(opts.body).p_payload, fetched_at: new Date(1_000_000_000).toISOString() };
        return Response.json({ ok: true });
      }
      return new Response('{}', { status: 404 });
    } };
  failures = 1;  // first try 404, retry succeeds
  let res = await handleApi(new Request(`${base}/health/records`), settings);
  assert.deepEqual([res.status, scriptCalls], [200, 2]);
  assert.ok(saved, 'good copy saved');
  failures = 2;  // both tries fail: served from the saved copy, reported as stale
  res = await handleApi(new Request(`${base}/health/records`), settings);
  assert.deepEqual([res.status, (await res.json()).error, scriptCalls], [503, 'HTTP_404', 4]);
});

test('member card does not wait for the script: an outdated copy is shown at once and refreshed afterwards', async () => {
  const later = [];
  let scriptCalls = 0, saved = { payload: { summary, rewards }, fetched_at: '-infinity' };
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1', allowedOrigins: [],
    playRecordUrl: SCRIPT, now: () => 2_000_000_000, background: work => later.push(work),
    fetcher: async (url, opts = {}) => {
      if (url === `${SCRIPT}?action=summary`) { scriptCalls++; return Response.json({ ok: true, summary, rewards }); }
      const name = url.split('/rpc/')[1];
      if (name === 'resolve_session') return Response.json({ user_id: userId, display_name: '小明', is_admin: false });
      if (name === 'my_binding') return Response.json({ user_id: userId, record_name: '阿明', status: 'approved', bonus_status: 'granted' });
      if (name === 'get_record_snapshot') return Response.json(saved);
      if (name === 'put_record_snapshot') { saved = { payload: JSON.parse(opts.body).p_payload, fetched_at: new Date(2_000_000_000).toISOString() }; return Response.json({ ok: true }); }
      return Response.json(null);
    } };
  const res = await handleApi(new Request(`${base}/me/binding`, { headers: { Authorization: 'Bearer ' + 'S'.repeat(43) } }), settings);
  const { card } = await res.json();
  assert.deepEqual([card.balance, card.refreshing, scriptCalls], [100, true, 0], 'answered from the copy before reading the script');
  await Promise.all(later);
  assert.equal(scriptCalls, 1, 'refreshed after the response');
  assert.notEqual(saved.fetched_at, '-infinity');
});

test('LINE 玩後問卷: bound players get their name; a pending claim is offered; nothing else is guessed', async () => {
  const bound = backend({ binding: { user_id: userId, record_name: '阿明', status: 'approved', bonus_status: 'granted' }, now: 20 });
  assert.deepEqual(await (await call(bound.settings, '/me/survey')).json(), { recordName: '阿明', pendingName: null });
  const fresh = backend({ account: '新玩家', now: 21 });
  assert.equal((await (await call(fresh.settings, '/me/survey')).json()).recordName, '新玩家');
  const pending = backend({ binding: { user_id: userId, record_name: '小華', status: 'pending', bonus_status: 'none' }, now: 22 });
  assert.deepEqual(await (await call(pending.settings, '/me/survey')).json(), { recordName: null, pendingName: '小華' });
  const none = backend({ now: 23 });
  assert.deepEqual(await (await call(none.settings, '/me/survey')).json(), { recordName: null, pendingName: null });
});

test('a new player may claim only a brand-new name; existing 玩本記錄 names go through store-approved binding', async () => {
  const b = backend({ now: 24 });
  const claim = name => call(b.settings, '/me/survey/name', 'POST', { name });
  for (const name of ['阿明', ' 阿明 ', '小華']) {
    const res = await claim(name);
    assert.equal(res.status, 409, name);
    assert.equal((await res.json()).error, 'NAME_EXISTS');
  }
  assert.ok(!b.calls.some(c => c.url.endsWith('/claim_record_name')), 'existing names never reach the database claim');
  assert.equal((await claim('')).status, 400);
  assert.equal((await claim('字'.repeat(31))).status, 400);
  const ok = await claim(' 小海星 ');
  assert.equal(ok.status, 201);
  assert.equal((await ok.json()).recordName, '小海星');
});

test('a new name is never handed out from an outdated copy: naming pauses while the Apps Script is unreachable', async () => {
  // The saved copy is a week old; 「新來的」 joined the 玩本記錄 after it was taken.
  const week = 7 * 86400_000, now = 3_000_000_000_000;  // clocks rise through this file: the summary cache is shared
  let scriptUp = false, scriptReads = 0;
  const calls = [];
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1', allowedOrigins: [],
    playRecordUrl: SCRIPT, now: () => now,
    fetcher: async (url, opts = {}) => {
      calls.push(url);
      if (url === `${SCRIPT}?action=summary`) {
        scriptReads++;
        if (!scriptUp) throw new TypeError('network');
        return Response.json({ ok: true, summary: [...summary, { name: '新來的', agent: '#060', plays: 1, last: '2026/10/7' }], rewards });
      }
      switch (url.split('/rpc/')[1]) {
        case 'resolve_session': return Response.json({ user_id: userId, display_name: 'QA', is_admin: false });
        case 'get_record_snapshot': return Response.json({ payload: { ok: true, summary, rewards }, fetched_at: new Date(now - week).toISOString() });
        case 'claim_record_name': return Response.json({ record_name: JSON.parse(opts.body).p_name.trim() });
        default: return Response.json(null);
      }
    } };
  const claim = name => call(settings, '/me/survey/name', 'POST', { name });

  for (const name of ['新來的', '小海星']) {
    const res = await claim(name);
    assert.deepEqual([res.status, (await res.json()).error], [503, 'RECORDS_UNAVAILABLE'], name);
  }
  assert.ok(!calls.some(u => u.endsWith('/claim_record_name')), 'nothing is claimed from the outdated copy');
  assert.equal(scriptReads, 4, 'one read and one retry per request, no second round once the script has failed');
  // Names already in the old copy are still refused outright.
  assert.equal((await claim('阿明')).status, 409);

  scriptUp = true;
  const taken = await claim('新來的');
  assert.deepEqual([taken.status, (await taken.json()).error], [409, 'NAME_EXISTS'], 'the fresh list knows the newer name');
  const ok = await claim('小海星');
  assert.equal(ok.status, 201);
  assert.ok(calls.some(u => u.endsWith('/claim_record_name')));
});

test('veteran pages never wait on the Apps Script: names come from the saved copy, the bonus is granted afterwards', async () => {
  const later = [], calls = [];
  let release; const scriptHeld = new Promise(r => { release = r; });  // the Apps Script answers only when released
  let saved = { payload: { ok: true, summary, rewards }, fetched_at: new Date(0).toISOString() };  // long out of date
  let binding = { user_id: userId, record_name: '阿明', status: 'approved', bonus_status: 'none' };
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'k', loginChannelId: '1', allowedOrigins: [],
    playRecordUrl: SCRIPT, playRecordSecret: 'bonus-secret', now: () => 4_000_000_000_000, background: w => later.push(w),
    fetcher: async (url, opts = {}) => {
      if (url.startsWith(SCRIPT)) { calls.push(url === SCRIPT ? 'grant' : 'summary'); await scriptHeld; return Response.json(url === SCRIPT ? { ok: true, granted: true } : { ok: true, summary, rewards }); }
      const name = url.split('/rpc/')[1], args = opts.body ? JSON.parse(opts.body) : {};
      switch (name) {
        case 'resolve_session': return Response.json({ user_id: userId, display_name: 'QA', is_admin: false });
        case 'my_binding': return Response.json(binding);
        case 'bound_record_names': return Response.json([]);
        case 'get_record_snapshot': return Response.json(saved);
        case 'put_record_snapshot': saved = { payload: JSON.parse(opts.body).p_payload, fetched_at: new Date().toISOString() }; return Response.json({ ok: true });
        case 'mark_binding_bonus': binding = { ...binding, bonus_status: args.p_status }; return Response.json(binding);
        default: return Response.json(null);
      }
    } };
  const names = await (await call(settings, '/records/names')).json();
  assert.equal(names.names.length, 2);
  const card = await (await call(settings, '/me/binding')).json();
  assert.equal(card.binding.bonusStatus, 'none', 'answered before the bonus call');
  assert.equal(card.card.balance, 100);
  // Both answers above arrived while the Apps Script was still holding its reply.
  release();
  await Promise.all(later);
  assert.ok(calls.includes('grant') && calls.includes('summary'), 'bonus and fresh names follow after the response');
  assert.equal(binding.bonus_status, 'granted');
});
