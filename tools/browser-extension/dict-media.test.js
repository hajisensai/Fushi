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
  const ctx = load({}); // window.__fushiDictMedia unset -> app path
  const out = ctx.rewriteDictionaryMediaPath('gaiji/foo.svg', '明鏡');
  assert.strictEqual(
    out,
    'image://?dictionary=' + encodeURIComponent('明鏡') + '&path=' + encodeURIComponent('gaiji/foo.svg'),
  );
});

test('extension environment rewrites to the http media endpoint with token', () => {
  const ctx = load({ __fushiDictMedia: { base: 'http://127.0.0.1:19633', token: 'secret-tok' } });
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
  const ctx = load({ __fushiDictMedia: { base: 'http://127.0.0.1:19633', token: '' } });
  const out = ctx.rewriteDictionaryMediaPath('accent/1.svg', 'NHK');
  assert.ok(out.startsWith('image://'), 'expected image:// fallback, got ' + out);
});

test('absolute / scheme paths are left alone (returns null)', () => {
  const ctx = load({ __fushiDictMedia: { base: 'http://127.0.0.1:19633', token: 't' } });
  assert.strictEqual(ctx.rewriteDictionaryMediaPath('https://example.com/x.png', 'D'), null);
  assert.strictEqual(ctx.rewriteDictionaryMediaPath('data:image/svg+xml;base64,AAA', 'D'), null);
});

test('backslashes and leading ./ are normalized before rewriting', () => {
  const ctx = load({ __fushiDictMedia: { base: 'http://h:1', token: 't' } });
  const bs = String.fromCharCode(92); // build backslash without a literal escape
  const out = ctx.rewriteDictionaryMediaPath('.' + bs + 'sub' + bs + 'a.svg', 'D');
  assert.ok(out.includes('path=' + encodeURIComponent('sub/a.svg')), out);
});

// ── BUG-1718：词典自带 CSS / 词条内嵌资源在扩展侧的兑现 ──────────────────────
//
// 症状：同一本 mdx 词典（OALDPE），app 内查词样式正常，浏览器插件里词头/音标/徽标/义项缩进
// 全成裸文本，词条内插图裂图。两个根因都在这个文件负责的边界上：
//  ① popup.js 读的 window.dictionaryStyles/globalDictCSS/customDictCSS 在扩展侧从未被赋值；
//  ② TODO-1215 把 <img src> 降级成 data-fushi-media-* 占位属性以免泄漏 token，却从没有人兑现。

function loadCtx(extra) {
  const ctx = Object.assign({ window: {} }, extra || {});
  if (!ctx.window) ctx.window = {};
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return ctx;
}

test('applyFushiPopupCss 把查词响应的 CSS 尾段落到 popup.js 读的三个全局上', () => {
  const ctx = loadCtx();
  ctx.applyFushiPopupCss({
    dictionaryStyles: { OALDPE: '.opal{color:red}' },
    globalDictCSS: 'body{font-size:16px}',
    customDictCSS: { 明鏡: '.mk{}' },
  });
  assert.deepStrictEqual(ctx.window.dictionaryStyles, { OALDPE: '.opal{color:red}' });
  assert.strictEqual(ctx.window.globalDictCSS, 'body{font-size:16px}');
  assert.deepStrictEqual(ctx.window.customDictCSS, { 明鏡: '.mk{}' });
});

test('applyFushiPopupCss 对老 app 的缺字段响应归零，绝不留 undefined 给 popup.js', () => {
  const ctx = loadCtx();
  ctx.applyFushiPopupCss({ type: 'dictionaryResult' });
  // 注：这些空对象由 vm realm 创建，跨 realm 原型不同 → 用 JSON 形状比对而非 deepStrictEqual。
  assert.strictEqual(JSON.stringify(ctx.window.dictionaryStyles), '{}');
  assert.strictEqual(ctx.window.globalDictCSS, '');
  assert.strictEqual(JSON.stringify(ctx.window.customDictCSS), '{}');
});

test('扩展环境下词条里的 <link> 样式表降级成无 token 占位（dictmedia:// 在真浏览器是死链）', () => {
  const ctx = loadCtx({ window: { __fushiDictMedia: { base: 'http://127.0.0.1:19633', token: 'secret-tok' } } });
  const out = ctx.rewriteDictLinks('<link rel="stylesheet" href="oaldpe.css">', 'OALDPE');
  assert.ok(!out.includes('dictmedia://'), '扩展侧不得留 dictmedia:// 死链');
  assert.ok(!out.includes('secret-tok'), 'token 绝不能进宿主页 DOM');
  assert.ok(out.includes('data-fushi-media-path="oaldpe.css"'), out);
  assert.ok(out.includes('data-fushi-media-dict="OALDPE"'), out);
});

test('app 环境下 <link> 仍走 dictmedia:// 自定义 scheme（不得破坏 app 内弹窗）', () => {
  const ctx = loadCtx();
  const out = ctx.rewriteDictLinks('<link rel="stylesheet" href="oaldpe.css">', 'OALDPE');
  assert.ok(out.includes('dictmedia://oaldpe.css?dictionary=OALDPE'), out);
});

// 极简 DOM 替身：只实现 resolveDictMediaPlaceholders 真正用到的那几个能力。
function fakeNode(tagName, attrs) {
  const node = {
    tagName,
    attrs: Object.assign({}, attrs),
    src: null,
    listeners: {},
    parentNode: null,
    getAttribute: (k) => (k in node.attrs ? node.attrs[k] : null),
    removeAttribute: (k) => { delete node.attrs[k]; },
    addEventListener: (k, fn) => { node.listeners[k] = fn; },
  };
  return node;
}

function fakeEnv(nodes, fetchImpl) {
  const parent = { children: nodes.slice(), replaced: [] };
  parent.replaceChild = (fresh, old) => { parent.replaced.push({ fresh, old }); };
  for (const n of nodes) n.parentNode = parent;
  const created = [];
  return {
    parent,
    created,
    ctx: {
      window: { __fushiDictMedia: { base: 'http://127.0.0.1:19633', token: 'secret-tok' } },
      document: {
        createElement: (tag) => { const el = { tagName: tag.toUpperCase(), textContent: '' }; created.push(el); return el; },
      },
      URL: { createObjectURL: () => 'blob:fake-1', revokeObjectURL: () => {} },
      fetch: fetchImpl,
    },
    root: { querySelectorAll: () => nodes.filter((n) => 'data-fushi-media-path' in n.attrs) },
  };
}

test('图片占位被兑现成 blob: URL，token 只出现在 fetch 参数里', async () => {
  const img = fakeNode('IMG', { 'data-fushi-media-dict': 'OALDPE', 'data-fushi-media-path': 'gaiji%2Ffoo.svg' });
  const calls = [];
  const env = fakeEnv([img], (url) => { calls.push(url); return Promise.resolve({ ok: true, blob: () => Promise.resolve('BYTES') }); });
  const ctx = loadCtx(env.ctx);
  ctx.resolveDictMediaPlaceholders(env.root);
  await new Promise((r) => setImmediate(r));
  assert.strictEqual(calls.length, 1);
  assert.strictEqual(
    calls[0],
    'http://127.0.0.1:19633/api/media/dictionary?dictionary=OALDPE'
      + '&path=' + encodeURIComponent('gaiji/foo.svg') + '&token=secret-tok');
  assert.strictEqual(img.src, 'blob:fake-1');
  assert.ok(!('data-fushi-media-path' in img.attrs), '占位属性必须摘掉，否则 observer 会无限重试');
});

test('样式表占位被兑现成内联 <style>（词条自带 <link> 在扩展里终于生效）', async () => {
  const link = fakeNode('LINK', { 'data-fushi-media-dict': 'OALDPE', 'data-fushi-media-path': 'oaldpe.css' });
  const env = fakeEnv([link], () => Promise.resolve({ ok: true, text: () => Promise.resolve('.opal{color:red}') }));
  const ctx = loadCtx(env.ctx);
  ctx.resolveDictMediaPlaceholders(env.root);
  await new Promise((r) => setImmediate(r));
  assert.strictEqual(env.parent.replaced.length, 1);
  assert.strictEqual(env.parent.replaced[0].fresh.tagName, 'STYLE');
  assert.strictEqual(env.parent.replaced[0].fresh.textContent, '.opal{color:red}');
});

test('未配置 server（app 内 / 尚未拿到 cfg）时兑现器完全不动手', () => {
  const img = fakeNode('IMG', { 'data-fushi-media-dict': 'OALDPE', 'data-fushi-media-path': 'gaiji%2Ffoo.svg' });
  const env = fakeEnv([img], () => { throw new Error('不应发起请求'); });
  env.ctx.window = {}; // __fushiDictMedia 未设
  const ctx = loadCtx(env.ctx);
  ctx.resolveDictMediaPlaceholders(env.root);
  assert.ok('data-fushi-media-path' in img.attrs, '没有 server 配置时不得摘掉占位（拿到配置后还要兑现）');
});
