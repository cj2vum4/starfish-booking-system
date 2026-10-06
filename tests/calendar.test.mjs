import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createVerify } from 'node:crypto';
import { handleApi, sha256Hex } from '../supabase/functions/api/index.ts';

const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const google = { clientEmail: 'freebusy@test.iam.gserviceaccount.com', calendarId: 'owner@example.com',
  privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const now = Date.parse('2026-10-02T04:00:00Z');  // 12:00 Taipei
const base = 'https://example.invalid/functions/v1/api';
const token = 'S'.repeat(43);
const dinner = { start: '2026-10-05T10:30:00Z', end: '2026-10-05T11:30:00Z' };

function backend({ googleDown = false, calendarError = false, withGoogle = true } = {}) {
  const calls = [];
  const fetcher = async (url, opts) => {
    calls.push({ url, body: opts.body, auth: opts.headers?.Authorization });
    if (url === 'https://oauth2.googleapis.com/token') {
      if (googleDown) throw new Error('network');
      const assertion = new URLSearchParams(opts.body).get('assertion');
      const [h, c, sig] = assertion.split('.');
      const ok = createVerify('RSA-SHA256').update(`${h}.${c}`).verify(publicKey, Buffer.from(sig, 'base64url'));
      const claims = JSON.parse(Buffer.from(c, 'base64url'));
      if (!ok || claims.iss !== google.clientEmail || !claims.scope.split(' ').includes('https://www.googleapis.com/auth/calendar.freebusy')) {
        return new Response('{}', { status: 400 });
      }
      return Response.json({ access_token: 'google-access', expires_in: 3600 });
    }
    if (url === 'https://www.googleapis.com/calendar/v3/freeBusy') {
      if (googleDown) throw new Error('network');
      const errors = calendarError ? [{ reason: 'notFound' }] : undefined;
      return Response.json({ calendars: { [google.calendarId]: { busy: calendarError ? [] : [dinner], errors } } });
    }
    const name = url.split('/rpc/')[1];
    const args = JSON.parse(opts.body);
    if (name === 'resolve_session') {
      return Response.json(args.p_session_hash === await sha256Hex(token)
        ? { user_id: 'user-1', display_name: 'QA', is_admin: false, expires_at: '2026-10-02T16:00:00Z' } : null);
    }
    if (name === 'sync_calendar_busy') return Response.json({ busy: args.p_busy.length });
    if (name === 'list_available_starts') {
      return Response.json([{ starts_at: '2026-10-05T12:00:00+00:00', ends_at: '2026-10-05T16:00:00+00:00' }]);
    }
    if (name === 'create_group') return Response.json({ group_id: 'group-1', created: true,
      starts_at: args.p_starts_at, ends_at: '2026-10-05T16:00:00+00:00' });
    return new Response('{}', { status: 404 });
  };
  return { calls, settings: { loginChannelId: '2000000000', supabaseUrl: 'https://db.invalid', serviceKey: 'k',
    allowedOrigins: [], google: withGoogle ? google : undefined, now: () => now, fetcher } };
}
const get = path => new Request(`${base}${path}`, { headers: { Authorization: `Bearer ${token}` } });
const post = (path, body) => new Request(`${base}${path}`, { method: 'POST',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
const rpcNames = calls => calls.filter(c => c.url.includes('/rpc/')).map(c => c.url.split('/rpc/')[1]);
const group = { requestId: '11111111-1111-4111-8111-111111111111', startsAt: '2026-10-05T12:00:00Z', capacity: 6 };

test('slots are listed only after a fresh Google free/busy sync of the same window', async () => {
  const { calls, settings } = backend();
  const response = await handleApi(get('/slots?from=2026-10-05&days=2'), settings);
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).slots, [{ startsAt: '2026-10-05T12:00:00+00:00', endsAt: '2026-10-05T16:00:00+00:00' }]);
  assert.deepEqual(rpcNames(calls), ['resolve_session', 'sync_calendar_busy', 'list_available_starts']);
  const freebusy = JSON.parse(calls.find(c => c.url.endsWith('/freeBusy')).body);
  // 2026-10-05 00:00 Taipei = 2026-10-04 16:00 UTC; two days later.
  assert.equal(freebusy.timeMin, '2026-10-04T16:00:00.000Z');
  assert.equal(freebusy.timeMax, '2026-10-06T16:00:00.000Z');
  const sync = JSON.parse(calls.find(c => c.url.endsWith('/sync_calendar_busy')).body);
  assert.deepEqual(sync.p_busy, [dinner]);
  assert.equal(calls.find(c => c.url.endsWith('/freeBusy')).auth, 'Bearer google-access');
});

test('creating a group re-checks the calendar first and uses the session user, not body input', async () => {
  const { calls, settings } = backend();
  const response = await handleApi(post('/groups', { ...group, actor: 'someone-else', p_actor: 'x' }), settings);
  assert.equal(response.status, 201);
  assert.deepEqual(rpcNames(calls), ['expire_stale_groups', 'resolve_session', 'sync_calendar_busy', 'create_group']);
  const args = JSON.parse(calls.find(c => c.url.endsWith('/create_group')).body);
  assert.equal(args.p_actor, 'user-1');
  assert.equal(args.p_starts_at, '2026-10-05T12:00:00.000Z');
});

test('calendar outages or errors fail closed: nothing is listed or reserved', async () => {
  for (const options of [{ googleDown: true }, { calendarError: true }, { withGoogle: false }]) {
    const { calls, settings } = backend(options);
    const listed = await handleApi(get('/slots'), settings);
    const created = await handleApi(post('/groups', group), settings);
    assert.equal(listed.status, 503, JSON.stringify(options));
    assert.equal(created.status, 503, JSON.stringify(options));
    assert.ok(!rpcNames(calls).some(n => n === 'list_available_starts' || n === 'create_group'));
  }
});

test('slot and group routes require a session and validate input', async () => {
  const { calls, settings } = backend();
  assert.equal((await handleApi(new Request(`${base}/slots`), settings)).status, 401);
  assert.equal((await handleApi(get('/slots?days=90'), settings)).status, 400);
  assert.equal((await handleApi(get('/slots?from=2026-13-40'), settings)).status, 400);
  assert.equal((await handleApi(post('/groups', { ...group, requestId: 'nope' }), settings)).status, 400);
  assert.equal((await handleApi(post('/groups', { ...group, startsAt: 'tomorrow-ish' }), settings)).status, 400);
  assert.ok(!calls.some(c => c.url.endsWith('/freeBusy')));
});

test('setup check reports which Google step failed without exposing calendar data', async () => {
  const check = async options => {
    const { calls, settings } = backend(options);
    const response = await handleApi(new Request(`${base}/health/calendar`), { ...settings, loginChannelId: undefined });
    return { status: response.status, body: await response.json(), calls };
  };
  const ok = await check({});
  assert.deepEqual([ok.status, ok.body], [200, { ok: true, publishedCalendars: 0 }]);
  assert.ok(!JSON.stringify(ok.body).includes(dinner.start), 'busy times leaked');
  assert.ok(!ok.calls.some(c => c.url.includes('/rpc/')), 'health check touched the database');
  assert.equal((await check({ calendarError: true })).body.error, 'CALENDAR_NOT_SHARED');
  assert.equal((await check({ withGoogle: false })).body.error, 'CALENDAR_NOT_CONFIGURED');
});

test('listing reuses a fresh sync of a covering window; creating a group always syncs live', async () => {
  const { calls, settings } = backend();
  let clock = now;
  settings.now = () => clock;
  const freebusy = () => calls.filter(c => c.url.endsWith('/freeBusy')).length;
  await handleApi(get('/slots?from=2026-10-05&days=7'), settings);
  const first = freebusy();
  await handleApi(get('/slots?from=2026-10-05&days=3'), settings);   // inside the synced window, 0s later
  assert.equal(freebusy(), first, 'flood of listings does not hit Google each time');
  clock += 61 * 1000;
  await handleApi(get('/slots?from=2026-10-05&days=3'), settings);
  assert.equal(freebusy(), first + 1, 'stale after a minute');
  await handleApi(post('/groups', group), settings);
  await handleApi(post('/groups', group), settings);
  assert.equal(freebusy(), first + 3, 'every reservation re-checks the calendar');
});
