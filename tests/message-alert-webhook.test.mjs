import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { handleWebhook } from '../supabase/functions/line-webhook/index.ts';

const secret = 'test-alert-secret';
const sender = 'U' + 'a'.repeat(32), recipient = 'U' + 'd'.repeat(32);
const event = { type: 'message', webhookEventId: 'message-1', timestamp: 1791428400000,
  source: { type: 'user', userId: sender }, message: { type: 'text', text: 'private conversation' } };
const alert = { id: 'alert-1', retry_key: 'retry-1', line_user_id: recipient, friend_status: 'active' };
function req(events = [event], signed = true) {
  const body = JSON.stringify({ events });
  return new Request('https://example.invalid', { method: 'POST', body,
    headers: { 'x-line-signature': signed ? createHmac('sha256',secret).update(body).digest('base64') : 'bad' } });
}
function setup({ alerts = [alert], pending = alerts.length, pushStatus = 200, failCompletion = false } = {}) {
  const calls = [];
  const settings = { channelSecret: secret, supabaseUrl: 'https://example.invalid', serviceKey: 'test-key',
    lineAccessToken: 'test-token', fetcher: async (url, opts) => {
      calls.push({ url, ...opts });
      if (url.endsWith('process_oa_message_alerts')) return Response.json({ alerts, pending_count: pending });
      if (url.endsWith('/push')) return new Response('', { status: pushStatus });
      if (url.endsWith('complete_oa_message_alert') && failCompletion) return new Response('', { status: 500 });
      return Response.json(null);
    } };
  return { calls, settings };
}
test('signed direct message notifies only stored recipient, without forwarding content or sender ID', async () => {
  const { calls, settings } = setup();
  assert.equal((await handleWebhook(req(),settings)).status,200);
  assert.deepEqual(JSON.parse(calls[0].body),{ p_events: [{ type:'message',userId:sender,
    timestamp:event.timestamp,webhookEventId:'message-1' }] });
  const push = calls.find(c=>c.url.endsWith('/push'));
  const sent = JSON.parse(push.body);
  assert.equal(sent.to,recipient);
  assert.equal(sent.notificationDisabled,false);
  assert.match(sent.messages[0].text,/chat\.line\.biz\/account\/@825gdzws/);
  assert.equal(push.headers['X-Line-Retry-Key'],'retry-1');
  assert.ok(!JSON.stringify(calls).includes('private conversation'));
  assert.ok(!push.body.includes(sender));
  assert.equal(JSON.parse(calls.at(-1).body).p_result,'sent');
});
test('signature rejection, groups, rooms, postbacks and Verify never alert', async () => {
  const { calls,settings } = setup();
  assert.equal((await handleWebhook(req([event],false),settings)).status,401);
  for (const events of [[],[{...event,source:{type:'group',userId:sender}}],
    [{...event,source:{type:'room',userId:sender}}],[{type:'postback'}]]) {
    assert.equal((await handleWebhook(req(events),settings)).status,200);
  }
  assert.equal(calls.length,0);
});
test('image, sticker, audio and file messages all trigger metadata-only alerts', async () => {
  for(const type of ['image','sticker','audio','file']) {
    const {calls,settings}=setup();
    assert.equal((await handleWebhook(req([{...event,message:{type,id:'private-media-id'}}]),settings)).status,200);
    assert.ok(!JSON.stringify(calls).includes('private-media-id'));
  }
});
test('deduped, self or cooldown-suppressed messages do not push',async()=>{
  const {calls,settings}=setup({alerts:[]});
  assert.equal((await handleWebhook(req(),settings)).status,200);
  assert.equal(calls.length,1);
});
test('network, 429 and server failure return 500 so LINE can redeliver',async()=>{
  for(const pushStatus of [429,500,503]) {
    const {calls,settings}=setup({pushStatus});
    const response=await handleWebhook(req(),settings);
    assert.equal(response.status,500);
    assert.equal(JSON.parse(calls.at(-1).body).p_result,'failed');
  }
  const {settings}=setup(); const original=settings.fetcher;
  settings.fetcher=async(url,opts)=>url.endsWith('/push') ? Promise.reject(new Error('private network detail')) : original(url,opts);
  const response=await handleWebhook(req(),settings);
  assert.equal(response.status,500);
  assert.ok(!(await response.text()).includes('private network detail'));
});
test('accepted retry key counts as sent; terminal recipient errors are skipped',async()=>{
  for(const pushStatus of [409,400,403]) {
    const {calls,settings}=setup({pushStatus});
    assert.equal((await handleWebhook(req(),settings)).status,200);
    assert.equal(JSON.parse(calls.at(-1).body).p_result,pushStatus===409?'sent':'skipped');
  }
  const {calls,settings}=setup({alerts:[{...alert,friend_status:'blocked'}]});
  assert.equal((await handleWebhook(req(),settings)).status,200);
  assert.ok(!calls.some(c=>c.url.endsWith('/push')));
});
test('missing push configuration, partial queue and failed completion stay retryable',async()=>{
  const missing=setup(); delete missing.settings.lineAccessToken;
  assert.equal((await handleWebhook(req(),missing.settings)).status,503);
  assert.equal(missing.calls.length,0);
  for(const opts of [{pending:21},{failCompletion:true}]) {
    const {settings}=setup(opts);
    assert.equal((await handleWebhook(req(),settings)).status,500);
  }
});
test('mixed follow and message persists friendship first and malformed direct user events fail closed',async()=>{
  const {calls,settings}=setup();
  assert.equal((await handleWebhook(req([{...event,type:'follow'},event]),settings)).status,200);
  assert.ok(calls[0].url.endsWith('process_line_events'));
  assert.ok(calls[1].url.endsWith('process_oa_message_alerts'));
  const invalid=setup();
  assert.equal((await handleWebhook(req([{...event,source:{type:'user',userId:'forged'}}]),invalid.settings)).status,400);
  assert.equal(invalid.calls.length,0);
});
