import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { handleWebhook } from '../supabase/functions/line-webhook/index.ts';
const secret = 'test-secret-not-a-real-credential';
const config = { channelSecret: secret, supabaseUrl: 'https://example.invalid', serviceKey: 'test-key' };
const follow = { type: 'follow', timestamp: 1790928000000, webhookEventId: 'event-1',
  source: { type: 'user', userId: 'U' + 'a'.repeat(32) } };
const body = JSON.stringify({ events: [follow] });
const sign = data => createHmac('sha256', secret).update(data).digest('base64');
function req(data = body, signature = sign(data)) {
  return new Request('https://example.invalid', { method: 'POST',
    headers: signature ? { 'x-line-signature': signature } : {}, body: data });
}
function capture() {
  const calls = [];
  return { calls, settings: { ...config, fetcher: async (url, opts) => {
    calls.push({ url, ...opts }); return new Response('{}');
  } } };
}
test('valid signature writes normalized batch, never raw message content', async () => {
  const { calls, settings } = capture();
  assert.equal((await handleWebhook(req(), settings)).status, 200);
  assert.equal(calls.length, 1);
  assert.deepEqual(JSON.parse(calls[0].body), { p_events: [{ type: 'follow',
    userId: follow.source.userId, timestamp: follow.timestamp, webhookEventId: 'event-1' }] });
});
test('missing, malformed and wrong signatures never touch database', async () => {
  const { calls, settings } = capture();
  for (const signature of ['', 'bad', sign('different')]) {
    assert.equal((await handleWebhook(req(body, signature), settings)).status, 401);
  }
  assert.equal(calls.length, 0);
});
test('a whitespace change invalidates signature: verify raw bytes, not parsed JSON', async () => {
  const { settings } = capture();
  assert.equal((await handleWebhook(req(body + ' ', sign(body)), settings)).status, 401);
});
test('LINE verification with empty array succeeds without database access', async () => {
  const { calls, settings } = capture();
  assert.equal((await handleWebhook(req('{"events":[]}'), settings)).status, 200);
  assert.equal(calls.length, 0);
});
test('multiple follow/unfollow events are submitted in one transaction', async () => {
  const { calls, settings } = capture();
  const events = [follow, { ...follow, type: 'unfollow', webhookEventId: 'event-2' }];
  assert.equal((await handleWebhook(req(JSON.stringify({ events })), settings)).status, 200);
  assert.equal(calls.length, 1);
  assert.equal(JSON.parse(calls[0].body).p_events.length, 2);
});
test('unhandled event types are acknowledged without storing private message text', async () => {
  const { calls, settings } = capture();
  const data = JSON.stringify({ events: [{ type: 'message', message: { text: 'private' } }] });
  assert.equal((await handleWebhook(req(data), settings)).status, 200);
  assert.equal(calls.length, 0);
});
test('malformed signed payloads and invalid identities fail closed', async () => {
  const { calls, settings } = capture();
  for (const data of ['null', '{', '{}', '{"events":[null]}', JSON.stringify({ events: [{ ...follow,
    source: { type: 'user', userId: 'forged' } }] })]) {
    assert.equal((await handleWebhook(req(data), settings)).status, 400);
  }
  assert.equal(calls.length, 0);
});
test('non-POST, missing configuration and oversized input are rejected', async () => {
  assert.equal((await handleWebhook(new Request('https://example.invalid'), config)).status, 405);
  assert.equal((await handleWebhook(req(), {})).status, 503);
  const data = 'x'.repeat(1024 * 1024 + 1);
  assert.equal((await handleWebhook(req(data), config)).status, 413);
});
test('database failure/timeout returns 500 to allow LINE redelivery, no sensitive errors', async () => {
  for (const fetcher of [async () => new Response('sensitive db details', { status: 500 }),
    async () => { throw new Error('secret connection details'); }]) {
    const response = await handleWebhook(req(), { ...config, fetcher });
    assert.equal(response.status, 500);
    assert.deepEqual(await response.json(), { error: 'event_persistence_failed' });
  }
});
