const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1215: dict-media.js is a content script shared verbatim between the app
// popup (assets/popup) and the extension (vendor/). It declares top-level
// functions with no module.exports, so load it into a fresh VM context where we
// control the `window` global that gates extension vs app behaviour.
const VENDOR = path.join(__dirname, 'vendor', 'dict-media.js');
const src = fs.readFileSync(VENDOR, 'utf8');

function load(windowObj) {
  const ctx = { window: windowObj };
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return ctx;
}

test('app environment (no config) keeps the image:// scheme', () => {
  const ctx = load({}); // window.__hibikiDictMedia unset -> app path
  const out = ctx.rewriteDictionaryMediaPath('gaiji/foo.svg', '明鏡');
  assert.strictEqual(
    out,
    'image://?dictionary=' + encodeURIComponent('明鏡') + '&path=' + encodeURIComponent('gaiji/foo.svg'),
  );
});

test('extension environment rewrites to the http media endpoint with token', () => {
  const ctx = load({ __hibikiDictMedia: { base: 'http://127.0.0.1:19633', token: 'secret-tok' } });
  const out = ctx.rewriteDictionaryMediaPath('gaiji/foo.svg', '明鏡');
  assert.strictEqual(
    out,
    'http://127.0.0.1:19633/api/media/dictionary'
      + '?dictionary=' + encodeURIComponent('明鏡')
      + '&path=' + encodeURIComponent('gaiji/foo.svg')
      + '&token=' + encodeURIComponent('secret-tok'),
  );
});

test('incomplete extension config falls back to image://', () => {
  // Missing token -> cannot authenticate; must not emit a broken http URL.
  const ctx = load({ __hibikiDictMedia: { base: 'http://127.0.0.1:19633', token: '' } });
  const out = ctx.rewriteDictionaryMediaPath('accent/1.svg', 'NHK');
  assert.ok(out.startsWith('image://'), 'expected image:// fallback, got ' + out);
});

test('absolute / scheme paths are left alone (returns null)', () => {
  const ctx = load({ __hibikiDictMedia: { base: 'http://127.0.0.1:19633', token: 't' } });
  assert.strictEqual(ctx.rewriteDictionaryMediaPath('https://example.com/x.png', 'D'), null);
  assert.strictEqual(ctx.rewriteDictionaryMediaPath('data:image/svg+xml;base64,AAA', 'D'), null);
});

test('backslashes and leading ./ are normalized before rewriting', () => {
  const ctx = load({ __hibikiDictMedia: { base: 'http://h:1', token: 't' } });
  const bs = String.fromCharCode(92); // build backslash without a literal escape
  const out = ctx.rewriteDictionaryMediaPath('.' + bs + 'sub' + bs + 'a.svg', 'D');
  assert.ok(out.includes('path=' + encodeURIComponent('sub/a.svg')), out);
});
