// No external runtime dependencies. Shared by Supabase Deno and Node 24 tests.
type Settings = {
  loginChannelId?: string;
  supabaseUrl?: string;
  serviceKey?: string;
  allowedOrigins?: string[];
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
  if (!settings.loginChannelId || !settings.supabaseUrl || !settings.serviceKey) {
    return reply(503, { error: 'API_NOT_CONFIGURED' });
  }
  // Supabase serves this function at /functions/v1/api/...; strip everything up to "/api".
  const path = new URL(req.url).pathname.replace(/^.*?\/api(?=\/|$)/, '') || '/';
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
  }));
}
