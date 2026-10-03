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
