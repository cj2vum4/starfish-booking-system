import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, notificationText } from '../supabase/functions/api/index.ts';
const event = '22222222-2222-4222-8222-222222222222';

test('recording attendance sends no 玩後問卷 reminder (the store hands out a QR code)', () => {
  assert.equal(notificationText({ kind: 'review_reminder', event_id: event, game_title: '年輪', played_date: '2026-10-05' }), null);
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
