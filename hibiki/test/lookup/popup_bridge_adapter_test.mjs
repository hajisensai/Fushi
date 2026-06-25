// Unit test for assets/popup/popup_bridge_adapter.js (TODO-617).
// Run: node hibiki/test/lookup/popup_bridge_adapter_test.mjs
//
// Verifies the adapter maps window.flutter_inappwebview.callHandler onto
// chrome.webview.postMessage with a {handler, args, id} envelope, and that the
// returned Promise resolves with the parsed value when native calls
// window.__hibikiBridgeResolve(id, jsonValue).

import assert from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { runInNewContext } from 'node:vm';

const __dirname = dirname(fileURLToPath(import.meta.url));
const adapterSrc = readFileSync(
  join(__dirname, '..', '..', 'assets', 'popup', 'popup_bridge_adapter.js'),
  'utf8',
);

// Fake browser globals.
const posted = [];
const sandbox = {
  Promise,
  Array,
  JSON,
  window: { chrome: { webview: { postMessage: (m) => posted.push(m) } } },
};
runInNewContext(adapterSrc, sandbox);

// 1. callHandler posts the right envelope.
const p = sandbox.window.flutter_inappwebview.callHandler('playWordAudio', {
  term: 'favour',
});
assert.strictEqual(posted.length, 1, 'one message posted');
const env = JSON.parse(posted[0]);
assert.strictEqual(env.handler, 'playWordAudio');
assert.deepStrictEqual(env.args, [{ term: 'favour' }]);
assert.strictEqual(typeof env.__bridgeId, 'number');

// 2. native reply resolves the Promise with the parsed value.
sandbox.window.__hibikiBridgeResolve(env.__bridgeId, JSON.stringify({ url: 'a.mp3' }));
const result = await p;
assert.deepStrictEqual(result, { url: 'a.mp3' });

// 3. void / null reply resolves to null (read-only handlers — prevents freeze).
const p2 = sandbox.window.flutter_inappwebview.callHandler('mineEntry', {});
const env2 = JSON.parse(posted[1]);
sandbox.window.__hibikiBridgeResolve(env2.__bridgeId, null);
assert.strictEqual(await p2, null);

// 4. unknown id is ignored (no throw).
sandbox.window.__hibikiBridgeResolve(99999, '"x"');

console.log('popup_bridge_adapter_test: PASS');
