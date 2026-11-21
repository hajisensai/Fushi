// theme.js 的「独立网页」模式（fushi_server WebUI 经 web_kit.g.dart 内嵌本库）只在非扩展上下文成立：
// data-fushi-theme-host="page" 是任何网页都能写的 DOM 属性，content script 与宿主页共享 DOM 与
// localStorage，若扩展上下文也认它，宿主页就能让 content script 改读页面可控的 localStorage、
// 把主题写到宿主页 <html> 上。
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { runInNewContext } = require('node:vm');

const src = (name) => readFileSync(path.join(__dirname, name), 'utf8');

function load({ runtimeId }) {
  const rootAttrs = new Map([['data-fushi-theme-host', 'page']]);
  const html = {
    getAttribute: (k) => (rootAttrs.has(k) ? rootAttrs.get(k) : null),
    setAttribute: (k, v) => { rootAttrs.set(k, String(v)); },
    removeAttribute: (k) => { rootAttrs.delete(k); },
  };
  const local = new Map([['fushi-theme:extensionTheme', JSON.stringify('light')]]);
  const scope = {
    console,
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    location: { protocol: 'https:' },
    localStorage: {
      getItem: (k) => (local.has(k) ? local.get(k) : null),
      setItem: (k, v) => { local.set(k, String(v)); },
    },
    addEventListener() {},
    document: {
      documentElement: html,
      head: { appendChild() {} },
      getElementById: () => null,
      createElement: () => ({ setAttribute() {}, appendChild() {} }),
      createTextNode: () => ({}),
    },
  };
  scope.window = scope;
  const sets = [];
  scope.chrome = {
    runtime: runtimeId ? { id: runtimeId } : {},
    storage: {
      local: {
        get: (_keys, cb) => { cb({ extensionTheme: 'dark' }); },
        set: (changes) => { sets.push(changes); },
      },
      onChanged: { addListener() {} },
    },
  };
  runInNewContext(src('material-color.js'), scope);
  runInNewContext(src('theme-palette.js'), scope);
  runInNewContext(src('theme.js'), scope);
  return { theme: scope.fushiTheme, rootAttrs, local, sets };
}

test('content script（有 chrome.runtime.id）不认宿主页伪造的 data-fushi-theme-host="page"', () => {
  const { theme, rootAttrs, local, sets } = load({ runtimeId: 'ext-id' });
  assert.equal(theme.isStandalonePage(), false);
  assert.equal(theme.preference, 'dark', '偏好来自 chrome.storage，而不是宿主页可控的 localStorage');
  assert.equal(rootAttrs.has('data-theme'), false, '不得把主题写到宿主页 <html> 上');
  assert.equal(rootAttrs.has('data-style'), false);
  theme.save({ extensionTheme: 'light' });
  assert.equal(sets.length, 1, '保存走 chrome.storage.local');
  assert.equal(local.get('fushi-theme:extensionTheme'), JSON.stringify('light'), 'localStorage 原样未动');
});

test('非扩展上下文（fushi_server WebUI）照常按独立网页处理', () => {
  const { theme, rootAttrs, local, sets } = load({ runtimeId: null });
  assert.equal(theme.isStandalonePage(), true);
  assert.equal(theme.preference, 'light', '偏好来自 localStorage');
  assert.equal(rootAttrs.get('data-theme'), 'light', '主题写到自己根上');
  theme.save({ extensionTheme: 'dark' });
  assert.equal(sets.length, 0);
  assert.equal(local.get('fushi-theme:extensionTheme'), JSON.stringify('dark'));
  assert.equal(theme.preference, 'dark');
});
