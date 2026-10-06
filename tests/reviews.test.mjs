import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, notificationText } from '../supabase/functions/api/index.ts';
const actor = '11111111-1111-4111-8111-111111111111';
const event = '22222222-2222-4222-8222-222222222222';
const script = 'https://script.invalid/exec';
function backend({ denied = false, result = { ok: true, name: '歸戶名' } } = {}) {
  const posts = [];
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'test', loginChannelId: '1',
    playRecordUrl: script, playRecordSecret: 'test-only', fetcher: async (url, opts) => {
      if (url === script) { posts.push(new URLSearchParams(opts.body)); return Response.json(result); }
      const args = JSON.parse(opts.body);
      switch (url.split('/rpc/')[1]) {
        case 'resolve_session': return Response.json({ user_id: actor, display_name: 'LINE 名', is_admin: false });
        case 'my_manual_review_context':
        case 'my_review_context':
          assert.equal(args.p_actor, actor);
          return denied ? Response.json({ code: 'P0001', message: 'REVIEW_NOT_FOUND' }, { status: 400 }) :
            Response.json({ event_id: event, record_name: '歸戶名', display_name: 'LINE 名', date: '2026-10-05', title: '年輪完整版', review_key: '年輪' });
        default: return Response.json([]);
      }
    } };
  return { settings, posts };
}
function call(settings, body, token = true) {
  return handleApi(new Request(`https://api.invalid/me/reviews/${event}`, { method: 'POST',
    headers: { ...(token ? { Authorization: 'Bearer ' + 'S'.repeat(43) } : {}), 'Content-Type': 'application/json' },
    body: JSON.stringify(body) }), settings);
}
const valid = { character: '甲', rating: 5, comment: '好玩' };
test('review submission uses authenticated identity and attendance, ignoring forged identity/game/date', async () => {
  const { settings, posts } = backend();
  assert.equal((await call(settings, { ...valid, actor: 'fake', name: '冒用', date: '2000-01-01', script: '偽造' })).status, 200);
  assert.deepEqual(['actor','name','date','script','event'].map(k => posts[0].get(k)), [actor,'歸戶名','2026-10-05','年輪',event]);
});
test('missing session, absent players and invalid reviews cannot reach the sheet', async () => {
  const b = backend({ denied: true });
  assert.equal((await call(b.settings, valid, false)).status, 401);
  assert.equal((await call(b.settings, valid)).status, 404);
  assert.equal(b.posts.length, 0);
  const c = backend();
  assert.equal((await call(c.settings, { ...valid, rating: 6 })).status, 400);
  assert.equal(c.posts.length, 0);
});
test('sheet failures remain retryable, successful duplicate is explicit; reminder targets this event', async () => {
  const b = backend({ result: { ok: false, error: 'INVALID_SECRET' } });
  assert.equal((await call(b.settings, valid)).status, 502);
  const c = backend({ result: { ok: true, duplicate: true, name: '歸戶名' } });
  assert.equal((await (await call(c.settings, valid)).json()).duplicate, true);
  assert.match(notificationText({ kind: 'review_reminder', event_id: event, game_title: '年輪', played_date: '2026-10-05' }), /review=22222222/);
});

test('manual records still use LINE identity and a stable submission key across retries', async () => {
  const { settings, posts } = backend();
  const send = date => handleApi(new Request('https://api.invalid/me/records', { method: 'POST',
    headers: { Authorization: 'Bearer ' + 'S'.repeat(43), 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...valid, gameId: event, date, name: '冒用者' }) }), settings);
  assert.equal((await send('2026-10-05')).status, 200);
  assert.equal((await send('2026-10-05')).status, 200);
  assert.equal(posts[0].get('event'), posts[1].get('event'));
  assert.equal(posts[0].get('name'), '歸戶名');
  assert.equal((await send('invalid')).status, 400);
});
