// No external runtime dependencies. Shared by Supabase Deno and Node 24 tests.
type Settings = {
  loginChannelId?: string;
  supabaseUrl?: string;
  serviceKey?: string;
  allowedOrigins?: string[];
  // Google service account with "See only free/busy" access to the owner's calendar.
  google?: { clientEmail: string; privateKey: string; calendarId: string };
  catalogUrl?: string;  // raw scripts.js in the Starfish site repo
  catalogSiteBase?: string;  // where that repo's pages are published
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
    scope: 'https://www.googleapis.com/auth/calendar.freebusy', aud: 'https://oauth2.googleapis.com/token',
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
    return [200, { ok: true }];
  } catch { return [503, { ok: false, error: 'CALENDAR_UNAVAILABLE' }]; }
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
  if (req.method === 'POST' && path === '/admin/games/sync') {
    const { session } = await requireSession(req, settings);
    if (!session.is_admin) throw new ApiError(403, 'NOT_ADMIN');
    let source: string;
    try {
      const response = await (settings.fetcher ?? fetch)(settings.catalogUrl ?? CATALOG_URL,
        { signal: AbortSignal.timeout(8000) });
      if (!response.ok) throw new Error();
      source = await response.text();
    } catch { throw new ApiError(502, 'CATALOG_UNAVAILABLE'); }
    const games = parseStarfishCatalog(source, settings.catalogSiteBase ?? CATALOG_SITE);
    return [200, camel(await rpc(settings, 'admin_sync_games', { p_actor: session.user_id, p_games: games }))];
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
  }));
}
function googleFromEnv() {
  try {
    const account = JSON.parse(Deno.env.get('GOOGLE_SERVICE_ACCOUNT_JSON') ?? '');
    const calendarId = Deno.env.get('GOOGLE_CALENDAR_ID');
    if (!account.client_email || !account.private_key || !calendarId) return undefined;
    return { clientEmail: account.client_email, privateKey: account.private_key, calendarId };
  } catch { return undefined; }
}
