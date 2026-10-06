import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, notificationText } from '../supabase/functions/api/index.ts';
const event = '22222222-2222-4222-8222-222222222222';

test('after attendance the reminder sends players to the website form, which lists each script\'s roles', () => {
  const text = notificationText({ kind: 'review_reminder', event_id: event, game_title: '年輪', played_date: '2026-10-05' });
  assert.match(text, /2026-10-05《年輪》/);
  assert.ok(text.includes('https://cj2vum4.github.io/starfishlarp/%E6%96%B0%E5%A2%9E%E7%8E%A9%E6%9C%AC%E8%A8%98%E9%8C%84.html'));
  assert.doesNotMatch(text, /review=/);
});

test('LINE no longer accepts 玩本心得 itself', async () => {
  const settings = { supabaseUrl: 'https://db.invalid', serviceKey: 'test', loginChannelId: '1', playRecordSecret: 'test-only',
    fetcher: async url => url.endsWith('/rpc/resolve_session') ? Response.json({ user_id: 'u', display_name: 'x', is_admin: false }) : Response.json([]) };
  for (const [method, path] of [['POST', `/me/reviews/${event}`], ['GET', `/me/reviews/${event}`], ['POST', '/me/records'], ['GET', '/me/records']]) {
    const res = await handleApi(new Request(`https://api.invalid${path}`, { method,
      headers: { Authorization: 'Bearer ' + 'S'.repeat(43), 'Content-Type': 'application/json' },
      ...(method === 'POST' ? { body: '{"character":"甲","rating":5,"comment":"好玩"}' } : {}) }), settings);
    assert.equal(res.status, 404, `${method} ${path}`);
  }
});
