import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const html = readFileSync(new URL('../web/liff/index.html', import.meta.url), 'utf8');

test('the LIFF page script parses (a syntax error would blank the page for every player)', () => {
  const inline = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  assert.equal(inline.length, 1);
  assert.doesNotThrow(() => new vm.Script(inline[0], { filename: 'web/liff/index.html' }));
});

test('the LIFF page loads only the LINE SDK and its own config', () => {
  const external = [...html.matchAll(/<script src="([^"]+)"/g)].map(m => m[1]);
  assert.deepEqual(external, ['https://static.line-scdn.net/liff/edge/2/sdk.js', 'config.js']);
});

test('every Rich Menu view opens a page the LIFF app routes to', async () => {
  const { richMenuDefinition, storeRichMenuDefinition } = await import('../supabase/functions/api/index.ts');
  const views = [...['new', 'member'].flatMap(k => richMenuDefinition(k, 'X').areas), ...storeRichMenuDefinition('X').areas]
    .map(a => a.action.uri)
    .filter(u => u.startsWith('https://liff.line.me/')).map(u => new URL(u).searchParams.get('view')).filter(Boolean);
  assert.ok(views.length >= 5);
  for (const v of new Set(views)) {
    assert.match(html, new RegExp(String.raw`'${v}'[^\n]*\]\.includes\(view\)`), `?view=${v} not moved into the hash`);
    assert.ok(html.includes(`h === '#/${v}'`), `#/${v} has no route`);
  }
});

test('script filters are the website\'s 7 core tags, matched exactly (starfishlarp scripts-data.js FILTER_TYPES)', () => {
  const inline = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const list = /const TAG_FILTERS = (\[[^\]]*\]);/.exec(inline);
  assert.ok(list, 'TAG_FILTERS not found');
  assert.deepEqual(JSON.parse(list[1].replace(/'/g, '"')), ['情感', '推理', '陣營', '歡樂', '微恐', '新手', '繁體']);
  assert.match(inline, /const tagMatch = g => !state\.tag \|\| \(g\.genres \|\| \[\]\)\.includes\(state\.tag\);/);
});

// Runs the page script against a fake browser opened from a website 立即預約 link, with no saved session.
async function openLiff(search, { idToken = 'id-token', authStatus = 200 } = {}) {
  const inline = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const loc = new URL(`https://cj2vum4.github.io/starfish-booking-system/${search}`);
  const logins = [], storage = new Map();
  const el = () => ({ textContent: '', innerHTML: '', hidden: true, addEventListener() {}, style: {}, querySelectorAll: () => [] });
  const ctx = {
    window: { STARFISH_CONFIG: { LIFF_ID: 'X', API_BASE: 'https://api.example' }, addEventListener() {}, scrollTo() {} },
    document: { getElementById: el, addEventListener() {}, hidden: false, querySelector: () => null, querySelectorAll: () => [] },
    location: { get href() { return loc.href; }, get pathname() { return loc.pathname; }, get search() { return loc.search; },
      get hash() { return loc.hash; }, set hash(h) { loc.hash = h; }, replace() {} },
    history: { replaceState(_s, _t, url) { loc.href = new URL(url, loc.href).href; } },
    liff: { init: async () => {}, isLoggedIn: () => true, getIDToken: () => idToken, login: o => logins.push(o?.redirectUri),
      logout() {}, getFriendship: async () => ({ friendFlag: true }), isInClient: () => false },
    sessionStorage: { getItem: k => storage.get(k) ?? null, setItem: (k, v) => storage.set(k, v), removeItem: k => storage.delete(k) },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    fetch: async url => url.endsWith('/auth/line')
      ? Response.json(authStatus === 200 ? { sessionToken: 't', user: { displayName: 'x' } } : { error: 'INVALID_ID_TOKEN' }, { status: authStatus })
      : new Promise(() => {}),  // page data never arrives: only the sign-in path is under test
    URLSearchParams, URL, Intl, Date, Math, JSON, Promise, console, setTimeout, clearTimeout, Response, crypto,
    navigator: { userAgent: 'node' },
  };
  ctx.window.window = ctx.window;
  vm.createContext(ctx);
  vm.runInContext(inline, ctx);
  await new Promise(r => setTimeout(r, 50));
  return { logins, url: loc.href };
}

test('website 立即預約 links keep ?game= through a LINE login round trip', async () => {
  const link = '?view=create&game=wangzuo';
  for (const opts of [{ idToken: null }, { authStatus: 401 }]) {  // no ID token yet / a stale one
    const { logins } = await openLiff(link, opts);
    assert.equal(logins.length, 1, JSON.stringify(opts));
    assert.equal(new URL(logins[0]).search, link, `${JSON.stringify(opts)}: comes back with the script preselected`);
  }
  const signedIn = await openLiff(link);
  assert.equal(signedIn.logins.length, 0);
  assert.ok(signedIn.url.endsWith('/#/create') && !signedIn.url.includes('game='), 'the address bar is tidied once signed in');
});
