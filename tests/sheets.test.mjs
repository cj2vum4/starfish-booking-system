import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { handleApi, reportToSheets, sha256Hex } from '../supabase/functions/api/index.ts';

const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const google = { clientEmail: 'sa@test.iam.gserviceaccount.com', calendarId: 'owner@example.com', sheetId: 'SHEET123',
  privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const session = 'S'.repeat(43);
const report = {
  sessions: [{ event_id: 'e1', starts_at: '2026-10-10T05:00:00+00:00', ends_at: '2026-10-10T09:00:00+00:00', title: '王座',
    source: '揪團', organizer: '阿明', status: 'completed', capacity: 7, booked: 7, attended: 6, absent: 1,
    venue: '南港', dm_name: '海星', price_cents: 40000, cancel_reason: null }],
  attendance: [{ event_id: 'e1', starts_at: '2026-10-10T05:00:00+00:00', title: '王座', player: '=HYPERLINK("x")',
    has_line: false, status: 'completed', attendance: 'attended' }],
  players: [{ player: '阿明', has_line: true, oa_friend: 'active', played: 3, last_played: '2026-10-10T05:00:00+00:00', joined_at: '2026-10-02T08:00:00+00:00' }],
};

test('report rows are Taipei-timed, in Chinese, with prices in NT$', () => {
  const t = reportToSheets(report);
  assert.deepEqual(Object.keys(t), ['場次', '出席', '玩家']);
  assert.deepEqual(t['場次'][1].slice(0, 10), ['2026-10-10 13:00', '2026-10-10 17:00', '王座', '揪團', '阿明', '已結束', 7, 7, 6, 1]);
  assert.equal(t['場次'][1][12], 400);
  assert.deepEqual(t['出席'][1].slice(2), ['=HYPERLINK("x")', '否', 'completed', '出席']);
  assert.deepEqual(t['玩家'][1].slice(0, 4), ['阿明', '是', '是', 3]);
});

function backend({ isAdmin = true, sheetStatus = 200, tabs = ['場次'], sheetId = 'SHEET123' } = {}) {
  const calls = [];
  const fetcher = async (url, opts = {}) => {
    let body = null;
    try { body = opts.body ? JSON.parse(opts.body) : null; } catch { body = opts.body; }  // token request is form-encoded
    calls.push({ url, method: opts.method, body });
    if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'g', expires_in: 3600 });
    if (url.startsWith('https://sheets.googleapis.com/')) {
      if (sheetStatus !== 200) return new Response('{}', { status: sheetStatus });
      if (url.includes('?fields=')) return Response.json({ sheets: tabs.map(title => ({ properties: { title } })) });
      return Response.json({});
    }
    const name = url.split('/rpc/')[1];
    if (name === 'resolve_session') return Response.json(JSON.parse(opts.body).p_session_hash === await sha256Hex(session)
      ? { user_id: 'owner', display_name: '店長', is_admin: isAdmin, expires_at: 'x' } : null);
    if (name === 'admin_report') return Response.json(report);
    return Response.json({});
  };
  return { calls, settings: { loginChannelId: '1', supabaseUrl: 'https://db.invalid', serviceKey: 'k', allowedOrigins: [],
    google: { ...google, sheetId }, fetcher } };
}
const exportReq = () => new Request('https://x/functions/v1/api/admin/sheets/export',
  { method: 'POST', headers: { Authorization: `Bearer ${session}` } });

test('export creates missing tabs, clears, then writes RAW values to the configured sheet', async () => {
  const { calls, settings } = backend();
  const res = await handleApi(exportReq(), settings);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { sessions: 1, attendance: 1, players: 1, url: 'https://docs.google.com/spreadsheets/d/SHEET123' });
  const sheetCalls = calls.filter(c => c.url.startsWith('https://sheets.googleapis.com/'));
  assert.ok(sheetCalls.every(c => c.url.includes('/spreadsheets/SHEET123')));
  const add = sheetCalls.find(c => c.url.endsWith(':batchUpdate'));
  assert.deepEqual(add.body.requests.map(r => r.addSheet.properties.title), ['出席', '玩家']);
  const write = sheetCalls.find(c => c.url.endsWith('/values:batchUpdate'));
  assert.equal(write.body.valueInputOption, 'RAW', 'formula-looking names must stay text');
  assert.deepEqual(write.body.data.map(d => d.range), ["'場次'!A1", "'出席'!A1", "'玩家'!A1"]);
  const order = sheetCalls.map(c => c.url.replace(/^.*SHEET123/, ''));
  assert.deepEqual(order, ['?fields=sheets.properties.title', ':batchUpdate', '/values:batchClear', '/values:batchUpdate']);
});

test('export: admin only, clear errors for an unshared or unconfigured sheet', async () => {
  assert.equal((await handleApi(exportReq(), backend({ isAdmin: false }).settings)).status, 403);
  const unshared = await handleApi(exportReq(), backend({ sheetStatus: 403 }).settings);
  assert.deepEqual([unshared.status, await unshared.json()], [503, { error: 'SHEET_NOT_SHARED' }]);
  const unset = await handleApi(exportReq(), backend({ sheetId: null }).settings);
  assert.deepEqual(await unset.json(), { error: 'SHEETS_NOT_CONFIGURED' });
});
