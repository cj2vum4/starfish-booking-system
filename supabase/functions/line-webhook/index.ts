// No external runtime dependencies. Shared by Supabase Deno and Node 24 tests.
type Settings = {
  channelSecret?: string;
  supabaseUrl?: string;
  serviceKey?: string;
  fetcher?: typeof fetch;
};
type LineEvent = { type: string; webhookEventId: string; timestamp: number;
  source?: { type?: string; userId?: string } };
const MAX_BODY = 1024 * 1024;
const json = (status: number, data: unknown) => new Response(JSON.stringify(data), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});

async function readBody(req: Request): Promise<Uint8Array> {
  const reader = req.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > MAX_BODY) { await reader.cancel(); throw new Error('too_large'); }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { body.set(chunk, offset); offset += chunk.length; }
  return body;
}

export async function verifySignature(body: Uint8Array, signature: string, secret: string) {
  if (!/^[A-Za-z0-9+/]{43}=$/.test(signature)) return false;
  try {
    const bytes = Uint8Array.from(atob(signature), c => c.charCodeAt(0));
    const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    return await crypto.subtle.verify('HMAC', key, bytes, body);
  } catch { return false; }
}

export async function handleWebhook(req: Request, settings: Settings): Promise<Response> {
  if (req.method !== 'POST') return new Response(null, { status: 405, headers: { Allow: 'POST' } });
  const signature = req.headers.get('x-line-signature');
  if (!signature) return json(401, { error: 'invalid_signature' });
  if (!settings.channelSecret || !settings.supabaseUrl || !settings.serviceKey) {
    return json(503, { error: 'webhook_not_configured' });
  }
  let body: Uint8Array;
  try { body = await readBody(req); }
  catch { return json(413, { error: 'invalid_body_size' }); }
  if (!(await verifySignature(body, signature, settings.channelSecret))) {
    return json(401, { error: 'invalid_signature' });
  }
  let payload: { events: LineEvent[] };
  try { payload = JSON.parse(new TextDecoder().decode(body)); }
  catch { return json(400, { error: 'invalid_json' }); }
  if (!payload || !Array.isArray(payload.events) || payload.events.length > 1000) {
    return json(400, { error: 'invalid_events' });
  }
  const events = [];
  for (const event of payload.events) {
    if (!event || typeof event.type !== 'string') return json(400, { error: 'invalid_event' });
    // Other event types will be implemented separately; do not retain chat content.
    if (event.type !== 'follow' && event.type !== 'unfollow') continue;
    if (event.source?.type !== 'user' || !/^U[0-9a-f]{32}$/.test(event.source?.userId ?? '') ||
        typeof event.webhookEventId !== 'string' || event.webhookEventId.length < 1 ||
        event.webhookEventId.length > 128 || !Number.isSafeInteger(event.timestamp) ||
        event.timestamp < 0) return json(400, { error: 'invalid_event' });
    events.push({ type: event.type, userId: event.source.userId,
      timestamp: event.timestamp, webhookEventId: event.webhookEventId });
  }
  // LINE's Verify button sends a signed payload with an empty events array.
  if (!events.length) return json(200, { ok: true });
  try {
    const response = await (settings.fetcher ?? fetch)(
      `${settings.supabaseUrl}/rest/v1/rpc/process_line_events`, {
        method: 'POST', signal: AbortSignal.timeout(8000),
        headers: { 'Content-Type': 'application/json', apikey: settings.serviceKey,
          Authorization: `Bearer ${settings.serviceKey}` },
        body: JSON.stringify({ p_events: events }),
      });
    if (!response.ok) return json(500, { error: 'event_persistence_failed' });
    return json(200, { ok: true });
  } catch { return json(500, { error: 'event_persistence_failed' }); }
}

// Node imports this module for tests; only Deno starts the HTTP listener.
if (typeof Deno !== 'undefined') {
  Deno.serve((req: Request) => handleWebhook(req, {
    channelSecret: Deno.env.get('LINE_CHANNEL_SECRET'),
    supabaseUrl: Deno.env.get('SUPABASE_URL'),
    serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
  }));
}
