import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, notificationText, processRecordSubmissions } from '../supabase/functions/api/index.ts';
const actor = '11111111-1111-4111-8111-111111111111';
const event = '22222222-2222-4222-8222-222222222222';
const script = 'https://script.invalid/exec';
// A tiny stand-in for record_submissions: queue, claim, complete.
function backend({ denied = false, result = { ok: true, name: '歸戶名' }, background } = {}) {
  const posts = [], queue = new Map(), saved = [];
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'test', loginChannelId: '1', background,
    playRecordUrl: script, playRecordSecret: 'test-only', fetcher: async (url, opts) => {
      if (url === script) { posts.push(new URLSearchParams(opts.body)); return typeof result === 'function' ? result() : Response.json(result); }
      const args = JSON.parse(opts.body);
      switch (url.split('/rpc/')[1]) {
        case 'resolve_session': return Response.json({ user_id: actor, display_name: 'LINE 名', is_admin: false });
        case 'my_manual_review_context':
        case 'my_review_context':
          assert.equal(args.p_actor, actor);
          return denied ? Response.json({ code: 'P0001', message: 'REVIEW_NOT_FOUND' }, { status: 400 }) :
            Response.json({ event_id: event, record_name: '歸戶名', display_name: 'LINE 名', date: '2026-10-05', title: '年輪完整版', review_key: '年輪' });
        case 'queue_record_submission': {
          const key = args.p_actor + args.p_record_id, old = queue.get(key);
          if (old && old.status !== 'failed') return Response.json({ status: old.status, duplicate: true });
          queue.set(key, { ...args, status: 'pending', attempts: 0 });
          return Response.json({ status: 'pending', duplicate: false });
        }
        case 'claim_record_submissions': {
          const picked = [...queue.values()].filter(s => s.status === 'pending');
          picked.forEach(s => { s.status = 'sending'; s.attempts++; });
          return Response.json(picked.map(s => ({ user_id: s.p_actor, record_id: s.p_record_id, title: s.p_title,
            review_key: s.p_review_key, date: s.p_date, character: s.p_character, rating: s.p_rating, comment: s.p_comment,
            record_name: s.p_record_name, display_name: s.p_display_name })));
        }
        case 'complete_record_submission': {
          const s = queue.get(args.p_actor + args.p_record_id);
          s.status = args.p_error === null ? 'saved' : args.p_permanent ? 'failed' : 'pending';
          s.error = args.p_error;
          return Response.json(null);
        }
        case 'save_record_account': saved.push(args.p_name); return Response.json(null);
        default: return Response.json([]);
      }
    } };
  return { settings, posts, queue, saved };
}
function call(settings, body, token = true) {
  return handleApi(new Request(`https://api.invalid/me/reviews/${event}`, { method: 'POST',
    headers: { ...(token ? { Authorization: 'Bearer ' + 'S'.repeat(43) } : {}), 'Content-Type': 'application/json' },
    body: JSON.stringify(body) }), settings);
}
const valid = { character: '甲', rating: 5, comment: '好玩' };

test('the player gets an answer before the slow sheet write, which happens afterwards', async () => {
  const later = [];
  const b = backend({ background: work => later.push(work) });
  const res = await call(b.settings, valid);
  assert.equal(res.status, 202);
  assert.deepEqual(await res.json(), { queued: true, status: 'pending', duplicate: false });
  assert.equal(b.posts.length, 0, 'sheet not contacted while the player waits');
  await Promise.all(later);
  assert.equal(b.posts.length, 1);
  assert.deepEqual([...b.queue.values()].map(s => s.status), ['saved']);
  assert.deepEqual(b.saved, ['歸戶名']);
});
test('review submission uses authenticated identity and attendance, ignoring forged identity/game/date', async () => {
  const { settings, posts } = backend();
  assert.equal((await call(settings, { ...valid, actor: 'fake', name: '冒用', date: '2000-01-01', script: '偽造' })).status, 202);
  assert.deepEqual(['actor','name','date','script','event'].map(k => posts[0].get(k)), [actor,'歸戶名','2026-10-05','年輪',event]);
});
test('missing session, absent players and invalid reviews are never queued', async () => {
  const b = backend({ denied: true });
  assert.equal((await call(b.settings, valid, false)).status, 401);
  assert.equal((await call(b.settings, valid)).status, 404);
  assert.equal(b.queue.size, 0);
  const c = backend();
  assert.equal((await call(c.settings, { ...valid, rating: 6 })).status, 400);
  assert.equal((await call(c.settings, { ...valid, comment: '字'.repeat(51) })).status, 400);
  assert.equal(c.queue.size, 0);
});
test('a second submission for the same session is a duplicate; temporary sheet errors retry, identity conflicts stop', async () => {
  const ok = backend();
  await call(ok.settings, valid);
  assert.equal((await (await call(ok.settings, valid)).json()).duplicate, true);
  assert.equal(ok.posts.length, 1);
  let down = true;
  const flaky = backend({ result: () => down ? new Response('busy', { status: 500 }) : Response.json({ ok: true, name: '歸戶名' }) });
  await call(flaky.settings, valid);
  assert.deepEqual([...flaky.queue.values()].map(s => [s.status, s.error]), [['pending', 'HTTP_500']]);
  down = false;
  await processRecordSubmissions(flaky.settings);
  assert.deepEqual([...flaky.queue.values()].map(s => s.status), ['saved']);
  const merge = backend({ result: { ok: false, error: 'IDENTITY_MERGE_REQUIRED' } });
  await call(merge.settings, valid);
  assert.deepEqual([...merge.queue.values()].map(s => s.status), ['failed']);
  assert.match(notificationText({ kind: 'review_reminder', event_id: event, game_title: '年輪', played_date: '2026-10-05' }), /review=22222222/);
});

test('manual records still use LINE identity and a stable submission key across retries', async () => {
  const { settings, posts, queue } = backend();
  const send = date => handleApi(new Request('https://api.invalid/me/records', { method: 'POST',
    headers: { Authorization: 'Bearer ' + 'S'.repeat(43), 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...valid, gameId: event, date, name: '冒用者' }) }), settings);
  assert.equal((await send('2026-10-05')).status, 202);
  assert.equal((await (await send('2026-10-05')).json()).duplicate, true);
  assert.equal(queue.size, 1);
  assert.equal(posts[0].get('name'), '歸戶名');
  assert.equal((await send('invalid')).status, 400);
});

test('the list of my LINE reviews and my record name come from the database only', async () => {
  const { settings, posts } = backend();
  const res = await handleApi(new Request('https://api.invalid/me/records', {
    headers: { Authorization: 'Bearer ' + 'S'.repeat(43) } }), settings);
  assert.equal(res.status, 200);
  assert.deepEqual(Object.keys(await res.json()).sort(), ['recordName', 'submissions']);
  assert.equal(posts.length, 0);
});
