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
  const { richMenuDefinition } = await import('../supabase/functions/api/index.ts');
  const views = ['new', 'member'].flatMap(k => richMenuDefinition(k, 'X').areas.map(a => a.action.uri))
    .filter(u => u.startsWith('https://liff.line.me/')).map(u => new URL(u).searchParams.get('view')).filter(Boolean);
  assert.ok(views.length >= 6);
  for (const v of new Set(views)) {
    assert.match(html, new RegExp(String.raw`'${v}'[^\n]*\]\.includes\(view\)`), `?view=${v} not moved into the hash`);
    assert.ok(html.includes(`h === '#/${v}'`), `#/${v} has no route`);
  }
});
