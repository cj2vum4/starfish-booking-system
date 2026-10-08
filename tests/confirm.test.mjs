import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { handleApi, sha256Hex } from '../supabase/functions/api/index.ts';

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const google = { clientEmail: 'sa@test.iam.gserviceaccount.com', calendarId: 'owner@example.com',
  eventsCalendarId: 'store-calendar@group.calendar.google.com', privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const session = 'S'.repeat(43);
const groupId = '44444444-4444-4444-8444-444444444444';
const eventId = '55555555-5555-4555-8555-555555555555';
const payload = { event_id: eventId, google_event_id: null, title: '王座', starts_at: '2026-10-10T05:00:00+00:00',
  ends_at: '2026-10-10T09:30:00+00:00', venue: '海星劇本殺', dm_name: '店長', price_cents: 65000, capacity: 7,
  organizer_name: '阿明', players: ['阿明', '涵涵'] };

function backend({ isAdmin = true, googleStatus = 200, alreadySynced = false, withEventsCalendar = true,
  busyStatus = 200, confirmed = false } = {}) {
  const calls = [];
  const fetcher = async (url, opts = {}) => {
    calls.push({ url, body: opts.body });
    if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'g', expires_in: 3600 });
    if (url === 'https://www.googleapis.com/calendar/v3/freeBusy') return Response.json({
      calendars: { [google.calendarId]: { busy: [] } } }, { status: busyStatus });
    if (url.startsWith('https://www.googleapis.com/calendar/v3/calendars/')) {
      return new Response('{}', { status: googleStatus });
    }
    const name = url.split('/rpc/')[1];
    const args = JSON.parse(opts.body);
    if (name === 'resolve_session') return Response.json(args.p_session_hash === await sha256Hex(session)
      ? { user_id: 'owner', display_name: '店長', is_admin: isAdmin, expires_at: 'x' } : null);
    if (name === 'admin_group_confirmation_window') return Response.json(confirmed ? { event_id: eventId }
      : { starts_at: payload.starts_at, ends_at: payload.ends_at });
    if (name === 'admin_confirm_group_event_checked') {
      if (!isAdmin) return Response.json({ code: 'P0001', message: 'NOT_ADMIN' }, { status: 400 });
      return Response.json({ event_id: eventId, created: true });
    }
    if (name === 'event_calendar_payload') return Response.json({ ...payload, google_event_id: alreadySynced ? 'x'.repeat(32) : null });
    return Response.json({ ok: true });
  };
  return { calls, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
    google: withEventsCalendar ? google : { ...google, eventsCalendarId: undefined }, fetcher } };
}
const post = (path, body) => new Request(`https://x/functions/v1/api${path}`, { method: 'POST',
  headers: { Authorization: `Bearer ${session}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body ?? {}) });
const confirmBody = { gameId: null, priceTwd: 650, venue: '海星劇本殺', dmName: '店長' };

test('confirming writes one calendar event with a stable ID and marks it synced', async () => {
  const { calls, settings } = backend();
  const response = await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), settings);
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), { eventId, calendarSynced: true });
  const confirm = JSON.parse(calls.find(c => c.url.endsWith('/admin_confirm_group_event_checked')).body);
  assert.equal(confirm.p_price_cents, 65000);
  assert.equal(confirm.p_actor, 'owner');
  const busyRead = calls.findIndex(c => c.url.endsWith('/freeBusy'));
  const busySync = calls.findIndex(c => c.url.endsWith('/sync_calendar_busy'));
  const committed = calls.findIndex(c => c.url.endsWith('/admin_confirm_group_event_checked'));
  assert.ok(busyRead >= 0 && busyRead < busySync && busySync < committed);
  assert.equal(confirm.p_starts_at, payload.starts_at);
  assert.equal(confirm.p_ends_at, payload.ends_at);
  assert.deepEqual(JSON.parse(calls[busyRead].body), { timeMin: new Date(payload.starts_at).toISOString(),
    timeMax: new Date(payload.ends_at).toISOString(), items: [{ id: google.calendarId }] });
  const write = calls.find(c => c.url.includes('/calendar/v3/calendars/'));
  assert.ok(write.url.includes(encodeURIComponent(google.eventsCalendarId)), 'writes only to the store calendar');
  assert.ok(!write.url.includes(encodeURIComponent(google.calendarId)), 'never writes to the owner calendar');
  const event = JSON.parse(write.body);
  assert.equal(event.id, eventId.replace(/-/g, ''));
  assert.match(event.id, /^[a-v0-9]{5,}$/);
  assert.equal(event.summary, '【海星】王座（7人）');
  assert.deepEqual(event.start, { dateTime: payload.starts_at, timeZone: 'Asia/Taipei' });
  assert.ok(event.description.includes('每人：NT$650') && event.description.includes('阿明、涵涵'));
  const mark = JSON.parse(calls.find(c => c.url.endsWith('/mark_event_calendar_synced')).body);
  assert.equal(mark.p_google_event_id, event.id);
});

test('free/busy or Outlook failure stops confirmation before any event is committed', async () => {
  for (const failure of ['google', 'outlook', 'unset']) {
    const run = backend({ busyStatus: failure === 'google' ? 503 : 200 });
    if (failure === 'unset') delete run.settings.google;
    if (failure === 'outlook') {
      run.settings.icsUrls = ['https://outlook.invalid/busy.ics'];
      const base = run.settings.fetcher;
      run.settings.fetcher = (url, opts) => url === run.settings.icsUrls[0]
        ? Promise.resolve(new Response('offline', { status: 503 })) : base(url, opts);
    }
    const res = await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), run.settings);
    assert.equal(res.status, 503, failure);
    assert.ok(!run.calls.some(c => c.url.endsWith('/admin_confirm_group_event_checked')), failure);
    assert.ok(!run.calls.some(c => c.url.includes('/calendar/v3/calendars/')), failure);
  }
});

test('confirmation always refreshes free/busy; confirmed retries skip the read during an outage', async () => {
  const live = backend();
  for (let i = 0; i < 2; i++) assert.equal((await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), live.settings)).status, 201);
  assert.equal(live.calls.filter(c => c.url.endsWith('/freeBusy')).length, 2);
  const retry = backend({ confirmed: true, alreadySynced: true, busyStatus: 503 });
  const res = await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), retry.settings);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { eventId, calendarSynced: true });
  assert.ok(!retry.calls.some(c => c.url.endsWith('/freeBusy') || c.url.endsWith('/admin_confirm_group_event_checked')));
});

test('a retry after a partial failure is idempotent; Google 409 counts as already written', async () => {
  const dup = backend({ googleStatus: 409 });
  const res = await handleApi(post(`/admin/events/${eventId}/calendar`), dup.settings);
  assert.deepEqual(await res.json(), { calendarSynced: true });
  const synced = backend({ alreadySynced: true });
  assert.deepEqual(await (await handleApi(post(`/admin/events/${eventId}/calendar`), synced.settings)).json(), { calendarSynced: true });
  assert.ok(!synced.calls.some(c => c.url.includes('/calendar/v3/')), 'no second write when already synced');
});

test('calendar problems never undo the confirmation; they are reported for retry', async () => {
  const failing = backend({ googleStatus: 403 });
  const res = await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), failing.settings);
  assert.equal(res.status, 201);
  assert.deepEqual(await res.json(), { eventId, calendarSynced: false, calendarError: 'CALENDAR_WRITE_FAILED' });
  assert.ok(!failing.calls.some(c => c.url.endsWith('/mark_event_calendar_synced')));
  const unset = backend({ withEventsCalendar: false });
  assert.deepEqual(await (await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), unset.settings)).json(),
    { eventId, calendarSynced: false, calendarError: 'CALENDAR_WRITE_NOT_CONFIGURED' });
});

test('only admins confirm or retry; price must be a whole amount', async () => {
  const player = backend({ isAdmin: false });
  assert.equal((await handleApi(post(`/admin/groups/${groupId}/confirm`, confirmBody), player.settings)).status, 403);
  assert.equal((await handleApi(post(`/admin/events/${eventId}/calendar`), player.settings)).status, 403);
  assert.ok(!player.calls.some(c => c.url.includes('/calendar/v3/')));
  const { settings } = backend();
  for (const priceTwd of [-1, 12.5, 'abc', null, 100001]) {
    assert.equal((await handleApi(post(`/admin/groups/${groupId}/confirm`, { ...confirmBody, priceTwd }), settings)).status, 400);
  }
});

test('cancelling removes the calendar entry; gone entries count as removed; failures are retryable', async () => {
  const run = async ({ googleStatus = 204, removed = false, synced = true } = {}) => {
    const calls = [];
    const fetcher = async (url, opts = {}) => {
      calls.push({ url, method: opts.method, body: opts.body });
      if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'g', expires_in: 3600 });
      if (url.startsWith('https://www.googleapis.com/calendar/v3/calendars/')) return new Response(null, { status: googleStatus });
      const name = url.split('/rpc/')[1];
      const args = JSON.parse(opts.body);
      if (name === 'resolve_session') return Response.json(args.p_session_hash === await sha256Hex(session)
        ? { user_id: 'owner', display_name: '店長', is_admin: true, expires_at: 'x' } : null);
      if (name === 'admin_cancel_event') return Response.json({ cancelled: true, event_id: eventId, refund_required: true });
      if (name === 'event_calendar_payload') return Response.json({ ...payload, status: 'cancelled',
        google_event_id: synced ? eventId.replace(/-/g, '') : null, calendar_removed: removed });
      return Response.json({ ok: true });
    };
    const settings = { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [], google, fetcher };
    const res = await handleApi(post(`/admin/events/${eventId}/cancel`, { reason: 'DM 生病' }), settings);
    return { status: res.status, data: await res.json(), calls };
  };
  const ok = await run();
  assert.deepEqual([ok.status, ok.data], [200, { cancelled: true, refundRequired: true, calendarRemoved: true }]);
  const del = ok.calls.find(c => c.method === 'DELETE');
  assert.ok(del.url.endsWith(`/events/${eventId.replace(/-/g, '')}`));
  assert.ok(del.url.includes(encodeURIComponent(google.eventsCalendarId)) && !del.url.includes(encodeURIComponent(google.calendarId)));
  assert.equal(JSON.parse(ok.calls.find(c => c.url.endsWith('/admin_cancel_event')).body).p_reason, 'DM 生病');
  for (const googleStatus of [404, 410]) assert.equal((await run({ googleStatus })).data.calendarRemoved, true);
  const failed = await run({ googleStatus: 500 });
  assert.deepEqual(failed.data, { cancelled: true, refundRequired: true, calendarRemoved: false, calendarError: 'CALENDAR_REMOVE_FAILED' });
  assert.ok(!failed.calls.some(c => c.url.endsWith('/mark_event_calendar_removed')));
  for (const opts of [{ removed: true }, { synced: false }]) {
    const skip = await run(opts);
    assert.equal(skip.data.calendarRemoved, true);
    assert.ok(!skip.calls.some(c => c.method === 'DELETE'), 'nothing to delete');
  }
});
