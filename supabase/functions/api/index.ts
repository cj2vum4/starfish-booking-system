// No external runtime dependencies. Shared by Supabase Deno and Node 24 tests.
type Settings = {
  loginChannelId?: string;
  supabaseUrl?: string;
  serviceKey?: string;
  allowedOrigins?: string[];
  // Google service account: "See only free/busy" on the owner's calendar (calendarId) and
  // "Make changes to events" on a dedicated store calendar (eventsCalendarId).
  google?: { clientEmail: string; privateKey: string; calendarId: string; eventsCalendarId?: string; projectId?: string };
  icsUrls?: string[];  // published busy calendars, e.g. the owner's Outlook (capability URLs: keep secret)
  catalogUrl?: string;  // raw scripts.js in the Starfish site repo
  catalogSiteBase?: string;  // where that repo's pages are published
  catalogCommitUrl?: string;  // raw file URL template with {commit}, for the GitHub hook
  catalogSyncSecret?: string;  // shared with the starfishlarp GitHub Action
  lineAccessToken?: string;  // Messaging API channel access token, for push notifications
  adminLineAccessToken?: string;  // the store's own OA: store notifications use its separate free quota
  liffId?: string;  // links in notifications open this LIFF app
  richMenuImageUrls?: Record<string, string>;
  // The website's 玩本記錄 Apps Script: public summary (points) and the secret-protected 回歸禮.
  playRecordUrl?: string;
  playRecordSecret?: string;  // shared with the Apps Script property BOOKING_SECRET
  roleSurveySheetId?: string;  // the old 角色問卷總表, imported once (defaults to the known sheet)
  playRecordSheetId?: string;  // the 玩本記錄 spreadsheet behind the Apps Script (defaults to the known sheet)
  background?: (work: Promise<unknown>) => void;  // run after the response (EdgeRuntime.waitUntil)
  fetcher?: typeof fetch;
  now?: () => number;
};
type Session = { user_id: string; display_name: string | null; is_admin: boolean; expires_at: string };
const SESSION_HOURS = 12;
const MAX_BODY = 64 * 1024;

class ApiError extends Error {
  status: number;
  missing = false;  // PostgREST has no such function (a migration not applied yet)
  constructor(status: number, code: string) { super(code); this.status = status; }
}

// Stable RPC error codes → HTTP status. Unknown database errors stay opaque (500).
const NOT_FOUND = /_NOT_FOUND$/;
const CONFLICT = new Set(['IDENTITY_MERGE_REQUIRED', 'NAME_EXISTS', 'BINDING_PENDING', 'NAME_TAKEN', 'ALREADY_BOUND', 'BINDING_DECIDED',
  'SOLD_OUT', 'GROUP_FULL', 'ALREADY_BOOKED', 'ALREADY_MEMBER', 'ALREADY_CLAIMED',
  'INVITE_USED', 'GROUP_CLOSED', 'GROUP_CONFIRMED', 'EVENT_CLOSED', 'EVENT_STARTED', 'ORGANIZER_CANNOT_LEAVE',
  'RECORDS_LIVE', 'RECORDS_WENT_LIVE', 'IMPORT_REQUIRED', 'RECONCILE_MISMATCH', 'RECONCILE_STALE', 'LEDGER_APPEND_ONLY',
  'NOT_ENOUGH_POINTS', 'REDEMPTION_DECIDED', 'LEDGER_VOIDED', 'RECORD_HIDDEN', 'RECORD_NOT_HIDDEN', 'ALIAS_TAKEN', 'NAME_IS_PLAYER',
  'SAME_PLAYER']);
export function statusForCode(code: string) {
  if (NOT_FOUND.test(code)) return 404;
  if (CONFLICT.has(code)) return 409;
  if (code === 'NOT_ADMIN' || code === 'NOT_FRIEND') return 403;
  if (code === 'TOO_MANY_REQUESTS') return 429;
  if (code === 'RECORDS_NOT_LIVE') return 503;  // the website then uses the Apps Script, as before the cutover
  return 400;
}

function corsHeaders(req: Request, settings: Settings): Record<string, string> {
  const origin = req.headers.get('origin');
  if (!origin || !(settings.allowedOrigins ?? []).includes(origin)) return {};
  return { 'Access-Control-Allow-Origin': origin, Vary: 'Origin',
    'Access-Control-Allow-Headers': 'authorization, content-type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS', 'Access-Control-Max-Age': '600' };
}

const toHex = (bytes: ArrayBuffer) => [...new Uint8Array(bytes)].map(b => b.toString(16).padStart(2, '0')).join('');
export async function sha256Hex(value: string) {
  return toHex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
}
function newToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function readJson(req: Request, max = MAX_BODY): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > max) throw new ApiError(413, 'INVALID_BODY_SIZE');
  try {
    const data = JSON.parse(text || '{}');
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
    return data;
  } catch { throw new ApiError(400, 'INVALID_JSON'); }
}

async function rpc<T>(settings: Settings, name: string, args: Record<string, unknown>, timeoutMs = 8000): Promise<T> {
  let response: Response;
  try {
    response = await (settings.fetcher ?? fetch)(`${settings.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST', signal: AbortSignal.timeout(timeoutMs),
      headers: { 'Content-Type': 'application/json', apikey: settings.serviceKey!,
        Authorization: `Bearer ${settings.serviceKey}` },
      body: JSON.stringify(args),
    });
  } catch { throw new ApiError(503, 'DATABASE_UNAVAILABLE'); }
  const data = await response.json().catch(() => null);
  if (response.ok) return data as T;
  // Business rules raise P0001 with a stable code; never forward other database details.
  if (data?.code === 'P0001' && /^[A-Z_]{3,40}$/.test(data.message ?? '')) {
    throw new ApiError(statusForCode(data.message), data.message);
  }
  const error = new ApiError(500, 'DATABASE_ERROR');
  error.missing = response.status === 404;  // /rest/v1/rpc answers 404 (PGRST202) only for a function that does not exist
  // For the Edge Function logs: which function and which PostgreSQL/PostgREST code (42501, 57014…), never the data.
  console.error(JSON.stringify({ rpc: name, status: response.status, code: typeof data?.code === 'string' ? data.code : null }));
  throw error;
}

// Opening, joining or claiming a seat requires OA friendship so the player can be notified.
// The stored status comes from webhooks; when it is not active we ask LINE directly, because
// players who added the OA before the webhook existed were never recorded. If LINE itself is
// unreachable we let the action through: notifications are a convenience, not a safety rule.
async function requireFriend(settings: Settings, userId: string) {
  if (!settings.lineAccessToken) return;
  const me = await rpc<{ line_user_id: string; oa_friend_status: string } | null>(settings, 'user_line_identity',
    { p_user_id: userId });
  if (!me || me.oa_friend_status === 'active') return;
  let response: Response;
  try {
    response = await (settings.fetcher ?? fetch)(
      `https://api.line.me/v2/bot/profile/${encodeURIComponent(me.line_user_id)}`, {
        signal: AbortSignal.timeout(5000), headers: { Authorization: `Bearer ${settings.lineAccessToken}` } });
  } catch { return; }
  if (response.ok) { await rpc(settings, 'mark_user_followed', { p_user_id: userId }); return; }
  if (response.status === 404) throw new ApiError(403, 'NOT_FRIEND');
}

// LINE verifies signature, audience and expiry; we re-check the claims we rely on.
async function verifyIdToken(idToken: string, settings: Settings) {
  let response: Response;
  try {
    response = await (settings.fetcher ?? fetch)('https://api.line.me/oauth2/v2.1/verify', {
      method: 'POST', signal: AbortSignal.timeout(8000),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ id_token: idToken, client_id: settings.loginChannelId! }).toString(),
    });
  } catch { throw new ApiError(503, 'LINE_UNAVAILABLE'); }
  if (!response.ok) throw new ApiError(401, 'INVALID_ID_TOKEN');
  const claims = await response.json().catch(() => null);
  const now = (settings.now ?? Date.now)() / 1000;
  if (!claims || claims.iss !== 'https://access.line.me' || claims.aud !== settings.loginChannelId ||
      typeof claims.sub !== 'string' || !/^U[0-9a-f]{32}$/.test(claims.sub) ||
      typeof claims.exp !== 'number' || claims.exp <= now) {
    throw new ApiError(401, 'INVALID_ID_TOKEN');
  }
  return { userId: claims.sub as string, name: typeof claims.name === 'string' ? claims.name : null };
}

async function requireSession(req: Request, settings: Settings) {
  const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(req.headers.get('authorization') ?? '');
  if (!match) throw new ApiError(401, 'UNAUTHENTICATED');
  const hash = await sha256Hex(match[1]);
  const session = await rpc<Session | null>(settings, 'resolve_session', { p_session_hash: hash });
  if (!session) throw new ApiError(401, 'UNAUTHENTICATED');
  return { session, hash };
}

// --- Published calendars (.ics, e.g. Outlook) ---------------------------------------
// Only busy intervals are extracted; titles and details are never kept. Free and
// "show as available" items are skipped; tentative counts as busy. Recurrences are
// expanded in local wall time; unsupported rules fail closed rather than guess.
type IcsProp = { name: string; params: Record<string, string>; value: string };
type Busy = { start: string; end: string };
const ICS_MAX_OCCURRENCES = 5000;

function unfoldIcs(text: string) {
  return text.replace(/\r\n/g, '\n').replace(/\n[ \t]/g, '').split('\n');
}
function parseIcsLine(line: string): IcsProp | null {
  const colon = line.indexOf(':');
  if (colon < 0) return null;
  const [name, ...rest] = line.slice(0, colon).split(';');
  const params: Record<string, string> = {};
  for (const p of rest) { const eq = p.indexOf('='); if (eq > 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1).replace(/^"|"$/g, ''); }
  return { name: name.toUpperCase(), params, value: line.slice(colon + 1) };
}
// Minutes east of UTC for a TZID: from its VTIMEZONE STANDARD offset, Taipei by default.
function tzOffsets(lines: string[]) {
  const map: Record<string, number> = {};
  let tzid = '', inStandard = false;
  for (const line of lines) {
    if (line.startsWith('TZID:')) tzid = line.slice(5);
    else if (line === 'BEGIN:STANDARD') inStandard = true;
    else if (line === 'END:STANDARD') inStandard = false;
    else if (inStandard && line.startsWith('TZOFFSETTO:')) {
      const m = /^([+-])(\d{2})(\d{2})$/.exec(line.slice(11));
      if (m && tzid) map[tzid] = (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
    }
  }
  return map;
}
// A wall-clock instant kept as "local milliseconds" plus the zone offset in minutes.
type Local = { ms: number; offset: number; allDay: boolean };
function icsTime(prop: IcsProp, zones: Record<string, number>): Local {
  const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(prop.value.trim());
  if (!m) throw new Error('ICS_UNSUPPORTED');
  const ms = Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0), +(m[6] ?? 0));
  const tz = prop.params.TZID;
  const offset = m[7] ? 0 : tz && /taipei/i.test(tz) ? 480 : tz && zones[tz] != null ? zones[tz] : 480;
  return { ms, offset, allDay: !m[4] };
}
const toIso = (t: Local) => new Date(t.ms - t.offset * 60000).toISOString();
function icsDuration(value: string) {
  const m = /^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/.exec(value.trim());
  if (!m) throw new Error('ICS_UNSUPPORTED');
  return ((+(m[1] ?? 0) * 7 + +(m[2] ?? 0)) * 86400 + +(m[3] ?? 0) * 3600 + +(m[4] ?? 0) * 60 + +(m[5] ?? 0)) * 1000;
}
const WEEKDAYS = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
const DAY = 86400000;
// The nth (1-based, negative from the end) given weekday of a month, as local midnight ms.
function nthWeekday(year: number, month: number, weekday: number, n: number) {
  const days = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const matches = [];
  for (let d = 1; d <= days; d++) if (new Date(Date.UTC(year, month, d)).getUTCDay() === weekday) matches.push(d);
  const day = n > 0 ? matches[n - 1] : matches[matches.length + n];
  return day ? Date.UTC(year, month, day) : null;
}
// Occurrence starts (local ms) of a recurring event, ascending, up to untilLocal.
function expandRule(rule: string, start: Local, fromLocal: number, horizon: number): number[] {
  const parts: Record<string, string> = Object.fromEntries(rule.split(';').map(p => p.split('=') as [string, string]));
  const allowed = new Set(['FREQ', 'INTERVAL', 'COUNT', 'UNTIL', 'BYDAY', 'BYMONTHDAY', 'WKST']);
  if (Object.keys(parts).some(k => !allowed.has(k))) throw new Error('ICS_UNSUPPORTED');
  const interval = Number(parts.INTERVAL ?? 1);
  const count = parts.COUNT ? Number(parts.COUNT) : Infinity;
  let until = horizon;
  if (parts.UNTIL) {
    const u = icsTime({ name: 'UNTIL', params: {}, value: parts.UNTIL }, {});
    // UNTIL in UTC (Z) is converted to the event's local wall time.
    until = Math.min(until, parts.UNTIL.endsWith('Z') ? u.ms + start.offset * 60000 : u.ms + (u.allDay ? DAY - 1 : 0));
  }
  const timeOfDay = start.ms % DAY;
  const out: number[] = [];
  const push = (ms: number) => { if (ms >= start.ms && ms <= until && out.length < count) out.push(ms); };
  const d0 = new Date(start.ms);
  const byday = (parts.BYDAY ?? '').split(',').filter(Boolean).map(s => {
    const m = /^([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)$/.exec(s);
    if (!m) throw new Error('ICS_UNSUPPORTED');
    return { n: m[1] ? Number(m[1]) : 0, wd: WEEKDAYS.indexOf(m[2]) };
  });
  // Without COUNT, skip whole periods before the window (estimates err early, never late).
  const periodDays = { DAILY: 1, WEEKLY: 7, MONTHLY: 31, YEARLY: 366 }[parts.FREQ] ?? 1;
  let first = 0;
  if (count === Infinity && fromLocal > start.ms) {
    first = Math.max(0, Math.floor((fromLocal - start.ms) / (periodDays * DAY)) - 2);
    if (parts.FREQ === 'MONTHLY' || parts.FREQ === 'YEARLY') first = Math.max(0, first - 1);
    first -= first % interval;
  }
  let guard = 0;
  for (let i = first; out.length < count; i += interval) {
    if (++guard > ICS_MAX_OCCURRENCES) throw new Error('ICS_UNSUPPORTED');
    if (parts.FREQ === 'DAILY') {
      const ms = start.ms + i * DAY;
      if (ms > until) break;
      if (!byday.length || byday.some(b => b.wd === new Date(ms).getUTCDay())) push(ms);
    } else if (parts.FREQ === 'WEEKLY') {
      const wkst = WEEKDAYS.indexOf(parts.WKST ?? 'MO');
      const weekStart = start.ms - timeOfDay - ((d0.getUTCDay() - wkst + 7) % 7) * DAY + i * 7 * DAY;
      if (weekStart > until) break;
      const days = byday.length ? byday.map(b => b.wd) : [d0.getUTCDay()];
      for (const wd of [...days].sort((a, b) => ((a - wkst + 7) % 7) - ((b - wkst + 7) % 7))) {
        push(weekStart + ((wd - wkst + 7) % 7) * DAY + timeOfDay);
      }
    } else if (parts.FREQ === 'MONTHLY' || parts.FREQ === 'YEARLY') {
      const months = parts.FREQ === 'MONTHLY' ? i : i * 12;
      const y = d0.getUTCFullYear() + Math.floor((d0.getUTCMonth() + months) / 12);
      const mo = (d0.getUTCMonth() + months) % 12;
      if (Date.UTC(y, mo, 1) > until) break;
      const candidates: number[] = [];
      if (byday.length) {
        for (const b of byday) {
          if (!b.n) throw new Error('ICS_UNSUPPORTED');
          const day = nthWeekday(y, mo, b.wd, b.n);
          if (day != null) candidates.push(day + timeOfDay);
        }
      } else {
        const days = parts.BYMONTHDAY ? parts.BYMONTHDAY.split(',').map(Number) : [d0.getUTCDate()];
        const len = new Date(Date.UTC(y, mo + 1, 0)).getUTCDate();
        for (const d of days) { const day = d < 0 ? len + d + 1 : d; if (day >= 1 && day <= len) candidates.push(Date.UTC(y, mo, day) + timeOfDay); }
      }
      candidates.sort((a, b) => a - b).forEach(push);
    } else throw new Error('ICS_UNSUPPORTED');
  }
  return out;
}

export function parseIcsBusy(text: string, from: Date, to: Date): Busy[] {
  if (!/BEGIN:VCALENDAR/.test(text)) throw new Error('ICS_UNREADABLE');
  const lines = unfoldIcs(text);
  const zones = tzOffsets(lines);
  const events: IcsProp[][] = [];
  let current: IcsProp[] | null = null, depth = 0;
  for (const line of lines) {
    if (line === 'BEGIN:VEVENT') { current = []; depth = 0; continue; }
    if (line === 'END:VEVENT') { if (current) events.push(current); current = null; continue; }
    if (!current) continue;
    if (line.startsWith('BEGIN:')) { depth++; continue; }   // e.g. VALARM
    if (line.startsWith('END:')) { depth--; continue; }
    if (depth === 0) { const p = parseIcsLine(line); if (p) current.push(p); }
  }
  const get = (e: IcsProp[], n: string) => e.find(p => p.name === n);
  // Single-instance overrides replace the matching occurrence of their series.
  const overridden = new Set<string>();
  for (const e of events) {
    const rid = get(e, 'RECURRENCE-ID'); const uid = get(e, 'UID')?.value;
    if (rid && uid) overridden.add(`${uid}|${toIso(icsTime(rid, zones))}`);
  }
  const fromMs = from.getTime(), toMs = to.getTime();
  const busy: Busy[] = [];
  for (const e of events) {
    const status = get(e, 'STATUS')?.value.toUpperCase();
    const transp = get(e, 'TRANSP')?.value.toUpperCase();
    const show = get(e, 'X-MICROSOFT-CDO-BUSYSTATUS')?.value.toUpperCase();
    if (status === 'CANCELLED' || transp === 'TRANSPARENT' || show === 'FREE') continue;
    const dtstart = get(e, 'DTSTART');
    if (!dtstart) continue;
    const start = icsTime(dtstart, zones);
    const dtend = get(e, 'DTEND'), duration = get(e, 'DURATION');
    const length = dtend ? icsTime(dtend, zones).ms - start.ms : duration ? icsDuration(duration.value) : start.allDay ? DAY : 0;
    if (length <= 0) continue;
    const rule = get(e, 'RRULE')?.value;
    const isOverride = !!get(e, 'RECURRENCE-ID');
    const uid = get(e, 'UID')?.value ?? '';
    const excluded = new Set(e.filter(p => p.name === 'EXDATE').flatMap(p =>
      p.value.split(',').map(v => toIso(icsTime({ ...p, value: v }, zones)))));
    // Expand far enough (in local time) to cover the window.
    const horizon = toMs + start.offset * 60000;
    const starts = rule && !isOverride ? expandRule(rule, start, fromMs + start.offset * 60000 - length, horizon) : [start.ms];
    for (const ms of starts) {
      const occurrence = { ...start, ms };
      const iso = toIso(occurrence);
      if (excluded.has(iso) || (!isOverride && rule && overridden.has(`${uid}|${iso}`))) continue;
      const s = ms - start.offset * 60000, en = s + length;
      if (en > fromMs && s < toMs) busy.push({ start: new Date(Math.max(s, fromMs)).toISOString(), end: new Date(Math.min(en, toMs)).toISOString() });
    }
  }
  return busy;
}

const ICS_CACHE_MS = 5 * 60 * 1000;  // Outlook republishes slowly; avoid a 0.5 MB download per request
const icsCache = new Map<string, { at: number; text: string }>();
async function icsBusy(settings: Settings, from: Date, to: Date) {
  const busy: Busy[] = [];
  for (const url of settings.icsUrls ?? []) {
    const now = (settings.now ?? Date.now)();
    let cached = icsCache.get(url);
    if (!cached || now - cached.at > ICS_CACHE_MS) {
      const response = await (settings.fetcher ?? fetch)(url, { signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error('ICS_UNAVAILABLE');
      cached = { at: now, text: await response.text() };
      icsCache.set(url, cached);
    }
    busy.push(...parseIcsBusy(cached.text, from, to));
  }
  return busy;
}

// --- Google Calendar free/busy -------------------------------------------------------
const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const b64urlJson = (value: unknown) => b64url(new TextEncoder().encode(JSON.stringify(value)));
let googleToken: { value: string; expires: number; email: string } | null = null;

async function googleAccessToken(settings: Settings) {
  const google = settings.google!;
  const now = Math.floor((settings.now ?? Date.now)() / 1000);
  if (googleToken && googleToken.email === google.clientEmail && googleToken.expires > now + 60) return googleToken.value;
  const pem = google.privateKey.replace(/-----[A-Z ]+-----|\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const unsigned = `${b64urlJson({ alg: 'RS256', typ: 'JWT' })}.${b64urlJson({ iss: google.clientEmail,
    scope: 'https://www.googleapis.com/auth/calendar.freebusy https://www.googleapis.com/auth/calendar.events'
      + ' https://www.googleapis.com/auth/spreadsheets.readonly',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now, exp: now + 3600 })}`;
  const signature = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)));
  const response = await (settings.fetcher ?? fetch)('https://oauth2.googleapis.com/token', {
    method: 'POST', signal: AbortSignal.timeout(8000),
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${b64url(signature)}` }).toString(),
  });
  const data = await response.json().catch(() => null);
  if (!response.ok || typeof data?.access_token !== 'string') throw new Error('google_token');
  googleToken = { value: data.access_token, expires: now + (data.expires_in ?? 3600), email: google.clientEmail };
  return googleToken.value;
}

// Refreshes the mirrored busy periods for [from, to) straight from Google. Any failure
// fails closed: without fresh calendar data nothing is offered or reserved.
// Listings may reuse a sync of a covering window from the last minute (protects the Google
// quota from request floods); reservations always pass maxAgeMs 0 and sync live.
const LISTING_SYNC_MAX_AGE_MS = 60 * 1000;
let lastSync: { from: number; to: number; at: number } | null = null;
async function syncCalendar(settings: Settings, from: Date, to: Date, maxAgeMs = 0) {
  if (!settings.google) throw new ApiError(503, 'CALENDAR_NOT_CONFIGURED');
  const now = (settings.now ?? Date.now)();
  if (maxAgeMs > 0 && lastSync && now - lastSync.at < maxAgeMs
      && lastSync.from <= from.getTime() && lastSync.to >= to.getTime()) return;
  let busy: { start: string; end: string }[];
  try {
    const token = await googleAccessToken(settings);
    const response = await (settings.fetcher ?? fetch)('https://www.googleapis.com/calendar/v3/freeBusy', {
      method: 'POST', signal: AbortSignal.timeout(8000),
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ timeMin: from.toISOString(), timeMax: to.toISOString(),
        items: [{ id: settings.google.calendarId }] }),
    });
    const data = await response.json().catch(() => null);
    const calendar = data?.calendars?.[settings.google.calendarId];
    if (!response.ok || !calendar || calendar.errors?.length || !Array.isArray(calendar.busy)) throw new Error('freebusy');
    busy = calendar.busy.map((b: { start: string; end: string }) => ({ start: b.start, end: b.end }));
    busy.push(...await icsBusy(settings, from, to));
  } catch { throw new ApiError(503, 'CALENDAR_UNAVAILABLE'); }
  await rpc(settings, 'sync_calendar_busy', { p_from: from.toISOString(), p_to: to.toISOString(), p_busy: busy });
  lastSync = { from: from.getTime(), to: to.getTime(), at: now };
}

// Setup check: says which step is wrong, never returns busy times or writes anything.
async function checkCalendar(settings: Settings): Promise<[number, unknown]> {
  if (!settings.google) return [503, { ok: false, error: 'CALENDAR_NOT_CONFIGURED' }];
  let token: string;
  try { token = await googleAccessToken(settings); }
  catch { return [503, { ok: false, error: 'GOOGLE_KEY_INVALID' }]; }
  const nowMs = (settings.now ?? Date.now)();
  try {
    const response = await (settings.fetcher ?? fetch)('https://www.googleapis.com/calendar/v3/freeBusy', {
      method: 'POST', signal: AbortSignal.timeout(8000),
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ timeMin: new Date(nowMs).toISOString(), timeMax: new Date(nowMs + 86400000).toISOString(),
        items: [{ id: settings.google.calendarId }] }),
    });
    const data = await response.json().catch(() => null);
    if (response.status === 403) return [503, { ok: false, error: 'CALENDAR_API_DISABLED' }];
    const calendar = data?.calendars?.[settings.google.calendarId];
    if (!response.ok || !calendar) return [503, { ok: false, error: 'CALENDAR_UNAVAILABLE' }];
    if (calendar.errors?.length) return [503, { ok: false, error: 'CALENDAR_NOT_SHARED' }];
    try { await icsBusy(settings, new Date(nowMs), new Date(nowMs + 86400000)); }
    catch (error) {
      return [503, { ok: false, error: (error as Error).message === 'ICS_UNSUPPORTED' ? 'OUTLOOK_UNSUPPORTED' : 'OUTLOOK_UNAVAILABLE' }];
    }
    return [200, { ok: true, publishedCalendars: settings.icsUrls?.length ?? 0 }];
  } catch { return [503, { ok: false, error: 'CALENDAR_UNAVAILABLE' }]; }
}

// Writes a confirmed session to the store calendar. The Google event ID is derived from our
// event ID, so retries never create duplicates. Returns whether the calendar is up to date.
async function writeCalendarEvent(settings: Settings, eventId: string) {
  const calendarId = settings.google?.eventsCalendarId;
  if (!settings.google || !calendarId) return { calendarSynced: false, calendarError: 'CALENDAR_WRITE_NOT_CONFIGURED' };
  const e = await rpc<Record<string, any>>(settings, 'event_calendar_payload', { p_event_id: eventId });
  if (!e) throw new ApiError(404, 'EVENT_NOT_FOUND');
  if (e.status === 'cancelled') return removeCalendarEvent(settings, e);
  if (e.google_event_id) return { calendarSynced: true };
  const googleId = eventId.replace(/-/g, '');
  const price = e.price_cents == null ? '未定' : `NT$${Math.round(e.price_cents / 100)}`;
  const body = {
    id: googleId,
    summary: `【海星】${e.title}（${e.capacity}人）`,
    location: e.venue,
    description: [`主揪：${e.organizer_name ?? ''}`, `DM：${e.dm_name}`, `每人：${price}`,
      `玩家：${(e.players ?? []).join('、')}`, '', '由海星劇本殺預約系統建立'].join('\n'),
    start: { dateTime: e.starts_at, timeZone: 'Asia/Taipei' },
    end: { dateTime: e.ends_at, timeZone: 'Asia/Taipei' },
  };
  try {
    const token = await googleAccessToken(settings);
    const response = await (settings.fetcher ?? fetch)(
      `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendarId)}/events`, {
        method: 'POST', signal: AbortSignal.timeout(8000),
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify(body),
      });
    // 409 means an earlier attempt already created this exact event.
    if (!response.ok && response.status !== 409) throw new Error(String(response.status));
  } catch { return { calendarSynced: false, calendarError: 'CALENDAR_WRITE_FAILED' }; }
  await rpc(settings, 'mark_event_calendar_synced', { p_event_id: eventId, p_google_event_id: googleId });
  return { calendarSynced: true };
}

// Removes a cancelled session from the store calendar. Already-gone entries count as removed.
async function removeCalendarEvent(settings: Settings, e: Record<string, any>) {
  if (!e.google_event_id || e.calendar_removed) return { calendarRemoved: true };
  const calendarId = settings.google?.eventsCalendarId;
  if (!settings.google || !calendarId) return { calendarRemoved: false, calendarError: 'CALENDAR_WRITE_NOT_CONFIGURED' };
  try {
    const token = await googleAccessToken(settings);
    const response = await (settings.fetcher ?? fetch)(`https://www.googleapis.com/calendar/v3/calendars/${
      encodeURIComponent(calendarId)}/events/${encodeURIComponent(e.google_event_id)}`, {
      method: 'DELETE', signal: AbortSignal.timeout(8000), headers: { Authorization: `Bearer ${token}` } });
    if (!response.ok && response.status !== 404 && response.status !== 410) throw new Error(String(response.status));
  } catch { return { calendarRemoved: false, calendarError: 'CALENDAR_REMOVE_FAILED' }; }
  await rpc(settings, 'mark_event_calendar_removed', { p_event_id: e.event_id });
  return { calendarRemoved: true };
}

// --- LINE notifications ------------------------------------------------------------
const DEFAULT_LIFF_ID = '2011840025-6cuU9x8P';
const taipeiFormat = (opts: Intl.DateTimeFormatOptions) => new Intl.DateTimeFormat('zh-TW', { timeZone: 'Asia/Taipei', ...opts });
function sessionRange(p: Record<string, any>) {
  if (!p.starts_at) return '';
  const day = taipeiFormat({ month: 'numeric', day: 'numeric', weekday: 'short' }).format(new Date(p.starts_at));
  const time = (iso: string) => taipeiFormat({ hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso));
  return `${day} ${time(p.starts_at)}${p.ends_at ? '–' + time(p.ends_at) : ''}`;
}
export function notificationText(p: Record<string, any>, liffId = DEFAULT_LIFF_ID) {
  const link = `https://liff.line.me/${liffId}?group=${p.group_id}`;
  const when = sessionRange(p);
  const game = p.game_title ? `《${p.game_title}》` : '劇本待店家推薦';
  const price = p.price_cents == null ? '' : `\n每人 NT$${Math.round(p.price_cents / 100)}`;
  switch (p.kind) {
    case 'group_created':
      return `【新揪團】${p.organizer_name} 開了一團\n${when}\n${game}・${p.capacity} 人\n查看：${link}`;
    case 'member_joined':
      return `【有人加入】${p.joiner_name} 加入了你的揪團\n${when}・目前 ${p.filled}/${p.capacity} 人`
        + (p.filled >= p.capacity ? '\n已滿團！店家確認後會再通知大家。' : '') + `\n查看：${link}`;
    case 'group_full':
      return `【滿團待確認】${p.organizer_name} 的揪團已滿 ${p.capacity} 人\n${when}・${game}\n請確認成團：${link}`;
    case 'group_full_members':
      return `【已滿團】${when} 的${game}已經滿 ${p.capacity} 人\n店家確認成團後會再通知你。\n查看：${link}`;
    case 'group_confirmed':
      return `【成團確認】${game}\n${when}\n場地：${p.venue}\nDM：${p.dm_name}${price}\n詳情：${link}`;
    case 'event_cancelled':
      return `【場次取消】很抱歉，店家取消了 ${when} 的${game}`
        + (p.cancel_reason ? `\n原因：${p.cancel_reason}` : '') + `\n詳情：${link}`;
    case 'group_dissolved':
      return `【揪團解散】${p.organizer_name} 解散了 ${when} 的揪團\n詳情：${link}`;
    case 'binding_requested':
      return `【老玩家綁定申請】${p.display_name || 'LINE 玩家'} 申請綁定玩本記錄名字「${p.record_name}」\n審核：https://liff.line.me/${liffId}?view=bindings`;
    case 'binding_approved':
      return `【綁定完成】你的 LINE 已綁定玩本記錄「${p.record_name}」。\n符合資格的老玩家會收到 ${RETURN_BONUS} 點回歸禮，打開會員卡就能看到。\n會員卡：https://liff.line.me/${liffId}?view=card`;
    case 'redemption_requested':
      return `【兌換申請】${p.record_name} 想兌換「${p.reward}」（${p.cost} 點，餘額 ${p.balance}）${p.title ? `\n稱號：${p.title}` : ''}\n審核：https://liff.line.me/${liffId}?view=redemptions`;
    case 'redemption_approved':
      return `【兌換完成】已為你兌換「${p.reward}」，扣 ${p.cost} 點，目前餘額 ${p.balance} 點。${p.title ? `\n你的稱號「${p.title}」已掛上榮譽牆。` : ''}\n到店時出示會員卡即可。\n會員卡：https://liff.line.me/${liffId}?view=card`;
    case 'redemption_rejected':
      return `【兌換未通過】「${p.reward}」的兌換申請沒有通過${p.note ? `：${p.note}` : ''}。點數沒有扣，有問題請直接在聊天室留言。\n會員卡：https://liff.line.me/${liffId}?view=card`;
    case 'binding_rejected':
      return `【綁定未通過】店家沒有通過「${p.record_name}」的綁定。名字選錯的話可以重新申請，有問題請直接在聊天室留言。\n重新申請：https://liff.line.me/${liffId}?view=veteran`;
    default:
      return null;
  }
}

// Store-facing notifications go out from the store's own OA (a second LINE OA with its own free message
// quota) when LINE_ADMIN_CHANNEL_ACCESS_TOKEN is set. If that OA cannot reach the admin (not its friend yet,
// or its channel sits under another provider, where LINE user IDs differ), the players' OA sends it instead.
export const ADMIN_NOTIFICATION_KINDS = new Set(['group_created', 'group_full', 'binding_requested', 'redemption_requested']);
function pushText(settings: Settings, token: string, to: string, text: string, retryKey: string) {
  return (settings.fetcher ?? fetch)('https://api.line.me/v2/bot/message/push', {
    method: 'POST', signal: AbortSignal.timeout(8000),
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, 'X-Line-Retry-Key': retryKey },
    body: JSON.stringify({ to, messages: [{ type: 'text', text: text.slice(0, 5000) }] }),
  });
}
// The store's OA cannot deliver: not its friend / unknown user ID (400, 403, 404), a revoked token (401),
// or its monthly free messages are used up (429). The players' OA sends it instead.
const ADMIN_OA_FALLBACK = new Set([400, 401, 403, 404, 429]);

// Sends queued notifications. LINE's retry key makes a resend after a timeout a no-op.
export async function deliverNotifications(settings: Settings, limit = 20) {
  if (!settings.lineAccessToken) return { sent: 0, skipped: 0, failed: 0 };
  const batch = await rpc<Record<string, any>[]>(settings, 'claim_notifications', { p_limit: limit });
  const tally = { sent: 0, skipped: 0, failed: 0 };
  for (const n of batch) {
    const text = notificationText(n.payload, settings.liffId ?? DEFAULT_LIFF_ID);
    // friend_status is about the players' OA; the store's OA is tried regardless.
    const viaAdmin = Boolean(settings.adminLineAccessToken) && ADMIN_NOTIFICATION_KINDS.has(n.payload?.kind);
    let result: 'sent' | 'skipped' | 'failed', error: string | null = null;
    if (!text) { result = 'skipped'; error = 'UNKNOWN_KIND'; }
    else if (!viaAdmin && n.friend_status === 'blocked') { result = 'skipped'; error = 'BLOCKED'; }
    else {
      try {
        let response = await pushText(settings, viaAdmin ? settings.adminLineAccessToken! : settings.lineAccessToken,
          n.line_user_id, text, n.retry_key);
        if (viaAdmin && ADMIN_OA_FALLBACK.has(response.status) && n.friend_status !== 'blocked') {
          const adminStatus = response.status;
          response = await pushText(settings, settings.lineAccessToken, n.line_user_id, text, n.retry_key);
          error = `VIA_PLAYER_OA_${adminStatus}`;  // delivered, but the store's OA could not
        }
        // 409: this retry key was already accepted, i.e. the message went out earlier.
        if (response.ok || response.status === 409) result = 'sent';
        else if (response.status === 429 || response.status >= 500) { result = 'failed'; error = `HTTP_${response.status}`; }
        else { result = 'skipped'; error = `HTTP_${response.status}`; }  // e.g. not a friend of the OA
      } catch { result = 'failed'; error = 'NETWORK'; }
    }
    tally[result]++;
    await rpc(settings, 'complete_notification', { p_id: n.id, p_result: result, p_error: error });
  }
  return tally;
}

// The 5-minute schedule (pg_cron → POST /hooks/tick): work that must not wait for the next player's tap.
// Groups past their start time are cancelled, and queued or failed notifications go out in batches
// until the queue is empty, five batches have run, or 30 seconds have passed (the next tick continues).
const TICK_BATCHES = 5, TICK_BUDGET_MS = 30_000, NOTIFY_BATCH = 20;
export async function runScheduledWork(settings: Settings) {
  const clock = settings.now ?? Date.now, started = clock();
  const expired = await rpc<number>(settings, 'expire_stale_groups', {}).catch(() => null);
  const total = { sent: 0, skipped: 0, failed: 0 };
  for (let batch = 0; batch < TICK_BATCHES; batch++) {
    const tally = await deliverNotifications(settings, NOTIFY_BATCH);
    total.sent += tally.sent; total.skipped += tally.skipped; total.failed += tally.failed;
    if (tally.sent + tally.skipped + tally.failed < NOTIFY_BATCH || clock() - started > TICK_BUDGET_MS) break;
  }
  // During the transition the website may fall back to the old Apps Script; bring those answers in every 6 hours.
  // Fails quietly until the store shares the 角色問卷總表 with the service account.
  let surveys: number | null = null;
  if (settings.google && await rpc<boolean>(settings, 'claim_scheduled_job', { p_name: 'role-survey-import', p_every: '6 hours' })
    .catch(() => false)) {
    surveys = await importRoleSurveys(settings, null).then(r => r.imported, () => null);
  }
  // After the cutover, records the website sent to the Apps Script while the booking system was unreachable.
  let records: unknown = null;
  if (settings.google && await recordsLive(settings).catch(() => false) &&
      await rpc<boolean>(settings, 'claim_scheduled_job', { p_name: 'records-catch-up', p_every: '10 minutes' }).catch(() => false)) {
    records = await importPlayRecords(settings, null, 'new').then(r => (r as any)?.added ?? null, async e => {
      // Shown on the store's screen (e.g. the spreadsheet is no longer shared with the service account).
      await rpc(settings, 'system_records_catch_up_failed', { p_code: e instanceof ApiError ? e.message : 'CATCH_UP_FAILED' })
        .catch(() => undefined);
      return null;
    });
  }
  console.log('tick', JSON.stringify({ expired, ...total, surveys, records }));  // counts only, for the Edge Function logs
  return { expired, ...total };
}

// --- 玩本記錄 points (the website's Apps Script) ---------------------------------------
// Points stay in the website's Google Sheet; this system only reads its public summary and asks
// it to add the one-time 回歸禮 when the store approves a binding.
const PLAY_RECORD_URL = 'https://script.google.com/macros/s/AKfycbz2jFZhU9tSm-WvZaC_lLSovG2zy3Up2-HNlK6sO6xyfnFDQu8DxRUIKmhDBg1AHMDsDg/exec';
const RETURN_BONUS = 50;
type RecordSummary = { name: string; agent: string; earned: number; redeemed: number; balance: number; plays: number;
  last: string; title?: string };
type Reward = { track: string; name: string; cost: number; note: string };
type Binding = Record<string, any> & { user_id: string; record_name: string; status: string; bonus_status: string };
type RecordData = { summary: RecordSummary[]; rewards: Reward[]; fetchedAt: string; stale: boolean; refreshing?: boolean };
let recordCache: { at: number; url: string; data: RecordData } | null = null;
let lastRecordError = '';  // why the last summary fetch failed (a code only, no content)

// One read of the Apps Script summary; returns a reason code instead of throwing.
async function fetchRecordSummary(settings: Settings, url: string): Promise<{ body?: any; reason?: string }> {
  try {
    const response = await (settings.fetcher ?? fetch)(`${url}?action=summary`, { signal: AbortSignal.timeout(25000) });
    const text = await response.text();
    if (!response.ok) return { reason: `HTTP_${response.status}` };
    let body: any;
    try { body = JSON.parse(text); } catch { return { reason: `NOT_JSON:${(response.headers.get('content-type') ?? '').split(';')[0]}` }; }
    return body?.ok && Array.isArray(body.summary) ? { body } : { reason: 'BAD_PAYLOAD' };
  } catch (e) { return { reason: (e as Error)?.name === 'TimeoutError' ? 'TIMEOUT' : 'NETWORK' }; }
}

// The Apps Script is slow (5-25 s) and sometimes answers 404, so the last good copy is kept in
// the database. A page asks for data no older than maxAgeMs; when the script fails (after one
// retry) the older copy is used instead and marked stale.
// With preferCopy (pages a player is waiting on), an outdated copy is returned at once, marked
// refreshing, and the script is read after the response.
async function playRecordSummary(settings: Settings, maxAgeMs = 60_000, preferCopy = false): Promise<RecordData> {
  const url = settings.playRecordUrl ?? PLAY_RECORD_URL;
  const now = (settings.now ?? Date.now)();
  if (recordCache && recordCache.url === url && now - recordCache.at < Math.min(maxAgeMs, 60_000)) return recordCache.data;
  const shape = (payload: any, fetchedAt: string, stale: boolean): RecordData => ({
    summary: (payload.summary ?? []).filter((x: any) => typeof x?.name === 'string' && x.name),
    rewards: Array.isArray(payload.rewards) ? payload.rewards : [], fetchedAt, stale });
  const saved = await rpc<{ payload: any; fetched_at: string } | null>(settings, 'get_record_snapshot', {}).catch(() => null);
  const savedAt = saved ? Date.parse(saved.fetched_at) : NaN;  // '-infinity' (expired) parses as NaN
  if (saved && Number.isFinite(savedAt) && now - savedAt < maxAgeMs) {
    const data = shape(saved.payload, saved.fetched_at, false);
    recordCache = { at: savedAt, url, data };
    return data;
  }
  if (saved && preferCopy && settings.background) {
    settings.background(playRecordSummary(settings, maxAgeMs).catch(() => undefined));
    return { ...shape(saved.payload, Number.isFinite(savedAt) ? saved.fetched_at : '', false), refreshing: true };
  }
  let result = await fetchRecordSummary(settings, url);
  if (result.reason) result = await fetchRecordSummary(settings, url);
  if (result.body) {
    const payload = result.body;  // the whole public summary: the website reads this copy too
    await rpc(settings, 'put_record_snapshot', { p_payload: payload }).catch(() => undefined);
    const data = shape(payload, new Date(now).toISOString(), false);
    recordCache = { at: now, url, data };
    return data;
  }
  lastRecordError = result.reason ?? 'RECORDS_UNAVAILABLE';
  console.error('play record summary failed:', lastRecordError);
  if (saved) return shape(saved.payload, saved.fetched_at, true);
  throw new ApiError(503, 'RECORDS_UNAVAILABLE');
}

// After the cutover the points live here: the 回歸禮 is one ledger row, written with the eligibility check
// (once per player, joined before 回歸禮資格日) in the database.
// A database without migration 0036 (the function is missing) is still on the Apps Script. Any other failure is
// no answer: guessing 'Apps Script' after the cutover would send a 回歸禮 there or check a new name against its
// stale copy, so callers fail with 503 and are retried instead.
const recordsLive = (settings: Settings) =>
  rpc<string>(settings, 'records_source', {}).then(v => v === 'supabase', e => {
    if (e instanceof ApiError && e.missing) return false;
    throw new ApiError(503, 'RECORDS_UNAVAILABLE');
  });
// The stage-2 functions, read where a missing migration means "still on the Apps Script" (null).
const unlessMissing = <T>(work: Promise<T>) =>
  work.catch(e => { if (e instanceof ApiError && e.missing) return null; throw e; });

// Before the cutover: asks the Apps Script for the 回歸禮. It is idempotent per 歸戶名 and checks eligibility itself.
async function grantReturnBonus(settings: Settings, binding: Binding): Promise<Binding> {
  if (await recordsLive(settings)) {
    return rpc<Binding>(settings, 'grant_record_return_bonus', { p_user_id: binding.user_id, p_points: RETURN_BONUS });
  }
  if (!settings.playRecordSecret) throw new ApiError(503, 'BONUS_NOT_CONFIGURED');
  let body: any;
  try {
    const response = await (settings.fetcher ?? fetch)(settings.playRecordUrl ?? PLAY_RECORD_URL, {
      method: 'POST', signal: AbortSignal.timeout(30000),
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ action: 'grant_bonus', secret: settings.playRecordSecret, name: binding.record_name,
        points: String(RETURN_BONUS), note: 'LINE 綁定' }).toString() });
    body = response.ok ? await response.json() : null;
  } catch { body = null; }
  if (!body?.ok) throw new ApiError(502, body?.error === 'INVALID_SECRET' ? 'BONUS_SECRET_MISMATCH' : 'BONUS_FAILED');
  const status = body.granted ? 'granted' : body.reason === 'INELIGIBLE' ? 'ineligible' : 'already';
  recordCache = null;  // the balance just changed
  await rpc(settings, 'expire_record_snapshot', {}).catch(() => undefined);
  return rpc<Binding>(settings, 'mark_binding_bonus', { p_user_id: binding.user_id, p_status: status });
}

// The website reads the 玩本記錄 summary from this copy (about 0.2 s) instead of the Apps Script
// (1 s cached, ~10 s when its cache has expired). The Apps Script pings /hooks/records-changed
// after each recalculation; copies older than 5 minutes are refreshed after the response.
const PUBLIC_RECORDS_FRESH_MS = 5 * 60_000;
let refreshingRecords: Promise<unknown> | null = null;
function refreshRecordCopy(settings: Settings) {
  refreshingRecords ??= playRecordSummary(settings, 0).catch(() => undefined).finally(() => { refreshingRecords = null; });
  return refreshingRecords;
}
async function publicRecordsPayload(settings: Settings): Promise<Record<string, unknown>> {
  // After the cutover the summary is computed by the database (same JSON shape); before it, null.
  // After the cutover a failure is a 503, never the Apps Script copy: that copy lacks every point earned since.
  // live tells the website which side it is reading (it keeps its own copy rather than fall back once it was live).
  const live = await unlessMissing(rpc<Record<string, unknown> | null>(settings, 'public_records_payload', {}));
  if (live) return { ...live, live: true };
  const saved = await rpc<{ payload: any; fetched_at: string } | null>(settings, 'get_record_snapshot', {}).catch(() => null);
  const savedAt = saved ? Date.parse(saved.fetched_at) : NaN;
  // Copies saved before the whole payload was kept have no updatedAt; read the script for those.
  if (saved?.payload?.ok && typeof saved.payload.updatedAt === 'string') {
    if (!(((settings.now ?? Date.now)() - savedAt) < PUBLIC_RECORDS_FRESH_MS)) {
      const work = refreshRecordCopy(settings);
      if (settings.background) settings.background(work); else await work;
    }
    return { ...saved.payload, live: false };
  }
  await refreshRecordCopy(settings);
  const fresh = await rpc<{ payload: any } | null>(settings, 'get_record_snapshot', {}).catch(() => null);
  if (fresh?.payload?.ok) return { ...fresh.payload, live: false };
  throw new ApiError(503, 'RECORDS_UNAVAILABLE');
}

const publicRecord = (r: RecordSummary) => ({ name: r.name, agent: r.agent, plays: r.plays, last: r.last });

// --- Google Sheets import (read-only, service account) --------------------------------------
// The store shares an old spreadsheet with the service account (Viewer) and imports it once. Nothing is
// written back to Google. Used for the 角色問卷總表; the 玩本記錄 spreadsheet follows the same path.
const ROLE_SURVEY_SHEET_ID = '1NrmyrSq3UqoU0m-2JWVJsvF18VKwW18n-P-w-iyYb5M';  // GoogleAppsScript_角色問卷.gs
async function sheetsGet(settings: Settings, sheetId: string, query: string) {
  if (!settings.google) throw new ApiError(503, 'GOOGLE_NOT_CONFIGURED');
  let token: string;
  try { token = await googleAccessToken(settings); } catch { throw new ApiError(503, 'GOOGLE_KEY_INVALID'); }
  const response = await (settings.fetcher ?? fetch)(
    `https://sheets.googleapis.com/v4/spreadsheets/${encodeURIComponent(sheetId)}${query}`,
    { signal: AbortSignal.timeout(20000), headers: { Authorization: `Bearer ${token}` } });
  if (response.status === 403 || response.status === 404) {
    // Tell the store which setup step is missing; these come from Google's error body.
    const err = (await response.json().catch(() => null))?.error ?? {};
    const disabled = (err.details ?? []).some((d: any) => d.reason === 'SERVICE_DISABLED')
      || /has not been used|is disabled/i.test(err.message ?? '');
    throw new ApiError(503, response.status === 404 ? 'SHEET_NOT_FOUND' : disabled ? 'SHEETS_API_DISABLED' : 'SHEET_NOT_SHARED');
  }
  if (!response.ok) throw new ApiError(502, 'SHEETS_FAILED');
  return response.json();
}

// A Sheets date serial counts days from 1899-12-30 in the spreadsheet's own time zone.
// One formatter per zone: building it is most of the cost, and an import converts thousands of times (Edge CPU limit).
const zoneFormats = new Map<string, Intl.DateTimeFormat>();
function zoneOffsetMs(timeZone: string, utcMs: number) {
  let format = zoneFormats.get(timeZone);
  if (!format) {
    format = new Intl.DateTimeFormat('en-US', { timeZone, hourCycle: 'h23', year: 'numeric', month: '2-digit',
      day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' });
    zoneFormats.set(timeZone, format);
  }
  const parts = format.formatToParts(new Date(utcMs));
  const get = (t: string) => Number(parts.find(p => p.type === t)?.value);
  return Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second')) - utcMs;
}
export function sheetSerialToIso(serial: number, timeZone = 'Asia/Taipei') {
  const local = Math.round((serial - 25569) * 86400000);
  let utc = local - zoneOffsetMs(timeZone, local);
  utc = local - zoneOffsetMs(timeZone, utc);  // second pass settles the offset at the true instant
  return new Date(utc).toISOString();
}

// One tab of the 角色問卷總表 → answers. Column A is 時間戳記 (read as a serial for an exact time); every other
// column with a header becomes {label, value} using the text the store sees. Columns the store added by hand
// (分配角色 / 角色分配 / 備註) become the answer's assigned role and note, and 送出編號 (written by the website's
// fallback) ties the row to an answer the booking system may already have.
// import_key = SHA-256 of tab + time + how many earlier rows share that time, so later edits to a row in the
// sheet never create a second copy.
const SHEET_ROLE = new Set(['分配角色', '角色分配']), SHEET_NOTE = new Set(['備註']), SHEET_CLIENT_ID = '送出編號';
export async function surveyRowsFromSheet(tab: string, shown: unknown[][], serials: unknown[][], timeZone: string) {
  const header = (shown[0] ?? []).map(h => String(h ?? '').trim());
  const rows: Record<string, unknown>[] = [];
  const seen = new Map<number, number>();
  let skipped = 0;
  for (let i = 1; i < shown.length; i++) {
    const cells = header.map((_, c) => String((shown[i] ?? [])[c] ?? '').trim());
    const serial = Number((serials[i] ?? [])[0]);
    const pick = (names: Set<string>) => cells.find((v, c) => names.has(header[c]) && v) ?? '';
    const fields = header.map((label, c) => ({ label, value: cells[c] }))
      .filter((f, c) => c > 0 && f.label && f.value && !SHEET_ROLE.has(f.label) && !SHEET_NOTE.has(f.label) && f.label !== SHEET_CLIENT_ID);
    if (!fields.length) continue;  // an empty row is not an answer
    if (!Number.isFinite(serial) || serial < 1) { skipped++; continue; }
    const nth = seen.get(serial) ?? 0;
    seen.set(serial, nth + 1);
    const clientId = pick(new Set([SHEET_CLIENT_ID]));
    rows.push({ script: tab, submitted_at: sheetSerialToIso(serial, timeZone), fields,
      import_key: await sha256Hex(JSON.stringify([tab, serial, nth])),
      ...(UUID_ANY.test(clientId) ? { client_id: clientId.toLowerCase() } : {}),
      assigned_role: pick(SHEET_ROLE), store_note: pick(SHEET_NOTE) });
  }
  return { rows, skipped };
}
const UUID_ANY = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// actor null = the scheduled import (answers the website sent to the old Apps Script during the transition).
async function importRoleSurveys(settings: Settings, actor: string | null) {
  const sheetId = settings.roleSurveySheetId ?? ROLE_SURVEY_SHEET_ID;
  const meta = await sheetsGet(settings, sheetId, '?fields=properties.timeZone,sheets.properties.title');
  const timeZone = meta?.properties?.timeZone || 'Asia/Taipei';
  const tabs: string[] = (meta?.sheets ?? []).map((x: any) => String(x.properties?.title ?? '')).filter(Boolean);
  if (!tabs.length) return { tabs: [], imported: 0, skipped: 0 };
  const ranges = (cols: string) => tabs.map(t => `ranges=${encodeURIComponent(`'${t.replace(/'/g, "''")}'!${cols}`)}`).join('&');
  const [shown, serials] = await Promise.all([
    sheetsGet(settings, sheetId, `/values:batchGet?${ranges('A1:CZ')}&valueRenderOption=FORMATTED_VALUE`),
    sheetsGet(settings, sheetId, `/values:batchGet?${ranges('A1:A')}&valueRenderOption=UNFORMATTED_VALUE&dateTimeRenderOption=SERIAL_NUMBER`),
  ]);
  const rows: Record<string, unknown>[] = [];
  const perTab: { script: string; rows: number }[] = [];
  let skipped = 0;
  for (let t = 0; t < tabs.length; t++) {
    const got = await surveyRowsFromSheet(tabs[t], shown?.valueRanges?.[t]?.values ?? [], serials?.valueRanges?.[t]?.values ?? [], timeZone);
    skipped += got.skipped;
    if (got.rows.length) perTab.push({ script: tabs[t], rows: got.rows.length });
    rows.push(...got.rows);
  }
  if (rows.length > 5000) throw new ApiError(400, 'IMPORT_TOO_LARGE');
  const done = !rows.length ? { imported: 0, skipped: 0 } : actor
    ? await rpc<{ imported: number; skipped: number }>(settings, 'admin_import_role_surveys', { p_actor: actor, p_rows: rows })
    : await rpc<{ imported: number; skipped: number }>(settings, 'system_import_role_surveys', { p_rows: rows });
  return { tabs: perTab, imported: done.imported, skipped: done.skipped + skipped };
}

// --- 玩本記錄 spreadsheet import (stage 2 of the GAS removal) ----------------------------------
// The store shares the spreadsheet behind GoogleAppsScript_玩本記錄.gs with the service account (Viewer).
// Values are read unformatted, as the Apps Script's getValues() saw them: date cells come as serial numbers and
// become an instant (時間戳記, 最後更新) or a Y/M/D date (日期, 加入日期), numbers stay numbers, checkboxes booleans.
const PLAY_RECORD_SHEET_ID = '1hjdPJQo5Z6nVICZsvljihSXoZAJ32DpiAEQikCaog-8';
const PLAY_RECORD_RESPONSE_GID = 463584243;  // 表單回應 1
const PLAY_RECORD_TABS = ['點數帳本', '玩家', '設定', '獎勵', '任務', '心得互動'];
const serialDay = (serial: number) => {
  const d = new Date(Math.floor(serial - 25569) * 86400000);
  return `${d.getUTCFullYear()}/${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
};
const asText = (v: unknown) => v == null ? '' : typeof v === 'number' && !Number.isFinite(v) ? '' : String(v);
const asDate = (v: unknown) => typeof v === 'number' ? serialDay(v) : asText(v);
const asNumber = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const asTruthy = (v: unknown) => v === true || /^(true|yes|是|y|v|1|✓|✔)$/i.test(asText(v).trim());
const asActive = (v: unknown) => asText(v).trim().toUpperCase() !== 'FALSE';

// readRows_: the first row is the header; rows with every cell blank are skipped.
function sheetRows(values: unknown[][] | undefined) {
  const [head = [], ...body] = values ?? [];
  const header = head.map(h => asText(h).trim());
  return body.filter(r => (r ?? []).some(c => asText(c).trim()))
    .map(r => Object.fromEntries(header.map((h, i) => [h, (r ?? [])[i]]).filter(([h]) => h)) as Record<string, unknown>);
}

export async function playRecordsFromSheet(tabs: Record<string, unknown[][]>, responseTab: string, timeZone: string) {
  const stamp = (v: unknown) => {
    if (typeof v === 'number') return v > 0 ? sheetSerialToIso(v, timeZone) : null;
    // parseDate_: a typed text stamp ('2025/3/1 下午 3:04:05') counts as that day at midnight; anything else as none.
    const parts = asText(v).trim().split(/[\/\-.]/).map(x => parseInt(x, 10));
    if (parts.length < 3 || parts.some(Number.isNaN)) return null;
    return sheetSerialToIso(Date.UTC(parts[0], parts[1] - 1, parts[2]) / 86400000 + 25569, timeZone);
  };
  const seen = new Map<string, number>();
  const responses = [];
  // Old Google Form rows may hold the role in any of several 角色… columns (some with the very same header);
  // the honour wall joins them with ', '. Read them by position: a keyed row keeps only the last of equal headers.
  const head = (tabs[responseTab]?.[0] ?? []).map(h => asText(h).trim());
  const roleColumns = head.flatMap((h, i) => h.startsWith('角色') ? [i] : []);
  const rawRows = (tabs[responseTab] ?? []).slice(1).filter(r => (r ?? []).some(c => asText(c).trim()));
  let index = 0;
  for (const r of sheetRows(tabs[responseTab])) {
    const cells = rawRows[index] ?? [];
    index++;
    const raw = r['時間戳記'];
    const id = typeof raw === 'number' ? String(raw) : `row-${index}`;
    const nth = seen.get(id) ?? 0;
    seen.set(id, nth + 1);
    const role = roleColumns.map(i => asText(cells[i]).trim()).filter(Boolean).join(', ');
    responses.push({ key: await sha256Hex(JSON.stringify(['玩本記錄', id, nth])), stamp: stamp(raw),
      name: asText(r['怎麼稱呼你呢']), date: asDate(r['日期']), script: asText(r['劇本']), role,
      rating: asText(r['給予評價']), comment: asText(r['50字以內的心得推薦']), referrer: asText(r['介紹人']) });
  }
  return {
    responses,
    ledger: sheetRows(tabs['點數帳本']).map(r => ({ stamp: stamp(r['時間戳記']), name: asText(r['玩家名']), player: asText(r['歸戶名']),
      type: asText(r['類型']), points: asNumber(r['點數']), detail: asText(r['明細']), script: asText(r['劇本']), date: asDate(r['日期']),
      source: asText(r['來源']), status: asText(r['狀態']), note: asText(r['備註']), key: asText(r['去重鍵']) })),
    players: sheetRows(tabs['玩家']).map(r => ({ name: asText(r['顯示名']),
      aliases: asText(r['別名']).split(/[,，、;；]/).map(a => a.trim()).filter(Boolean),
      agent: asText(r['探員編號']), joined: asDate(r['加入日期']), note: asText(r['備註']), gilded: asTruthy(r['鍍金']),
      title: asText(r['自訂稱號']), legend: asTruthy(r['傳奇殿堂']) })),
    // Only the date settings may be date cells; the point settings are plain numbers.
    config: sheetRows(tabs['設定']).map(r => {
      const key = asText(r['設定項']).trim();
      const v = r['值'];
      // 雙倍日 may also be a weekday digit (6 = Saturday), which is a number cell but not a date.
      if (key === '雙倍日' && typeof v === 'number' && v < 367) return { key, value: String(v) };
      return { key, value: ['回歸禮資格日', 'LINE上線日', '雙倍日'].includes(key) ? asDate(v) : asText(v) };
    }),
    rewards: sheetRows(tabs['獎勵']).map(r => ({ track: asText(r['軌道']), name: asText(r['品項']), cost: asNumber(r['所需點數']),
      note: asText(r['說明']), active: asActive(r['是否上架']) })),
    quests: sheetRows(tabs['任務']).map(r => ({ id: asText(r['任務ID']), label: asText(r['說明']), goal: asNumber(r['目標']),
      points: asNumber(r['點數']), active: asActive(r['是否啟用']) })),
    interactions: sheetRows(tabs['心得互動']).map(r => ({ script: asText(r['劇本']), date: asDate(r['日期']), author: asText(r['作者']),
      likes: asNumber(r['讚數']), featured: asTruthy(r['精選']), updated: stamp(r['最後更新']) })),
  };
}

// full: everything, before the cutover (replaces the earlier import). new: only 表單回應 rows added after that import,
// scored with the new rules (the website fell back to the Apps Script). actor null = the scheduled catch-up.
async function importPlayRecords(settings: Settings, actor: string | null, mode: 'full' | 'new') {
  const sheetId = settings.playRecordSheetId ?? PLAY_RECORD_SHEET_ID;
  const meta = await sheetsGet(settings, sheetId, '?fields=properties.timeZone,sheets.properties(title,sheetId)');
  const timeZone = meta?.properties?.timeZone || 'Asia/Taipei';
  const all: { title: string; sheetId: number }[] = (meta?.sheets ?? []).map((x: any) => x.properties ?? {});
  const responseTab = (all.find(t => t.sheetId === PLAY_RECORD_RESPONSE_GID) ?? all.find(t => t.title === '表單回應 1') ?? all[0])?.title;
  if (!responseTab) throw new ApiError(503, 'SHEET_NOT_FOUND');
  const wanted = [responseTab, ...(mode === 'full' ? PLAY_RECORD_TABS.filter(t => all.some(x => x.title === t)) : [])];
  const ranges = wanted.map(t => `ranges=${encodeURIComponent(`'${t.replace(/'/g, "''")}'!A1:CZ`)}`).join('&');
  const got = await sheetsGet(settings, sheetId,
    `/values:batchGet?${ranges}&valueRenderOption=UNFORMATTED_VALUE&dateTimeRenderOption=SERIAL_NUMBER`);
  const tabs = Object.fromEntries(wanted.map((t, i) => [t, got?.valueRanges?.[i]?.values ?? []]));
  const data = await playRecordsFromSheet(tabs, responseTab, timeZone);
  if (mode === 'new') {
    return actor
      ? rpc<Record<string, unknown>>(settings, 'admin_import_new_play_records', { p_actor: actor, p_rows: data.responses }, 60000)
      : rpc<Record<string, unknown>>(settings, 'system_import_new_play_records', { p_rows: data.responses }, 60000);
  }
  return rpc<Record<string, unknown>>(settings, 'admin_import_play_records', { p_actor: actor, p_data: data }, 60000);
}

// --- Rich Menu -------------------------------------------------------------------
// Two 2500x1686 menus of six cells. New players get the default one (getting to know
// Starfish, then booking); players with a recorded play are linked to the member one.
const RICH_MENU_NEW = '海星選單・新玩家';
const RICH_MENU_MEMBER = '海星選單・老玩家';
const RICH_MENU_OLD_NAMES = ['海星預約選單'];  // earlier single menu, removed on setup
const RICH_MENU_IMAGES: Record<string, string> = {
  new: 'https://cj2vum4.github.io/starfish-booking-system/richmenu-new.jpg',
  member: 'https://cj2vum4.github.io/starfish-booking-system/richmenu-member.jpg',
  store: 'https://cj2vum4.github.io/starfish-booking-system/richmenu-store.jpg',
};
const SITE = 'https://cj2vum4.github.io/starfishlarp/';
const sitePage = (file: string) => SITE + encodeURIComponent(file);
export function richMenuDefinition(kind: 'new' | 'member', liffId = DEFAULT_LIFF_ID) {
  const liff = (view?: string) => `https://liff.line.me/${liffId}${view ? '?view=' + view : ''}`;
  const links = kind === 'new'
    ? [sitePage('主持人資訊.html'), SITE, liff(), liff('open'), liff('guide'), liff('veteran')]
    : [liff(), liff('open'), liff('survey'), liff('card'), SITE, sitePage('榮譽牆.html')];  // 玩後問卷: LIFF fills the name, then the website form
  const widths = [833, 834, 833];
  return {
    size: { width: 2500, height: 1686 }, selected: true,
    name: kind === 'new' ? RICH_MENU_NEW : RICH_MENU_MEMBER, chatBarText: '海星選單',
    areas: links.map((uri, i) => {
      const col = i % 3, row = Math.floor(i / 3);
      return { bounds: { x: col === 0 ? 0 : col === 1 ? 833 : 1667, y: row * 843, width: widths[col], height: 843 },
        action: { type: 'uri', uri } };
    }),
  };
}

type LineCall = (url: string, init?: RequestInit) => Promise<any>;
function lineCaller(settings: Settings, token = settings.lineAccessToken): LineCall {
  if (!token) throw new ApiError(503, 'LINE_NOT_CONFIGURED');
  const f = settings.fetcher ?? fetch;
  return async (url, init = {}) => {
    const response = await f(url, { signal: AbortSignal.timeout(15000), ...init,
      headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) } });
    if (!response.ok) throw new ApiError(502, `LINE_${response.status}`);
    return response.headers.get('content-type')?.includes('json') ? response.json() : null;
  };
}

// The store's OA: one menu for the store (whoever follows that OA is the store). Replaces an older copy.
const RICH_MENU_STORE = '海星選單・店家';
export function storeRichMenuDefinition(liffId = DEFAULT_LIFF_ID) {
  const liff = (view?: string) => `https://liff.line.me/${liffId}${view ? '?view=' + view : ''}`;
  const links = [liff('redemptions'), liff('players'), liff('reviews'), liff('admin'), liff('bindings'), liff()];
  const widths = [833, 834, 833];
  return {
    size: { width: 2500, height: 1686 }, selected: true, name: RICH_MENU_STORE, chatBarText: '店家選單',
    areas: links.map((uri, i) => {
      const col = i % 3, row = Math.floor(i / 3);
      return { bounds: { x: col === 0 ? 0 : col === 1 ? 833 : 1667, y: row * 843, width: widths[col], height: 843 },
        action: { type: 'uri', uri } };
    }),
  };
}
async function setupStoreRichMenu(settings: Settings) {
  if (!settings.adminLineAccessToken) throw new ApiError(503, 'ADMIN_OA_NOT_CONFIGURED');
  const call = lineCaller(settings, settings.adminLineAccessToken);
  const f = settings.fetcher ?? fetch;
  const image = await f(settings.richMenuImageUrls?.store ?? RICH_MENU_IMAGES.store, { signal: AbortSignal.timeout(15000) });
  if (!image.ok) throw new ApiError(502, 'RICH_MENU_IMAGE_UNAVAILABLE');
  const bytes = new Uint8Array(await image.arrayBuffer());
  if (bytes.length > 1024 * 1024) throw new ApiError(502, 'RICH_MENU_IMAGE_TOO_LARGE');
  const before = await call('https://api.line.me/v2/bot/richmenu/list');
  const { richMenuId } = await call('https://api.line.me/v2/bot/richmenu', { method: 'POST',
    headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(storeRichMenuDefinition(settings.liffId)) });
  await call(`https://api-data.line.me/v2/bot/richmenu/${richMenuId}/content`, { method: 'POST',
    headers: { 'Content-Type': 'image/jpeg' }, body: bytes });
  await call(`https://api.line.me/v2/bot/user/all/richmenu/${richMenuId}`, { method: 'POST' });
  const old = (before?.richmenus ?? []).filter((m: { name: string; richMenuId: string }) => m.name === RICH_MENU_STORE && m.richMenuId !== richMenuId);
  for (const m of old) await call(`https://api.line.me/v2/bot/richmenu/${m.richMenuId}`, { method: 'DELETE' });
  return { storeMenuId: richMenuId, replaced: old.length };
}

// Links every player with a recorded play to the member menu. Idempotent; bulk link takes 500 IDs.
async function syncMemberMenu(settings: Settings, call: LineCall, memberMenuId?: string) {
  if (!memberMenuId) {
    const list = await call('https://api.line.me/v2/bot/richmenu/list');
    memberMenuId = (list?.richmenus ?? []).find((m: { name: string }) => m.name === RICH_MENU_MEMBER)?.richMenuId;
    if (!memberMenuId) return { linked: 0 };
  }
  const ids = await rpc<string[]>(settings, 'member_menu_line_ids', {});
  for (let i = 0; i < ids.length; i += 500) {
    await call('https://api.line.me/v2/bot/richmenu/bulk/link', { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ richMenuId: memberMenuId, userIds: ids.slice(i, i + 500) }) });
  }
  return { linked: ids.length };
}

// Creates both menus and uploads their images, makes the new-player menu the default,
// links members, then removes older copies.
async function setupRichMenu(settings: Settings) {
  const call = lineCaller(settings);
  const f = settings.fetcher ?? fetch;
  const images: Record<string, Uint8Array> = {};
  for (const kind of ['new', 'member']) {
    const image = await f(settings.richMenuImageUrls?.[kind] ?? RICH_MENU_IMAGES[kind], { signal: AbortSignal.timeout(15000) });
    if (!image.ok) throw new ApiError(502, 'RICH_MENU_IMAGE_UNAVAILABLE');
    images[kind] = new Uint8Array(await image.arrayBuffer());
    if (images[kind].length > 1024 * 1024) throw new ApiError(502, 'RICH_MENU_IMAGE_TOO_LARGE');
  }
  const before = await call('https://api.line.me/v2/bot/richmenu/list');
  const ids: Record<string, string> = {};
  for (const kind of ['new', 'member'] as const) {
    ({ richMenuId: ids[kind] } = await call('https://api.line.me/v2/bot/richmenu', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(richMenuDefinition(kind, settings.liffId)) }));
    await call(`https://api-data.line.me/v2/bot/richmenu/${ids[kind]}/content`, { method: 'POST',
      headers: { 'Content-Type': 'image/jpeg' }, body: images[kind] });
  }
  await call(`https://api.line.me/v2/bot/user/all/richmenu/${ids.new}`, { method: 'POST' });
  const { linked } = await syncMemberMenu(settings, call, ids.member);
  const ours = [RICH_MENU_NEW, RICH_MENU_MEMBER, ...RICH_MENU_OLD_NAMES];
  const old = (before?.richmenus ?? []).filter((m: { name: string; richMenuId: string }) =>
    ours.includes(m.name) && m.richMenuId !== ids.new && m.richMenuId !== ids.member);
  for (const m of old) await call(`https://api.line.me/v2/bot/richmenu/${m.richMenuId}`, { method: 'DELETE' });
  return { newMenuId: ids.new, memberMenuId: ids.member, membersLinked: linked, replaced: old.length };
}

const TAIPEI_OFFSET_MS = 8 * 3600 * 1000;  // Taiwan has no daylight saving time.
function taipeiDayStart(date: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(`${date}T00:00:00Z`))) {
    throw new ApiError(400, 'INVALID_RANGE');
  }
  return new Date(Date.parse(`${date}T00:00:00Z`) - TAIPEI_OFFSET_MS);
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const INVITE_DAYS = 7;
const CATALOG_URL = 'https://raw.githubusercontent.com/cj2vum4/starfishlarp/main/scripts.js';
const CATALOG_SITE = 'https://cj2vum4.github.io/starfishlarp/';
// Pinned to the pushed commit: raw.githubusercontent.com caches branch URLs for minutes.
const CATALOG_COMMIT_URL = 'https://raw.githubusercontent.com/cj2vum4/starfishlarp/{commit}/scripts.js';

// Compares digests so the time taken does not reveal how much of the secret matched.
async function sameSecret(given: string, expected: string) {
  const [a, b] = await Promise.all([sha256Hex(given), sha256Hex(expected)]);
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function fetchCatalog(settings: Settings, url: string) {
  try {
    const response = await (settings.fetcher ?? fetch)(url, { signal: AbortSignal.timeout(8000) });
    if (!response.ok) throw new Error();
    return parseStarfishCatalog(await response.text(), settings.catalogSiteBase ?? CATALOG_SITE);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(502, 'CATALOG_UNAVAILABLE');
  }
}

// The Starfish site keeps its catalog as `window.SCRIPTS = [...]` in scripts.js. The array
// is read as JSON only, never executed, and each entry is reduced to the fields we store.
export function parseStarfishCatalog(source: string, siteBase = CATALOG_SITE) {
  const match = /window\.SCRIPTS\s*=\s*(\[[\s\S]*?\n\]);/.exec(source);
  if (!match) throw new ApiError(502, 'CATALOG_UNREADABLE');
  let entries: Record<string, unknown>[];
  try { entries = JSON.parse(match[1]); } catch { throw new ApiError(502, 'CATALOG_UNREADABLE'); }
  if (!Array.isArray(entries) || !entries.length) throw new ApiError(502, 'CATALOG_UNREADABLE');
  const https = (v: unknown) => typeof v === 'string' && /^https:\/\//.test(v) ? v : null;
  // The site now keeps posters as its own relative paths (img/劇本/...); those are served from siteBase.
  const sitePath = (v: unknown) => typeof v === 'string' && /^[^/:?#\\][^:?#\\]*$/.test(v) && !v.split('/').includes('..')
    ? siteBase + v.split('/').map(encodeURIComponent).join('/') : null;
  return entries.map(e => {
    const players = Number(e.players);
    const label = typeof e.playersLabel === 'string' ? e.playersLabel : '';
    const range = /(\d+)\s*[-–~]\s*(\d+)\s*人/.exec(label);
    const min = range ? Math.min(Number(range[1]), players) : players;
    const max = range ? Math.max(Number(range[2]), players) : players;
    return {
      slug: String(e.id ?? ''), title: String(e.name ?? ''), min_players: min, max_players: max,
      duration_minutes: Math.round(Number(e.time) * 60),
      genres: Array.isArray(e.types) ? e.types.filter(t => typeof t === 'string').slice(0, 20) : [],
      difficulty: e.difficulty == null ? null : String(e.difficulty), players_label: label || null,
      review_key: typeof e.reviewKey === 'string' && e.reviewKey.trim() ? e.reviewKey.trim() : e.name.trim(),
      image_url: https(e.poster) ?? sitePath(e.poster),
      video_url: https(e.youtube),
      source_url: typeof e.file === 'string' ? siteBase + e.file.split('/').map(encodeURIComponent).join('/') : null,
    };
  });
}

// Database rows use snake_case; the LIFF page uses camelCase.
function camel(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(camel);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).map(([k, v]) => [k.replace(/_([a-z])/g, (_, c) => c.toUpperCase()), camel(v)]));
}
// Invite tokens arrive in POST bodies (never URLs) so they stay out of request logs.
function inviteToken(body: Record<string, unknown>) {
  if (typeof body.token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.token)) throw new ApiError(400, 'INVITE_INVALID');
  return body.token;
}
const inviteExpiry = (settings: Settings) =>
  new Date((settings.now ?? Date.now)() + INVITE_DAYS * 86400000).toISOString();

const publicUser = (s: { user_id: string; display_name: string | null; is_admin: boolean }) =>
  ({ id: s.user_id, displayName: s.display_name, isAdmin: s.is_admin });

const BOOKING_HORIZON_MS = 183 * 86400000;
// 場地：南港／北車／新竹交大，或主揪自己寫的地點（1–60 字）。沒給就是南港。
function venueOf(value: unknown) {
  if (value == null) return '南港';
  if (typeof value !== 'string' || !value.trim() || Array.from(value.trim()).length > 60) throw new ApiError(400, 'INVALID_VENUE');
  return value.trim();
}

// Groups past their start without being confirmed are cancelled before anyone reads or joins them.
const GROUP_PATHS = /^\/(groups|me\/groups|admin\/groups|invites)(\/|$)/;

async function route(req: Request, path: string, settings: Settings): Promise<[number, unknown]> {
  if (GROUP_PATHS.test(path)) await rpc(settings, 'expire_stale_groups', {}).catch(() => undefined);
  if (req.method === 'POST' && path === '/auth/line') {
    const { idToken } = await readJson(req);
    if (typeof idToken !== 'string' || idToken.length < 20 || idToken.length > 4096) {
      throw new ApiError(400, 'INVALID_ID_TOKEN');
    }
    const identity = await verifyIdToken(idToken, settings);
    const token = newToken();
    const expiresAt = new Date((settings.now ?? Date.now)() + SESSION_HOURS * 3600 * 1000).toISOString();
    const user = await rpc<{ user_id: string; display_name: string | null; is_admin: boolean }>(
      settings, 'login_line_user', { p_line_user_id: identity.userId, p_display_name: identity.name,
        p_session_hash: await sha256Hex(token), p_expires_at: expiresAt });
    return [200, { sessionToken: token, expiresAt, user: publicUser(user) }];
  }
  if (req.method === 'GET' && path === '/me') {
    const { session } = await requireSession(req, settings);
    return [200, { user: publicUser(session), expiresAt: session.expires_at }];
  }
  // 店家決定：最遠可預約 6 個月內的時段（約 183 天）。
  if (req.method === 'GET' && path === '/slots') {
    await requireSession(req, settings);
    const params = new URL(req.url).searchParams;
    const days = Number(params.get('days') ?? '14');
    const minutes = Number(params.get('minutes') ?? '240');
    if (!Number.isInteger(days) || days < 1 || days > 31) throw new ApiError(400, 'INVALID_RANGE');
    if (!Number.isInteger(minutes) || minutes < 30 || minutes > 720) throw new ApiError(400, 'INVALID_RANGE');
    const nowMs = (settings.now ?? Date.now)();
    const fromDay = params.get('from');
    const startMs = fromDay ? taipeiDayStart(fromDay).getTime() : nowMs;
    const from = new Date(Math.max(nowMs, startMs));
    const to = new Date(Math.min(startMs + days * 86400000, nowMs + BOOKING_HORIZON_MS));
    if (to <= from) return [200, { slots: [] }];
    await syncCalendar(settings, from, to, LISTING_SYNC_MAX_AGE_MS);
    const slots = await rpc<{ starts_at: string; ends_at: string }[]>(settings, 'list_available_starts',
      { p_from: from.toISOString(), p_to: to.toISOString(), p_minutes: minutes });
    return [200, { slots: slots.map(s => ({ startsAt: s.starts_at, endsAt: s.ends_at })) }];
  }
  if (req.method === 'POST' && path === '/groups') {
    const { session } = await requireSession(req, settings);
    const body = await readJson(req);
    await requireFriend(settings, session.user_id);
    const startsAt = typeof body.startsAt === 'string' ? new Date(body.startsAt) : null;
    if (typeof body.requestId !== 'string' || !UUID.test(body.requestId)) throw new ApiError(400, 'INVALID_REQUEST');
    if (!startsAt || Number.isNaN(startsAt.getTime())) throw new ApiError(400, 'SLOT_UNAVAILABLE');
    if (startsAt.getTime() > (settings.now ?? Date.now)() + BOOKING_HORIZON_MS) throw new ApiError(400, 'TOO_FAR_AHEAD');
    if (body.gameId != null && (typeof body.gameId !== 'string' || !UUID.test(body.gameId))) {
      throw new ApiError(400, 'GAME_NOT_FOUND');
    }
    // Re-check the calendar for the whole session window right before reserving it.
    await syncCalendar(settings, startsAt, new Date(startsAt.getTime() + 12 * 3600 * 1000));
    const preferences = Array.isArray(body.preferences)
      ? body.preferences.filter((p: unknown) => typeof p === 'string').slice(0, 10) : [];
    const result = await rpc<Record<string, unknown>>(settings, 'create_group', {
      p_actor: session.user_id, p_request_id: body.requestId, p_starts_at: startsAt.toISOString(),
      p_capacity: body.capacity, p_game_id: body.gameId ?? null, p_preferences: preferences,
      p_note: typeof body.note === 'string' ? body.note : '',
      p_visibility: body.visibility === 'public' ? 'public' : 'private', p_venue: venueOf(body.venue) });
    return [result.created ? 201 : 200, { groupId: result.group_id, startsAt: result.starts_at, endsAt: result.ends_at }];
  }
  if (req.method === 'GET' && path === '/games') {
    const { session } = await requireSession(req, settings);
    const [games, played] = await Promise.all([rpc(settings, 'list_active_games', {}),
      rpc(settings, 'my_played_games', { p_actor: session.user_id })]);
    return [200, { games: camel(games), playedGameIds: played }];
  }
  if (req.method === 'GET' && path === '/me/history') {
    const { session } = await requireSession(req, settings);
    return [200, { history: camel(await rpc(settings, 'list_my_history', { p_actor: session.user_id })) }];
  }

  // ---- 老玩家綁定 and 會員卡 ----
  if (req.method === 'GET' && path === '/records/names') {
    await requireSession(req, settings);
    // After the cutover the names come from the database; before it, from the Apps Script copy.
    const [live, bound] = await Promise.all([unlessMissing(rpc<RecordSummary[] | null>(settings, 'record_names', {})),
      rpc<string[]>(settings, 'bound_record_names', {})]);
    if (live) return [200, { names: live, bound }];
    // The saved copy answers at once; a copy older than 10 minutes is refreshed after the response.
    const { summary } = await playRecordSummary(settings, 600_000, true);
    return [200, { names: summary.map(publicRecord), bound }];
  }
  // 玩後問卷從 LINE 打開：帶入綁定的名字；第一次填的新玩家取一個全新的名字直接綁定。
  // 已在玩本記錄裡的名字不能這樣取得（避免冒用別人的點數），要走老玩家綁定由店家審核。
  if (req.method === 'GET' && path === '/me/survey') {
    const { session } = await requireSession(req, settings);
    const [binding, account] = await Promise.all([
      rpc<Binding | null>(settings, 'my_binding', { p_actor: session.user_id }),
      rpc<string | null>(settings, 'my_record_account', { p_actor: session.user_id })]);
    return [200, { recordName: binding?.status === 'approved' ? binding.record_name : account,
      pendingName: binding?.status === 'pending' ? binding.record_name : null }];
  }
  if (req.method === 'POST' && path === '/me/survey/name') {
    const { session } = await requireSession(req, settings);
    const { name } = await readJson(req);
    if (typeof name !== 'string' || !name.trim() || Array.from(name.trim()).length > 30) throw new ApiError(400, 'INVALID_NAME');
    if (await recordsLive(settings)) {
      // A name that is (or, without spaces and case, matches) a player or an alias would add to someone else's points.
      if (await rpc<boolean>(settings, 'record_name_taken', { p_name: name })) throw new ApiError(409, 'NAME_EXISTS');
      const claimed = await rpc<{ record_name: string }>(settings, 'claim_record_name', { p_actor: session.user_id, p_name: name });
      return [201, { recordName: claimed.record_name }];
    }
    const wanted = name.trim().toLowerCase();
    const taken = (records: RecordData) => records.summary.some(r => r.name.trim().toLowerCase() === wanted);
    // A name not in a recent copy is checked once more against the script itself before it is given away.
    // That second read runs even when the first one failed: a cold script often answers by then.
    // A copy kept only because the script could not be read is not proof that a name is free: names added
    // since then would be handed to the wrong player, so naming waits until the script answers again.
    const recent = await playRecordSummary(settings, 600_000);
    if (taken(recent)) throw new ApiError(409, 'NAME_EXISTS');
    const latest = await playRecordSummary(settings, 0);
    if (latest.stale) throw new ApiError(503, 'RECORDS_UNAVAILABLE');
    if (taken(latest)) throw new ApiError(409, 'NAME_EXISTS');
    const claimed = await rpc<{ record_name: string }>(settings, 'claim_record_name', { p_actor: session.user_id, p_name: name });
    return [201, { recordName: claimed.record_name }];
  }
  if (path === '/me/binding' && (req.method === 'GET' || req.method === 'POST')) {
    const { session } = await requireSession(req, settings);
    if (req.method === 'POST') {
      const { name, note } = await readJson(req);
      if (typeof name !== 'string' || (note != null && typeof note !== 'string')) throw new ApiError(400, 'INVALID_NAME');
      const live = await unlessMissing(rpc<RecordSummary[] | null>(settings, 'record_names', {}));
      const listed = (records: RecordData) => records.summary.some(r => r.name === name.trim());
      if (live ? !live.some(r => r.name === name.trim())
          : !listed(await playRecordSummary(settings, 600_000)) && !listed(await playRecordSummary(settings, 0))) {
        throw new ApiError(404, 'NAME_NOT_FOUND');
      }
      return [201, { binding: camel(await rpc(settings, 'request_binding', { p_actor: session.user_id, p_name: name, p_note: note ?? '' })) }];
    }
    let binding = await rpc<Binding | null>(settings, 'my_binding', { p_actor: session.user_id });
    const live = await recordsLive(settings);
    if (binding?.status === 'approved' && binding.bonus_status === 'none' && live) {
      const pending = binding;  // the database grants it at once; a failure is retried on the next visit
      binding = await grantReturnBonus(settings, pending).catch(() => pending);
    } else if (binding?.status === 'approved' && binding.bonus_status === 'none' && settings.playRecordSecret) {
      // The Apps Script takes seconds; the card shows 「回歸禮處理中」 and the grant finishes after the response.
      const pending = binding;
      const work = grantReturnBonus(settings, pending).catch(() => pending);  // retried on the next visit
      if (settings.background) settings.background(work); else binding = await work;
    }
    let card = null, rewards: Reward[] = [];
    const recordName = binding?.status === 'approved' ? binding.record_name :
      await rpc<string | null>(settings, 'my_record_account', { p_actor: session.user_id }).catch(() => null);
    if (recordName && live) {
      const got = await rpc<{ card: RecordSummary | null; rewards: Reward[] } | null>(settings, 'record_card', { p_name: recordName });
      const r = got?.card;
      card = r ? { name: r.name, agent: r.agent, balance: r.balance, earned: r.earned, redeemed: r.redeemed, plays: r.plays,
        last: r.last, title: r.title ?? '', updatedAt: new Date((settings.now ?? Date.now)()).toISOString(), stale: false,
        refreshing: false } : null;
      rewards = got?.rewards ?? [];
    } else if (recordName) {
      const records = await playRecordSummary(settings, 300_000, true);
      const r = records.summary.find(x => x.name === recordName);
      card = r ? { name: r.name, agent: r.agent, balance: r.balance, earned: r.earned, redeemed: r.redeemed,
        plays: r.plays, last: r.last, title: r.title ?? '', updatedAt: records.fetchedAt, stale: records.stale,
        refreshing: records.refreshing === true } : null;
      rewards = records.rewards.map(x => ({ track: x.track, name: x.name, cost: x.cost, note: x.note }));
    }
    return [200, { binding: camel(binding), recordName, card, rewards }];
  }
  if (req.method === 'GET' && path === '/admin/bindings') {
    const { session } = await requireSession(req, settings);
    return [200, { bindings: camel(await rpc(settings, 'admin_list_bindings', { p_actor: session.user_id })) }];
  }
  const bindingAdmin = /^\/admin\/bindings\/([0-9a-f-]{36})\/(approve|reject|bonus)$/.exec(path);
  if (req.method === 'POST' && bindingAdmin && UUID.test(bindingAdmin[1])) {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    const [, userId, action] = bindingAdmin;
    let binding: Binding;
    if (action === 'bonus') {
      const found = (await rpc<Binding[]>(settings, 'admin_list_bindings', { p_actor: session.user_id }))
        .find(b => b.user_id === userId && b.status === 'approved');
      if (!found) throw new ApiError(404, 'BINDING_NOT_FOUND');
      binding = found;
    } else {
      binding = await rpc<Binding>(settings, 'admin_decide_binding', { p_actor: session.user_id, p_user_id: userId,
        p_approve: action === 'approve' });
    }
    let bonusError: string | null = null;
    if (binding.status === 'approved') {
      if (binding.bonus_status === 'none') {
        try { binding = await grantReturnBonus(settings, binding); }
        catch (e) { bonusError = e instanceof ApiError ? e.message : 'BONUS_FAILED'; }
      }
      if (settings.lineAccessToken) {
        const work = syncMemberMenu(settings, lineCaller(settings)).catch(() => undefined);
        if (settings.background) settings.background(work); else await work;
      }
    }
    return [200, { binding: camel(binding), bonusError }];
  }
  if (req.method === 'GET' && path === '/admin/groups') {
    const { session } = await requireSession(req, settings);
    return [200, { groups: camel(await rpc(settings, 'admin_list_groups', { p_actor: session.user_id })) }];
  }
  const confirmRoute = /^\/admin\/groups\/([0-9a-f-]{36})\/confirm$/.exec(path);
  if (req.method === 'POST' && confirmRoute && UUID.test(confirmRoute[1])) {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    const body = await readJson(req);
    const price = body.priceTwd;
    if (typeof price !== 'number' || !Number.isInteger(price) || price < 0 || price > 100000) {
      throw new ApiError(400, 'INVALID_PRICE');
    }
    if (body.gameId != null && (typeof body.gameId !== 'string' || !UUID.test(body.gameId))) {
      throw new ApiError(400, 'GAME_NOT_FOUND');
    }
    const window = await rpc<{ starts_at: string; ends_at: string; event_id?: string }>(settings,
      'admin_group_confirmation_window', { p_actor: session.user_id, p_group_id: confirmRoute[1], p_game_id: body.gameId ?? null });
    // A repeated confirmation only retries the calendar write, even if free/busy is offline
    // or the store calendar now contains this event itself.
    if (window.event_id) return [200, { eventId: window.event_id, ...(await writeCalendarEvent(settings, window.event_id)) }];
    await syncCalendar(settings, new Date(window.starts_at), new Date(window.ends_at));
    const result = await rpc<Record<string, any>>(settings, 'admin_confirm_group_event_checked', {
      p_actor: session.user_id, p_group_id: confirmRoute[1], p_venue: typeof body.venue === 'string' ? body.venue : '',
      p_dm_name: typeof body.dmName === 'string' ? body.dmName : '', p_game_id: body.gameId ?? null,
      p_price_cents: price * 100, p_starts_at: window.starts_at, p_ends_at: window.ends_at });
    return [result.created ? 201 : 200, { eventId: result.event_id, ...(await writeCalendarEvent(settings, result.event_id)) }];
  }
  const cancelRoute = /^\/admin\/events\/([0-9a-f-]{36})\/cancel$/.exec(path);
  if (req.method === 'POST' && cancelRoute && UUID.test(cancelRoute[1])) {
    const { session } = await requireSession(req, settings);
    const { reason } = await readJson(req);
    if (reason != null && (typeof reason !== 'string' || reason.length > 500)) throw new ApiError(400, 'INVALID_REASON');
    const result = await rpc<Record<string, any>>(settings, 'admin_cancel_event', {
      p_actor: session.user_id, p_event_id: cancelRoute[1], p_reason: reason ?? null });
    return [200, { cancelled: result.cancelled, refundRequired: !!result.refund_required,
      ...(await writeCalendarEvent(settings, cancelRoute[1])) }];
  }
  const eventAdmin = /^\/admin\/events\/([0-9a-f-]{36})\/(participants|complete)$/.exec(path);
  if (eventAdmin && UUID.test(eventAdmin[1])) {
    const { session } = await requireSession(req, settings);
    const actor = { p_actor: session.user_id, p_event_id: eventAdmin[1] };
    if (req.method === 'GET' && eventAdmin[2] === 'participants') {
      return [200, { participants: camel(await rpc(settings, 'admin_event_participants', actor)) }];
    }
    if (req.method === 'POST' && eventAdmin[2] === 'complete') {
      const { absent } = await readJson(req);
      const ids = Array.isArray(absent) ? absent : [];
      if (ids.length > 50 || ids.some(id => typeof id !== 'string' || !UUID.test(id))) throw new ApiError(400, 'INVALID_PARTICIPANTS');
      const result = await rpc(settings, 'admin_complete_event', { ...actor, p_absent: ids });
      // Players who just played their first recorded session switch to the member menu.
      if (settings.lineAccessToken) {
        const work = syncMemberMenu(settings, lineCaller(settings)).catch(() => undefined);
        if (settings.background) settings.background(work); else await work;
      }
      return [200, camel(result)];
    }
  }
  const calendarRoute = /^\/admin\/events\/([0-9a-f-]{36})\/calendar$/.exec(path);
  if (req.method === 'POST' && calendarRoute && UUID.test(calendarRoute[1])) {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    return [200, await writeCalendarEvent(settings, calendarRoute[1])];
  }
  if (req.method === 'GET' && path === '/admin/report') {
    const { session } = await requireSession(req, settings);
    const params = new URL(req.url).searchParams;
    const nowMs = (settings.now ?? Date.now)();
    const from = params.get('from') ? taipeiDayStart(params.get('from')!) : new Date(nowMs - 30 * 86400000);
    const to = params.get('to') ? new Date(taipeiDayStart(params.get('to')!).getTime() + 86400000) : new Date(nowMs + 60 * 86400000);
    return [200, camel(await rpc(settings, 'admin_report', { p_actor: session.user_id, p_from: from.toISOString(), p_to: to.toISOString() }))];
  }
  // ---- 角色分配問卷（網站問卷送出；店家在 LINE 看回覆、分配角色）----
  if (req.method === 'POST' && path === '/public/role-survey') {
    // The website posts text/plain JSON (a simple request: no CORS preflight), like it did to the Apps Script.
    // body.id is the website's 送出編號: a resend after a lost response is recognised instead of stored twice.
    const body = await readJson(req, 16 * 1024);
    if (typeof body.website === 'string' && body.website) return [200, { ok: true }];  // honeypot: drop silently
    await rpc(settings, 'submit_role_survey', { p_script: typeof body.script === 'string' ? body.script : '',
      p_fields: Array.isArray(body.fields) ? body.fields : [],
      p_client_id: typeof body.id === 'string' && UUID_ANY.test(body.id) ? body.id.toLowerCase() : null });
    return [201, { ok: true }];
  }
  if (req.method === 'GET' && path === '/admin/role-surveys') {
    const { session } = await requireSession(req, settings);
    return [200, { scripts: camel(await rpc(settings, 'admin_role_survey_scripts', { p_actor: session.user_id })) }];
  }
  if (req.method === 'GET' && path === '/admin/role-surveys/responses') {
    const { session } = await requireSession(req, settings);
    const params = new URL(req.url).searchParams;
    const before = params.get('before'), beforeId = params.get('beforeId');
    if ((before && Number.isNaN(Date.parse(before))) || (beforeId && !UUID.test(beforeId))) throw new ApiError(400, 'INVALID_RANGE');
    return [200, { responses: camel(await rpc(settings, 'admin_role_survey_responses', { p_actor: session.user_id,
      p_script: params.get('script') ?? '', p_limit: 30, p_before: before || null, p_before_id: before && beforeId ? beforeId : null })) }];
  }
  if (req.method === 'POST' && path === '/admin/role-surveys/import') {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    return [200, await importRoleSurveys(settings, session.user_id)];
  }
  const surveyRoute = /^\/admin\/role-surveys\/responses\/([0-9a-f-]{36})(\/delete)?$/.exec(path);
  if (req.method === 'POST' && surveyRoute && UUID.test(surveyRoute[1])) {
    const { session } = await requireSession(req, settings);
    if (surveyRoute[2]) return [200, await rpc(settings, 'admin_delete_role_survey', { p_actor: session.user_id, p_id: surveyRoute[1] })];
    const { assignedRole, storeNote } = await readJson(req);
    return [200, camel(await rpc(settings, 'admin_update_role_survey', { p_actor: session.user_id, p_id: surveyRoute[1],
      p_assigned_role: typeof assignedRole === 'string' ? assignedRole : '', p_store_note: typeof storeNote === 'string' ? storeNote : '' }))];
  }
  // ---- 玩本記錄（網站送出、按讚；店家匯入、對帳、切換）----
  // Without migration 0036 the website should go straight to the Apps Script, as before the cutover.
  const notLiveIfMissing = <T>(work: Promise<T>) =>
    work.catch(e => { throw e instanceof ApiError && e.missing ? new ApiError(503, 'RECORDS_NOT_LIVE') : e; });
  if (req.method === 'POST' && path === '/public/play-records') {
    // The website form (no login, like the Apps Script). body.id is its 送出編號: a resend is recognised.
    // Before the cutover this answers 503 RECORDS_NOT_LIVE and the website posts to the Apps Script instead.
    const body = await readJson(req, 8 * 1024);
    if (typeof body.website === 'string' && body.website) return [200, { ok: true }];  // honeypot: drop silently
    const text = (v: unknown) => typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '';
    const result = await notLiveIfMissing(rpc<Record<string, unknown>>(settings, 'submit_play_record', {
      p_record: { name: text(body.name), date: text(body.date), script: text(body.script), role: text(body.role ?? body.character),
        rating: text(body.rating), comment: text(body.comment), referrer: text(body.referrer) },
      p_client_id: typeof body.id === 'string' && UUID_ANY.test(body.id) ? body.id.toLowerCase() : null }));
    // Only what the form shows: the canonical player name would tell anyone which leaderboard name an alias belongs to.
    return [result.duplicate ? 200 : 201, { ok: true, live: true, status: result.status, award: result.award ?? null,
      ...(result.duplicate ? { duplicate: true } : {}) }];
  }
  if (req.method === 'POST' && path === '/public/likes') {
    // liker: a random ID the browser keeps, so one browser counts once per review (no login, as before).
    const body = await readJson(req, 4 * 1024);
    const text = (v: unknown) => typeof v === 'string' ? v : '';
    if (typeof body.liker !== 'string' || !UUID_ANY.test(body.liker)) throw new ApiError(400, 'INVALID_RECORD');
    return [200, { ...(await notLiveIfMissing(rpc<Record<string, unknown>>(settings, 'submit_review_like', { p_script: text(body.script),
      p_date: text(body.date), p_author: text(body.author), p_liker: body.liker.toLowerCase() }))), live: true }];
  }
  if (req.method === 'GET' && path === '/admin/records') {
    const { session } = await requireSession(req, settings);
    return [200, { ...camel(await rpc(settings, 'admin_records_status', { p_actor: session.user_id })) as object,
      serviceAccountEmail: settings.google?.clientEmail ?? null, sheetId: settings.playRecordSheetId ?? PLAY_RECORD_SHEET_ID }];
  }
  if (req.method === 'POST' && (path === '/admin/records/import' || path === '/admin/records/import-new')) {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    return [200, camel(await importPlayRecords(settings, session.user_id, path.endsWith('-new') ? 'new' : 'full'))];
  }
  if (req.method === 'GET' && path === '/admin/records/reconcile') {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    // Compare against the Apps Script's summary as it is right now (a stale copy is said to be stale).
    const fresh = await playRecordSummary(settings, 0).then(r => !r.stale, () => false);
    return [200, { ...(await rpc<Record<string, unknown>>(settings, 'admin_records_reconcile', { p_actor: session.user_id })),
      snapshotFresh: fresh }];
  }
  if (req.method === 'POST' && path === '/admin/records/source') {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    const { source, force } = await readJson(req);
    if (source !== 'gas' && source !== 'supabase') throw new ApiError(400, 'INVALID_SOURCE');
    // The first switch compares against the Apps Script's summary as it is now (RECONCILE_STALE if it cannot be read):
    // a 兌換 typed into the sheet after the import would otherwise be lost.
    if (source === 'supabase' && force !== true) await playRecordSummary(settings, 0).catch(() => undefined);
    recordCache = null;
    return [200, camel(await rpc(settings, 'admin_set_records_source', { p_actor: session.user_id, p_source: source,
      p_force: force === true }))];
  }
  // ---- 第 3 階段：兌換、補點扣點、作廢、隱藏、精選、別名、合併、設定、月報（寫入在切換後；資料庫檢查店家身分）----
  if (path === '/me/redemptions' && (req.method === 'GET' || req.method === 'POST')) {
    const { session } = await requireSession(req, settings);
    if (req.method === 'GET') return [200, camel(await rpc(settings, 'my_redemptions', { p_actor: session.user_id }))];
    const { rewardId, title, requestId } = await readJson(req);
    if (typeof rewardId !== 'string' || !UUID.test(rewardId)) throw new ApiError(400, 'REWARD_NOT_FOUND');
    return [201, camel(await rpc(settings, 'request_redemption', { p_actor: session.user_id, p_reward_id: rewardId,
      p_title: typeof title === 'string' ? title : '', p_request_key: typeof requestId === 'string' && UUID_ANY.test(requestId)
        ? `me:${session.user_id}:${requestId.toLowerCase()}` : null }))];
  }
  const myRedemption = /^\/me\/redemptions\/([0-9a-f-]{36})\/cancel$/.exec(path);
  if (req.method === 'POST' && myRedemption && UUID.test(myRedemption[1])) {
    const { session } = await requireSession(req, settings);
    return [200, camel(await rpc(settings, 'cancel_redemption', { p_actor: session.user_id, p_id: myRedemption[1] }))];
  }
  if (req.method === 'GET' && path === '/admin/redemptions') {
    const { session } = await requireSession(req, settings);
    return [200, camel(await rpc(settings, 'admin_redemptions', { p_actor: session.user_id }))];
  }
  const decide = /^\/admin\/redemptions\/([0-9a-f-]{36})\/(approve|reject)$/.exec(path);
  if (req.method === 'POST' && decide && UUID.test(decide[1])) {
    const { session } = await requireSession(req, settings);
    const { title, note } = await readJson(req);
    return [200, camel(await rpc(settings, 'admin_decide_redemption', { p_actor: session.user_id, p_id: decide[1],
      p_approve: decide[2] === 'approve', p_title: typeof title === 'string' ? title : '', p_note: typeof note === 'string' ? note : '' }))];
  }
  if (req.method === 'GET' && path === '/admin/players') {
    const { session } = await requireSession(req, settings);
    const params = new URL(req.url).searchParams;
    const name = params.get('name');
    if (name != null) return [200, camel(await rpc(settings, 'admin_player', { p_actor: session.user_id, p_name: name.slice(0, 60) }))];
    return [200, { players: camel(await rpc(settings, 'admin_players', { p_actor: session.user_id, p_query: (params.get('q') ?? '').slice(0, 60) })) }];
  }
  if (req.method === 'POST' && path.startsWith('/admin/players/')) {
    const { session } = await requireSession(req, settings);
    const body = await readJson(req);
    const text = (v: unknown) => typeof v === 'string' ? v : '';
    const key = typeof body.requestId === 'string' && UUID_ANY.test(body.requestId) ? `admin:${body.requestId.toLowerCase()}` : null;
    const actor = { p_actor: session.user_id };
    switch (path) {
      case '/admin/players/adjust':
        if (!Number.isInteger(body.points)) throw new ApiError(400, 'INVALID_POINTS');
        return [200, camel(await rpc(settings, 'admin_adjust_points', { ...actor, p_player: text(body.name), p_points: body.points,
          p_reason: text(body.reason), p_request_key: key }))];
      case '/admin/players/redeem':
        if (typeof body.rewardId !== 'string' || !UUID.test(body.rewardId)) throw new ApiError(400, 'REWARD_NOT_FOUND');
        return [200, camel(await rpc(settings, 'admin_redeem', { ...actor, p_player: text(body.name), p_reward_id: body.rewardId,
          p_title: text(body.title), p_note: text(body.note), p_request_key: key }))];
      case '/admin/players/glory':
        return [200, camel(await rpc(settings, 'admin_set_glory', { ...actor, p_player: text(body.name), p_gilded: body.gilded === true,
          p_title: text(body.title), p_legend: body.legend === true }))];
      case '/admin/players/alias':
        return [200, camel(await rpc(settings, 'admin_set_alias', { ...actor, p_player: text(body.name), p_alias: text(body.alias),
          p_remove: body.remove === true }))];
      case '/admin/players/merge':
        return [200, camel(await rpc(settings, 'admin_merge_players', { ...actor, p_from: text(body.from), p_into: text(body.into) }))];
    }
  }
  const voidRoute = /^\/admin\/ledger\/([0-9a-f-]{36})\/void$/.exec(path);
  if (req.method === 'POST' && voidRoute && UUID.test(voidRoute[1])) {
    const { session } = await requireSession(req, settings);
    const { reason } = await readJson(req);
    return [200, camel(await rpc(settings, 'admin_void_ledger', { p_actor: session.user_id, p_ledger_id: voidRoute[1],
      p_reason: typeof reason === 'string' ? reason : '' }))];
  }
  if (req.method === 'GET' && path === '/admin/reviews') {
    const { session } = await requireSession(req, settings);
    const params = new URL(req.url).searchParams;
    const before = params.get('before'), beforeId = params.get('beforeId');
    if ((before && Number.isNaN(Date.parse(before))) || (beforeId && !UUID.test(beforeId))) throw new ApiError(400, 'INVALID_RANGE');
    return [200, { reviews: camel(await rpc(settings, 'admin_reviews', { p_actor: session.user_id, p_script: (params.get('script') ?? '').slice(0, 100),
      p_before: before || null, p_before_id: before && beforeId ? beforeId : null })) }];
  }
  const reviewRoute = /^\/admin\/reviews\/([0-9a-f-]{36})\/(hide|feature)$/.exec(path);
  if (req.method === 'POST' && reviewRoute && UUID.test(reviewRoute[1])) {
    const { session } = await requireSession(req, settings);
    const body = await readJson(req);
    return [200, camel(reviewRoute[2] === 'hide'
      ? await rpc(settings, 'admin_hide_record', { p_actor: session.user_id, p_record_id: reviewRoute[1], p_hide: body.hidden !== false,
          p_reason: typeof body.reason === 'string' ? body.reason : '' })
      : await rpc(settings, 'admin_feature_record', { p_actor: session.user_id, p_record_id: reviewRoute[1], p_featured: body.featured !== false }))];
  }
  if (path === '/admin/record-settings' && (req.method === 'GET' || req.method === 'POST')) {
    const { session } = await requireSession(req, settings);
    if (req.method === 'GET') return [200, camel(await rpc(settings, 'admin_record_settings', { p_actor: session.user_id }))];
    const body = await readJson(req);
    const text = (v: unknown) => typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '';
    if (body.type === 'setting') {
      return [200, camel(await rpc(settings, 'admin_save_setting', { p_actor: session.user_id, p_key: text(body.key), p_value: text(body.value) }))];
    }
    if (body.type === 'reward') {
      if (body.id != null && (typeof body.id !== 'string' || !UUID.test(body.id))) throw new ApiError(400, 'REWARD_NOT_FOUND');
      if (!Number.isInteger(body.cost)) throw new ApiError(400, 'INVALID_REWARD');
      return [200, camel(await rpc(settings, 'admin_save_reward', { p_actor: session.user_id, p_id: body.id ?? null, p_track: text(body.track),
        p_name: text(body.name), p_cost: body.cost, p_note: text(body.note), p_active: body.active !== false,
        p_sort: Number.isInteger(body.sort) ? body.sort : null }))];
    }
    if (body.type === 'quest') {
      if (!Number.isInteger(body.goal) || !Number.isInteger(body.points)) throw new ApiError(400, 'INVALID_QUEST');
      return [200, camel(await rpc(settings, 'admin_save_quest', { p_actor: session.user_id, p_id: text(body.id), p_label: text(body.label),
        p_goal: body.goal, p_points: body.points, p_active: body.active !== false }))];
    }
    throw new ApiError(400, 'INVALID_SETTING');
  }
  if (req.method === 'GET' && path === '/admin/records/report') {
    const { session } = await requireSession(req, settings);
    return [200, { months: camel(await rpc(settings, 'admin_records_report', { p_actor: session.user_id })) }];
  }
  if (req.method === 'POST' && path === '/admin/richmenu/store') {
    // The store's own OA gets its menu (兌換審核, 玩家點數, …); needs LINE_ADMIN_CHANNEL_ACCESS_TOKEN.
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    return [200, await setupStoreRichMenu(settings)];
  }
  if (req.method === 'GET' && path === '/admin/google-account') {
    // Which service account a spreadsheet must be shared with before it can be imported.
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    return [200, { serviceAccountEmail: settings.google?.clientEmail ?? null, projectId: settings.google?.projectId ?? null }];
  }
  if (req.method === 'GET' && path === '/admin/line-health') {
    // Can each OA reach this admin? LINE's profile API answers 200 only for a friend of that OA whose
    // user ID belongs to the same provider.
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    const identity = await rpc<{ line_user_id?: string } | null>(settings, 'user_line_identity', { p_user_id: session.user_id });
    const probe = async (token?: string) => {
      if (!token) return 'not_configured';
      if (!identity?.line_user_id) return 'unreachable';
      try {
        const r = await (settings.fetcher ?? fetch)(`https://api.line.me/v2/bot/profile/${identity.line_user_id}`,
          { signal: AbortSignal.timeout(8000), headers: { Authorization: `Bearer ${token}` } });
        return r.ok ? 'ok' : r.status === 404 ? 'unreachable' : r.status === 401 ? 'bad_token' : 'error';
      } catch { return 'error'; }
    };
    const [playerOa, adminOa] = await Promise.all([probe(settings.lineAccessToken), probe(settings.adminLineAccessToken)]);
    return [200, { playerOa, adminOa }];
  }
  if (req.method === 'POST' && path === '/admin/games/sync') {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    const games = await fetchCatalog(settings, settings.catalogUrl ?? CATALOG_URL);
    return [200, camel(await rpc(settings, 'admin_sync_games', { p_actor: session.user_id, p_games: games }))];
  }
  if (req.method === 'POST' && path === '/hooks/tick') {
    // pg_cron calls this every 5 minutes with a one-time token that only the database can issue (0034).
    const token = req.headers.get('x-tick-token') ?? '';
    if (!/^[0-9a-f]{64}$/.test(token) ||
        !(await rpc<boolean>(settings, 'consume_tick_token', { p_token_hash: await sha256Hex(token) }))) {
      throw new ApiError(401, 'INVALID_TOKEN');
    }
    const work = runScheduledWork(settings).catch(() => undefined);
    if (settings.background) settings.background(work); else await work;
    return [202, { ok: true }];
  }
  if (req.method === 'POST' && path === '/hooks/richmenu-setup') {
    if (!settings.catalogSyncSecret) throw new ApiError(503, 'SYNC_NOT_CONFIGURED');
    if (!(await sameSecret(req.headers.get('x-sync-secret') ?? '', settings.catalogSyncSecret))) {
      throw new ApiError(401, 'INVALID_SECRET');
    }
    return [200, await setupRichMenu(settings)];
  }
  if (req.method === 'POST' && path === '/hooks/selftest-race') {
    // P6 acceptance on the live database: many simultaneous requests for one last seat
    // (or one time range). Only synthetic players and a qa-stress-* script are accepted.
    if (!settings.catalogSyncSecret) throw new ApiError(503, 'SYNC_NOT_CONFIGURED');
    if (!(await sameSecret(req.headers.get('x-sync-secret') ?? '', settings.catalogSyncSecret))) {
      throw new ApiError(401, 'INVALID_SECRET');
    }
    const body = await readJson(req);
    if (body.auto === true) {  // use the synthetic targets prepared by race_setup.sql
      const t = await rpc<Record<string, any> | null>(settings, 'selftest_targets', {});
      if (!t) throw new ApiError(404, 'SELFTEST_NOT_PREPARED');
      Object.assign(body, { gameId: t.game_id, eventId: t.event_id, userIds: t.user_ids });
    }
    const userIds = Array.isArray(body.userIds) ? body.userIds.filter((u: unknown) => typeof u === 'string' && UUID.test(u)) : [];
    const gameId = typeof body.gameId === 'string' && UUID.test(body.gameId) ? body.gameId : null;
    const eventId = typeof body.eventId === 'string' && UUID.test(body.eventId) ? body.eventId : null;
    if (!gameId || !userIds.length || (body.mode === 'booking' && !eventId)) throw new ApiError(400, 'INVALID_SELFTEST');
    const allowed = await rpc<boolean>(settings, 'selftest_targets_ok',
      { p_user_ids: userIds, p_game_id: gameId, p_event_id: eventId });
    if (!allowed) throw new ApiError(403, 'SELFTEST_TARGETS_REJECTED');
    const attempt = (u: string) => body.mode === 'booking'
      ? rpc(settings, 'join_event', { p_actor: u, p_event_id: eventId, p_request_id: crypto.randomUUID() })
      : rpc(settings, 'create_group', { p_actor: u, p_request_id: crypto.randomUUID(), p_starts_at: body.startsAt,
          p_capacity: 2, p_game_id: null });  // the test script stays hidden (inactive)
    const results = await Promise.allSettled(userIds.map(attempt));
    const errors: Record<string, number> = {};
    for (const r of results) if (r.status === 'rejected') {
      const code = r.reason instanceof ApiError ? r.reason.message : 'UNKNOWN';
      errors[code] = (errors[code] ?? 0) + 1;
    }
    return [200, { mode: body.mode, attempts: results.length,
      succeeded: results.filter(r => r.status === 'fulfilled').length, errors }];
  }
  if (req.method === 'POST' && path === '/hooks/catalog-sync') {
    if (!settings.catalogSyncSecret) throw new ApiError(503, 'SYNC_NOT_CONFIGURED');
    if (!(await sameSecret(req.headers.get('x-sync-secret') ?? '', settings.catalogSyncSecret))) {
      throw new ApiError(401, 'INVALID_SECRET');
    }
    const { commit } = await readJson(req);
    if (typeof commit !== 'string' || !/^[0-9a-f]{40}$/.test(commit)) throw new ApiError(400, 'INVALID_COMMIT');
    const games = await fetchCatalog(settings, (settings.catalogCommitUrl ?? CATALOG_COMMIT_URL).replace('{commit}', commit));
    return [200, camel(await rpc(settings, 'system_sync_games', { p_games: games, p_commit: commit }))];
  }
  if (req.method === 'GET' && path === '/groups/public') {
    await requireSession(req, settings);
    return [200, { groups: camel(await rpc(settings, 'list_public_groups', {})) }];
  }
  if (req.method === 'GET' && path === '/me/groups') {
    const { session } = await requireSession(req, settings);
    return [200, { groups: camel(await rpc(settings, 'list_my_groups', { p_actor: session.user_id })) }];
  }
  if (req.method === 'POST' && (path === '/invites/preview' || path === '/invites/claim')) {
    const { session } = await requireSession(req, settings);
    const hash = await sha256Hex(inviteToken(await readJson(req)));
    const name = path === '/invites/preview' ? 'preview_invite' : 'claim_invite';
    if (name === 'claim_invite') await requireFriend(settings, session.user_id);
    return [200, camel(await rpc(settings, name, { p_actor: session.user_id, p_token_hash: hash }))];
  }
  const groupRoute = /^\/groups\/([0-9a-f-]{36})(?:\/(share-link|reserve|join|cancel|visibility|venue|played))?$/.exec(path);
  if (groupRoute && UUID.test(groupRoute[1])) {
    const { session } = await requireSession(req, settings);
    const [, groupId, action] = groupRoute;
    const actor = { p_actor: session.user_id, p_group_id: groupId };
    if (req.method === 'GET' && !action) return [200, camel(await rpc(settings, 'get_group', actor))];
    // Keys are game IDs, so this map is returned as-is rather than camelCased.
    if (req.method === 'GET' && action === 'played') return [200, { played: await rpc(settings, 'group_played_games', actor) }];
    if (req.method === 'POST' && action === 'share-link') {
      const token = newToken();
      await rpc(settings, 'create_group_invite', { ...actor, p_token_hash: await sha256Hex(token),
        p_expires_at: inviteExpiry(settings) });
      return [201, { token }];
    }
    if (req.method === 'POST' && action === 'reserve') {
      const { displayName } = await readJson(req);
      if (typeof displayName !== 'string') throw new ApiError(400, 'INVALID_NAME');
      const token = newToken();
      const seat = await rpc<Record<string, unknown>>(settings, 'reserve_group_seat', { ...actor,
        p_display_name: displayName, p_token_hash: await sha256Hex(token), p_expires_at: inviteExpiry(settings) });
      return [201, { token, seatNumber: seat.seat_number }];
    }
    if (req.method === 'POST' && action === 'join') {
      await requireFriend(settings, session.user_id);
      return [200, camel(await rpc(settings, 'join_group', actor))];
    }
    if (req.method === 'POST' && action === 'cancel') return [200, camel(await rpc(settings, 'cancel_group', actor))];
    if (req.method === 'POST' && action === 'venue') {
      const { venue } = await readJson(req);
      return [200, camel(await rpc(settings, 'set_group_venue', { ...actor, p_venue: venueOf(venue) }))];
    }
    if (req.method === 'POST' && action === 'visibility') {
      const { visibility } = await readJson(req);
      if (visibility !== 'public' && visibility !== 'private') throw new ApiError(400, 'INVALID_VISIBILITY');
      return [200, camel(await rpc(settings, 'set_group_visibility', { ...actor, p_visibility: visibility }))];
    }
  }
  const seatRoute = /^\/seats\/([0-9a-f-]{36})\/leave$/.exec(path);
  if (req.method === 'POST' && seatRoute && UUID.test(seatRoute[1])) {
    const { session } = await requireSession(req, settings);
    return [200, camel(await rpc(settings, 'leave_group_seat', { p_actor: session.user_id, p_group_member_id: seatRoute[1] }))];
  }
  if (req.method === 'POST' && path === '/auth/logout') {
    const { hash } = await requireSession(req, settings);
    await rpc(settings, 'logout_session', { p_session_hash: hash });
    return [200, { ok: true }];
  }
  throw new ApiError(404, 'ROUTE_NOT_FOUND');
}

export async function handleApi(req: Request, settings: Settings): Promise<Response> {
  // Supabase serves this function at /functions/v1/api/...; strip everything up to "/api".
  const path = new URL(req.url).pathname.replace(/^.*?\/api(?=\/|$)/, '') || '/';
  // The website's public routes (role survey, 玩本記錄, likes, points summary) are readable from any origin: CORS does
  // not protect a simple POST anyway, and a page that cannot read a successful answer would resend it to the old
  // Apps Script (a duplicate). They carry no login and return only public data or {ok}.
  const openPublic = path.startsWith('/public/');
  const cors = openPublic ? { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET, POST',
    'Access-Control-Allow-Headers': 'content-type', 'Access-Control-Max-Age': '600' } : corsHeaders(req, settings);
  const reply = (status: number, data: unknown) => new Response(JSON.stringify(data), {
    status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: cors['Access-Control-Allow-Origin'] ? 204 : 403, headers: cors });
  }
  if (req.method === 'GET' && path === '/health/records') {
    // Public like /health/calendar: says whether the website's 玩本記錄 summary is readable, never its content.
    // Diagnostic only: when the switch cannot be read, report on the Apps Script as before. After the switch,
    // actually read the points (a missing grant or a broken function shows here, not only in the website).
    if (settings.supabaseUrl && settings.serviceKey && await recordsLive(settings).catch(() => false)) {
      const payload = await rpc<{ summary?: unknown[] } | null>(settings, 'public_records_payload', {}).catch(() => null);
      return payload?.summary ? reply(200, { ok: true, source: 'supabase', players: payload.summary.length })
        : reply(503, { ok: false, source: 'supabase', error: 'RECORDS_UNAVAILABLE' });
    }
    try {
      const { summary, rewards, stale } = await playRecordSummary(settings, 0);
      if (stale) return reply(503, { ok: false, error: lastRecordError, players: summary.length, servedFromCopy: true });
      return reply(200, { ok: true, players: summary.length, rewards: rewards.length });
    } catch { return reply(503, { ok: false, error: lastRecordError || 'RECORDS_UNAVAILABLE' }); }
  }
  if (req.method === 'GET' && path === '/public/play-records') {
    // The review list for the honour wall and script pages (replaces the published CSV). Before the cutover:
    // 503 {live:false} and the website reads the CSV. Only the columns the pages show; no times or referrers.
    if (!settings.supabaseUrl || !settings.serviceKey) return reply(503, { ok: false, live: false, error: 'API_NOT_CONFIGURED' });
    const script = new URL(req.url).searchParams.get('script');
    let records: unknown[] | null;
    try {
      records = await unlessMissing(rpc<unknown[] | null>(settings, 'public_play_records', { p_script: script ? script.slice(0, 100) : null }));
    } catch {
      // Not live:false: after the cutover the website must not take this for "use the CSV" (it lacks every new review).
      return reply(503, { ok: false, error: 'RECORDS_UNAVAILABLE' });
    }
    if (!records) return reply(503, { ok: false, live: false, error: 'RECORDS_NOT_LIVE' });
    return new Response(JSON.stringify({ ok: true, live: true, updatedAt: new Date((settings.now ?? Date.now)()).toISOString(), records }),
      { status: 200, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=30' } });
  }
  if (path === '/public/records' && req.method === 'GET') {
    const open = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET', Vary: 'Origin' };
    if (!settings.supabaseUrl || !settings.serviceKey) return reply(503, { ok: false, error: 'API_NOT_CONFIGURED' });
    try {
      return new Response(JSON.stringify(await publicRecordsPayload(settings)), { status: 200, headers: { ...open,
        'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=30' } });
    } catch {
      return new Response(JSON.stringify({ ok: false, error: 'RECORDS_UNAVAILABLE' }), { status: 503,
        headers: { ...open, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
    }
  }
  if (req.method === 'POST' && path === '/hooks/records-changed') {
    // Sent by the Apps Script after it recalculates points; it holds BOOKING_SECRET = PLAY_RECORD_SECRET.
    if (!settings.playRecordSecret || !settings.supabaseUrl || !settings.serviceKey ||
        !(await sameSecret(req.headers.get('x-play-record-secret') ?? '', settings.playRecordSecret))) {
      return reply(401, { error: 'INVALID_SECRET' });
    }
    recordCache = null;
    const work = refreshRecordCopy(settings);
    if (settings.background) settings.background(work); else await work;
    return reply(202, { ok: true });
  }
  if (req.method === 'GET' && path === '/health/calendar') {
    const [status, data] = await checkCalendar(settings);
    return reply(status, data);
  }
  if (!settings.loginChannelId || !settings.supabaseUrl || !settings.serviceKey) {
    return reply(503, { error: 'API_NOT_CONFIGURED' });
  }
  try {
    const [status, data] = await route(req, path, settings);
    if (req.method === 'POST' && status < 300 && settings.lineAccessToken && !/^\/(hooks|public)\//.test(path)) {
      const work = deliverNotifications(settings).catch(() => undefined);
      if (settings.background) settings.background(work); else await work;
    }
    return reply(status, data);
  } catch (error) {
    // The website's 玩本記錄 routes tell it to keep using the Apps Script until the store switches.
    if (error instanceof ApiError && openPublic) return reply(error.status, { ok: false, error: error.message,
      ...(error.message === 'RECORDS_NOT_LIVE' ? { live: false } : {}) });
    if (error instanceof ApiError) return reply(error.status, { error: error.message });
    return reply(500, { error: 'INTERNAL_ERROR' });
  }
}

// Node imports this module for tests; only Deno starts the HTTP listener.
if (typeof Deno !== 'undefined') {
  Deno.serve((req: Request) => handleApi(req, {
    loginChannelId: Deno.env.get('LINE_LOGIN_CHANNEL_ID'),
    supabaseUrl: Deno.env.get('SUPABASE_URL'),
    serviceKey: Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'),
    allowedOrigins: (Deno.env.get('ALLOWED_ORIGINS') ?? '').split(',').map(s => s.trim()).filter(Boolean),
    google: googleFromEnv(),
    catalogSyncSecret: Deno.env.get('CATALOG_SYNC_SECRET') || undefined,
    playRecordUrl: Deno.env.get('PLAY_RECORD_URL') || undefined,
    playRecordSecret: Deno.env.get('PLAY_RECORD_SECRET') || undefined,
    lineAccessToken: Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') || undefined,
    adminLineAccessToken: Deno.env.get('LINE_ADMIN_CHANNEL_ACCESS_TOKEN') || undefined,
    liffId: Deno.env.get('LIFF_ID') || undefined,
    // deno-lint-ignore no-explicit-any
    background: (work: Promise<unknown>) => (globalThis as any).EdgeRuntime?.waitUntil?.(work),
    icsUrls: (Deno.env.get('BUSY_ICS_URLS') ?? '').split(/[\s,]+/).filter(u => /^https:\/\//.test(u)),
  }));
}
function googleFromEnv() {
  try {
    const account = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT_JSON') ?? '');
    const calendarId = Deno.env.get('GOOGLE_CALENDAR_ID');
    if (!account.client_email || !account.private_key || !calendarId) return undefined;
    return { clientEmail: account.client_email, privateKey: account.private_key, calendarId, projectId: account.project_id,
      eventsCalendarId: Deno.env.get('GOOGLE_EVENTS_CALENDAR_ID') || undefined };
  } catch { return undefined; }
}
