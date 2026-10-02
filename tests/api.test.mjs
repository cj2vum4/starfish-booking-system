import test from 'node:test';
import assert from 'node:assert/strict';
import { handleApi, sha256Hex, statusForCode } from '../supabase/functions/api/index.ts';

const channelId = '2000000000';
const lineUser = 'U' + 'b'.repeat(32);
const now = 1790928000000;
const base = 'https://example.invalid/functions/v1/api';
const config = { loginChannelId: channelId, supabaseUrl: 'https://db.invalid', serviceKey: 'test-key',
  allowedOrigins: ['https://liff.example'], now: () => now };
const goodClaims = { iss: 'https://access.line.me', sub: lineUser, aud: channelId, exp: now / 1000 + 600, name: 'QA' };

// Fake LINE verify endpoint + PostgREST RPC with an in-memory session table.
function backend({ claims = goodClaims, lineStatus = 200, rpcFailure } = {}) {
  const calls = [];
  const sessions = new Map();
  const fetcher = async (url, opts) => {
    calls.push({ url, body: opts.body });
    if (url.startsWith('https://api.line.me/')) {
      return new Response(JSON.stringify(lineStatus === 200 ? claims : { error: 'invalid_request' }), { status: lineStatus });
    }
    if (rpcFailure) return rpcFailure();
    const name = url.split('/rpc/')[1];
    const args = JSON.parse(opts.body);
    if (name === 'login_line_user') {
      sessions.set(args.p_session_hash, { user_id: 'user-1', display_name: args.p_display_name,
        is_admin: false, expires_at: args.p_expires_at });
      return Response.json({ user_id: 'user-1', display_name: args.p_display_name, is_admin: false });
    }
    if (name === 'resolve_session') return Response.json(sessions.get(args.p_session_hash) ?? null);
    if (name === 'logout_session') return Response.json({ logged_out: sessions.delete(args.p_session_hash) });
    return new Response('{}', { status: 404 });
  };
  return { calls, sessions, settings: { ...config, fetcher } };
}
const login = (settings, idToken = 'x'.repeat(40)) => handleApi(new Request(`${base}/auth/line`, {
  method: 'POST', headers: { 'Content-Type': 'application/json', Origin: 'https://liff.example' },
  body: JSON.stringify({ idToken }) }), settings);
const withToken = (path, token, method = 'GET') => new Request(`${base}${path}`,
  { method, headers: { Authorization: `Bearer ${token}` } });

test('verified LINE ID token creates a server session; only its hash reaches the database', async () => {
  const { calls, sessions, settings } = backend();
  const response = await login(settings);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('access-control-allow-origin'), 'https://liff.example');
  const data = await response.json();
  assert.match(data.sessionToken, /^[A-Za-z0-9_-]{43}$/);
  assert.deepEqual(data.user, { id: 'user-1', displayName: 'QA', isAdmin: false });
  assert.equal(new Date(data.expiresAt).getTime(), now + 12 * 3600 * 1000);
  const verify = new URLSearchParams(calls[0].body);
  assert.equal(verify.get('client_id'), channelId);
  const loginCall = JSON.parse(calls[1].body);
  assert.equal(loginCall.p_line_user_id, lineUser);
  assert.equal(loginCall.p_session_hash, await sha256Hex(data.sessionToken));
  assert.ok(!calls.slice(1).some(c => c.body.includes(data.sessionToken)), 'raw session token sent to database');
  assert.ok(!calls.slice(1).some(c => c.body.includes('x'.repeat(40))), 'raw ID token sent to database');
  assert.ok(sessions.has(loginCall.p_session_hash));
});

test('/me resolves the session, never exposes LINE userId; logout invalidates it', async () => {
  const { settings } = backend();
  const { sessionToken } = await (await login(settings)).json();
  const me = await handleApi(withToken('/me', sessionToken), settings);
  assert.equal(me.status, 200);
  const text = await me.text();
  assert.ok(!text.includes(lineUser));
  assert.equal(JSON.parse(text).user.id, 'user-1');
  assert.equal((await handleApi(withToken('/auth/logout', sessionToken, 'POST'), settings)).status, 200);
  assert.equal((await handleApi(withToken('/me', sessionToken), settings)).status, 401);
});

test('forged userId or session cannot impersonate another player', async () => {
  const { calls, settings } = backend();
  const forged = await handleApi(new Request(`${base}/auth/line`, { method: 'POST',
    body: JSON.stringify({ userId: lineUser }) }), settings);
  assert.equal(forged.status, 400);
  for (const header of [undefined, 'Bearer short', `Bearer ${'A'.repeat(43)}`, lineUser]) {
    const res = await handleApi(new Request(`${base}/me`, { headers: header ? { Authorization: header } : {} }), settings);
    assert.equal(res.status, 401);
  }
  assert.ok(!calls.some(c => c.url.includes('login_line_user')));
});

test('invalid, expired, wrong-audience or wrong-issuer tokens are rejected before login', async () => {
  const cases = [
    { lineStatus: 400 },
    { claims: { ...goodClaims, exp: now / 1000 - 1 } },
    { claims: { ...goodClaims, aud: '1999999999' } },
    { claims: { ...goodClaims, iss: 'https://evil.example' } },
    { claims: { ...goodClaims, sub: 'forged' } },
  ];
  for (const options of cases) {
    const { calls, settings } = backend(options);
    const response = await login(settings);
    assert.equal(response.status, 401, JSON.stringify(options));
    assert.deepEqual(await response.json(), { error: 'INVALID_ID_TOKEN' });
    assert.ok(!calls.some(c => c.url.includes('/rpc/')));
  }
});

test('database details are never leaked; business codes map to HTTP status', async () => {
  const { settings } = backend({ rpcFailure: () => new Response(JSON.stringify(
    { code: '42P01', message: 'relation "secret_table" does not exist' }), { status: 400 }) });
  const response = await login(settings);
  assert.equal(response.status, 500);
  assert.deepEqual(await response.json(), { error: 'DATABASE_ERROR' });
  const down = backend({ rpcFailure: () => { throw new Error('connection string with password'); } });
  assert.deepEqual(await (await login(down.settings)).json(), { error: 'DATABASE_UNAVAILABLE' });
  assert.equal(statusForCode('SOLD_OUT'), 409);
  assert.equal(statusForCode('GROUP_NOT_FOUND'), 404);
  assert.equal(statusForCode('NOT_ADMIN'), 403);
  assert.equal(statusForCode('INVALID_CAPACITY'), 400);
});

test('CORS only for configured origins; unknown routes and missing config fail closed', async () => {
  const { settings } = backend();
  const ok = await handleApi(new Request(`${base}/me`, { method: 'OPTIONS', headers: { Origin: 'https://liff.example' } }), settings);
  assert.equal(ok.status, 204);
  const evil = await handleApi(new Request(`${base}/me`, { method: 'OPTIONS', headers: { Origin: 'https://evil.example' } }), settings);
  assert.equal(evil.status, 403);
  assert.equal(evil.headers.get('access-control-allow-origin'), null);
  assert.equal((await handleApi(new Request(`${base}/nope`), settings)).status, 404);
  assert.equal((await handleApi(new Request(`${base}/me`), {})).status, 503);
  const big = await handleApi(new Request(`${base}/auth/line`, { method: 'POST', body: 'x'.repeat(70000) }), settings);
  assert.equal(big.status, 413);
});
