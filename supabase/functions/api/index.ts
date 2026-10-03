// No external runtime dependencies. Shared by Supabase Deno and Node 24 tests.
type Settings = {
  loginChannelId?: string;
  supabaseUrl?: string;
  serviceKey?: string;
  allowedOrigins?: string[];
  // Google service account: "See only free/busy" on the owner's calendar (calendarId) and
  // "Make changes to events" on a dedicated store calendar (eventsCalendarId).
  google?: { clientEmail: string; privateKey: string; calendarId: string; eventsCalendarId?: string };
  icsUrls?: string[];  // published busy calendars, e.g. the owner's Outlook (capability URLs: keep secret)
  catalogUrl?: string;  // raw scripts.js in the Starfish site repo
  catalogSiteBase?: string;  // where that repo's pages are published
  catalogCommitUrl?: string;  // raw file URL template with {commit}, for the GitHub hook
  catalogSyncSecret?: string;  // shared with the starfishlarp GitHub Action
  lineAccessToken?: string;  // Messaging API channel access token, for push notifications
  liffId?: string;  // links in notifications open this LIFF app
  background?: (work: Promise<unknown>) => void;  // run after the response (EdgeRuntime.waitUntil)
  fetcher?: typeof fetch;
  now?: () => number;
};
type Session = { user_id: string; display_name: string | null; is_admin: boolean; expires_at: string };
const SESSION_HOURS = 12;
const MAX_BODY = 64 * 1024;

class ApiError extends Error {
  status: number;
  constructor(status: number, code: string) { super(code); this.status = status; }
}

// Stable RPC error codes → HTTP status. Unknown database errors stay opaque (500).
const NOT_FOUND = /_NOT_FOUND$/;
const CONFLICT = new Set(['SOLD_OUT', 'GROUP_FULL', 'ALREADY_BOOKED', 'ALREADY_MEMBER', 'ALREADY_CLAIMED',
  'INVITE_USED', 'GROUP_CLOSED', 'GROUP_CONFIRMED', 'EVENT_CLOSED', 'EVENT_STARTED', 'ORGANIZER_CANNOT_LEAVE']);
export function statusForCode(code: string) {
  if (NOT_FOUND.test(code)) return 404;
  if (CONFLICT.has(code)) return 409;
  if (code === 'NOT_ADMIN') return 403;
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

async function readJson(req: Request): Promise<Record<string, unknown>> {
  const text = await req.text();
  if (text.length > MAX_BODY) throw new ApiError(413, 'INVALID_BODY_SIZE');
  try {
    const data = JSON.parse(text || '{}');
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error();
    return data;
  } catch { throw new ApiError(400, 'INVALID_JSON'); }
}

async function rpc<T>(settings: Settings, name: string, args: Record<string, unknown>): Promise<T> {
  let response: Response;
  try {
    response = await (settings.fetcher ?? fetch)(`${settings.supabaseUrl}/rest/v1/rpc/${name}`, {
      method: 'POST', signal: AbortSignal.timeout(8000),
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
  throw new ApiError(500, 'DATABASE_ERROR');
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
    scope: 'https://www.googleapis.com/auth/calendar.freebusy https://www.googleapis.com/auth/calendar.events',
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
async function syncCalendar(settings: Settings, from: Date, to: Date) {
  if (!settings.google) throw new ApiError(503, 'CALENDAR_NOT_CONFIGURED');
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
    case 'group_confirmed':
      return `【成團確認】${game}\n${when}\n場地：${p.venue}\nDM：${p.dm_name}${price}\n詳情：${link}`;
    case 'event_cancelled':
      return `【場次取消】很抱歉，店家取消了 ${when} 的${game}`
        + (p.cancel_reason ? `\n原因：${p.cancel_reason}` : '') + `\n詳情：${link}`;
    case 'group_dissolved':
      return `【揪團解散】${p.organizer_name} 解散了 ${when} 的揪團\n詳情：${link}`;
    default:
      return null;
  }
}

// Sends queued notifications. LINE's retry key makes a resend after a timeout a no-op.
export async function deliverNotifications(settings: Settings, limit = 20) {
  if (!settings.lineAccessToken) return { sent: 0, skipped: 0, failed: 0 };
  const batch = await rpc<Record<string, any>[]>(settings, 'claim_notifications', { p_limit: limit });
  const tally = { sent: 0, skipped: 0, failed: 0 };
  for (const n of batch) {
    const text = notificationText(n.payload, settings.liffId ?? DEFAULT_LIFF_ID);
    let result: 'sent' | 'skipped' | 'failed', error: string | null = null;
    if (!text) { result = 'skipped'; error = 'UNKNOWN_KIND'; }
    else if (n.friend_status === 'blocked') { result = 'skipped'; error = 'BLOCKED'; }
    else {
      try {
        const response = await (settings.fetcher ?? fetch)('https://api.line.me/v2/bot/message/push', {
          method: 'POST', signal: AbortSignal.timeout(8000),
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${settings.lineAccessToken}`,
            'X-Line-Retry-Key': n.retry_key },
          body: JSON.stringify({ to: n.line_user_id, messages: [{ type: 'text', text: text.slice(0, 5000) }] }),
        });
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
      image_url: https(e.poster),
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

async function route(req: Request, path: string, settings: Settings): Promise<[number, unknown]> {
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
    const to = new Date(startMs + days * 86400000);
    if (to <= from) return [200, { slots: [] }];
    await syncCalendar(settings, from, to);
    const slots = await rpc<{ starts_at: string; ends_at: string }[]>(settings, 'list_available_starts',
      { p_from: from.toISOString(), p_to: to.toISOString(), p_minutes: minutes });
    return [200, { slots: slots.map(s => ({ startsAt: s.starts_at, endsAt: s.ends_at })) }];
  }
  if (req.method === 'POST' && path === '/groups') {
    const { session } = await requireSession(req, settings);
    const body = await readJson(req);
    const startsAt = typeof body.startsAt === 'string' ? new Date(body.startsAt) : null;
    if (typeof body.requestId !== 'string' || !UUID.test(body.requestId)) throw new ApiError(400, 'INVALID_REQUEST');
    if (!startsAt || Number.isNaN(startsAt.getTime())) throw new ApiError(400, 'SLOT_UNAVAILABLE');
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
      p_visibility: body.visibility === 'public' ? 'public' : 'private' });
    return [result.created ? 201 : 200, { groupId: result.group_id, startsAt: result.starts_at, endsAt: result.ends_at }];
  }
  if (req.method === 'GET' && path === '/games') {
    await requireSession(req, settings);
    return [200, { games: camel(await rpc(settings, 'list_active_games', {})) }];
  }
  if (req.method === 'GET' && path === '/admin/groups') {
    const { session } = await requireSession(req, settings);
    return [200, { groups: camel(await rpc(settings, 'admin_list_groups', { p_actor: session.user_id })) }];
  }
  const confirmRoute = /^\/admin\/groups\/([0-9a-f-]{36})\/confirm$/.exec(path);
  if (req.method === 'POST' && confirmRoute && UUID.test(confirmRoute[1])) {
    const { session } = await requireSession(req, settings);
    const body = await readJson(req);
    const price = body.priceTwd;
    if (typeof price !== 'number' || !Number.isInteger(price) || price < 0 || price > 100000) {
      throw new ApiError(400, 'INVALID_PRICE');
    }
    if (body.gameId != null && (typeof body.gameId !== 'string' || !UUID.test(body.gameId))) {
      throw new ApiError(400, 'GAME_NOT_FOUND');
    }
    const result = await rpc<Record<string, any>>(settings, 'admin_confirm_group_event', {
      p_actor: session.user_id, p_group_id: confirmRoute[1], p_venue: typeof body.venue === 'string' ? body.venue : '',
      p_dm_name: typeof body.dmName === 'string' ? body.dmName : '', p_game_id: body.gameId ?? null,
      p_price_cents: price * 100 });
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
  const calendarRoute = /^\/admin\/events\/([0-9a-f-]{36})\/calendar$/.exec(path);
  if (req.method === 'POST' && calendarRoute && UUID.test(calendarRoute[1])) {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    return [200, await writeCalendarEvent(settings, calendarRoute[1])];
  }
  if (req.method === 'POST' && path === '/admin/games/sync') {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    const games = await fetchCatalog(settings, settings.catalogUrl ?? CATALOG_URL);
    return [200, camel(await rpc(settings, 'admin_sync_games', { p_actor: session.user_id, p_games: games }))];
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
  if (req.method === 'GET' && path === '/me/groups') {
    const { session } = await requireSession(req, settings);
    return [200, { groups: camel(await rpc(settings, 'list_my_groups', { p_actor: session.user_id })) }];
  }
  if (req.method === 'POST' && (path === '/invites/preview' || path === '/invites/claim')) {
    const { session } = await requireSession(req, settings);
    const hash = await sha256Hex(inviteToken(await readJson(req)));
    const name = path === '/invites/preview' ? 'preview_invite' : 'claim_invite';
    return [200, camel(await rpc(settings, name, { p_actor: session.user_id, p_token_hash: hash }))];
  }
  const groupRoute = /^\/groups\/([0-9a-f-]{36})(?:\/(share-link|reserve|join|cancel))?$/.exec(path);
  if (groupRoute && UUID.test(groupRoute[1])) {
    const { session } = await requireSession(req, settings);
    const [, groupId, action] = groupRoute;
    const actor = { p_actor: session.user_id, p_group_id: groupId };
    if (req.method === 'GET' && !action) return [200, camel(await rpc(settings, 'get_group', actor))];
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
    if (req.method === 'POST' && action === 'join') return [200, camel(await rpc(settings, 'join_group', actor))];
    if (req.method === 'POST' && action === 'cancel') return [200, camel(await rpc(settings, 'cancel_group', actor))];
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
  const cors = corsHeaders(req, settings);
  const reply = (status: number, data: unknown) => new Response(JSON.stringify(data), {
    status, headers: { ...cors, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
  if (req.method === 'OPTIONS') return new Response(null, { status: cors['Access-Control-Allow-Origin'] ? 204 : 403, headers: cors });
  // Supabase serves this function at /functions/v1/api/...; strip everything up to "/api".
  const path = new URL(req.url).pathname.replace(/^.*?\/api(?=\/|$)/, '') || '/';
  if (req.method === 'GET' && path === '/health/calendar') {
    const [status, data] = await checkCalendar(settings);
    return reply(status, data);
  }
  if (!settings.loginChannelId || !settings.supabaseUrl || !settings.serviceKey) {
    return reply(503, { error: 'API_NOT_CONFIGURED' });
  }
  try {
    const [status, data] = await route(req, path, settings);
    if (req.method === 'POST' && status < 300 && settings.lineAccessToken) {
      const work = deliverNotifications(settings).catch(() => undefined);
      if (settings.background) settings.background(work); else await work;
    }
    return reply(status, data);
  } catch (error) {
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
    lineAccessToken: Deno.env.get('LINE_CHANNEL_ACCESS_TOKEN') || undefined,
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
    return { clientEmail: account.client_email, privateKey: account.private_key, calendarId,
      eventsCalendarId: Deno.env.get('GOOGLE_EVENTS_CALENDAR_ID') || undefined };
  } catch { return undefined; }
}
