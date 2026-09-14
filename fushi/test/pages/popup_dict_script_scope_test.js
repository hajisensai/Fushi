// BUG-2546 行为守卫：词典自带脚本必须**每个词典块独立**，跨「查词轮次」不留痕。
//
// 弹窗是常驻页面：换词只重建结果 DOM，同一本词典的同一份脚本会被再跑一遍
// （runDictScripts）。此前脚本拿到的是**真** window，于是：
//   · jQuery 式 `var document = window.document` 取到真 document，
//     `$(document).on('click', …)` 绑在真 document 上；第二次查词再绑一份，
//     一次点击被处理两次 —— MDX 折叠块展开又立刻收起 =「点不开」。
//   · `if (window.__inited) return;` 这类幂等守卫更彻底：第二次起直接短路，
//     新 DOM 一次都绑不上。
// 修复后 window 也是本块私有代理，两种写法都退化成「每块各自初始化一次」。
//
// 与 fushi/test/pages 下其它行为测试同构：手写最小 DOM 桩 + vm.runInContext 跑真
// dict-media.js，无 jsdom、无 node_modules。

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const ASSET = path.join(__dirname, '..', '..', 'assets', 'popup', 'dict-media.js');
const src = fs.readFileSync(ASSET, 'utf8');

function makeEl(tag, attrs = {}, textContent = '') {
  return {
    tagName: String(tag).toUpperCase(),
    children: [],
    parent: null,
    dataset: {},
    textContent,
    _attrs: { ...attrs },
    listeners: [],
    getAttribute(name) {
      return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
    },
    setAttribute(name, value) {
      this._attrs[name] = value;
    },
    append(child) {
      child.parent = this;
      this.children.push(child);
      return child;
    },
    remove() {
      if (this.parent) {
        const i = this.parent.children.indexOf(this);
        if (i >= 0) this.parent.children.splice(i, 1);
        this.parent = null;
      }
    },
    addEventListener(type, fn) {
      this.listeners.push([type, fn]);
    },
    removeEventListener() {},
    _walk(out) {
      for (const c of this.children) {
        out.push(c);
        c._walk(out);
      }
      return out;
    },
    querySelectorAll(selector) {
      const want = String(selector).toUpperCase();
      return this._walk([]).filter((e) => e.tagName === want);
    },
    querySelector(selector) {
      return this.querySelectorAll(selector)[0] || null;
    },
    getElementsByClassName() {
      return [];
    },
    getElementsByTagName(name) {
      return this.querySelectorAll(name);
    },
  };
}

/// 一个词典块：wrapper + 一个 `<script>`（内联，不经 bridge）。
function makeDictBlock(code) {
  const root = makeEl('div', { 'data-dictionary': 'OALDPE' });
  root.append(makeEl('script', {}, code));
  return root;
}

function makeContext() {
  const realWindowListeners = [];
  const realDocument = {
    __isRealDocument: true,
    body: { __isRealBody: true },
    documentElement: { __isRealHtml: true },
    readyState: 'loading',
    createElement: (t) => makeEl(t),
    querySelector: () => null,
    querySelectorAll: () => [],
    addEventListener: () => {
      throw new Error('dictionary script reached the REAL document');
    },
    removeEventListener: () => {},
  };
  const windowObj = {
    __isRealWindow: true,
    setTimeout,
    addEventListener(type, fn) {
      realWindowListeners.push([type, fn]);
    },
    removeEventListener() {},
    flutter_inappwebview: {
      callHandler: async () => null,
    },
  };
  const ctx = {
    window: windowObj,
    document: realDocument,
    console,
    Promise,
    setTimeout,
    CSS: { escape: (s) => String(s) },
    Event: class Event {
      constructor(type) {
        this.type = type;
      }
    },
    WeakSet,
    Map,
    Proxy,
    Reflect,
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(src, ctx, { filename: 'dict-media.js' });
  return { ctx, windowObj, realDocument, realWindowListeners };
}

// 一份「典型 MDX 词典脚本」：既走 window.document（jQuery 式），又用 window 上的
// 标记做幂等守卫（两种泄漏写法各一半）。每跑一次就在本块 wrapper 上留痕。
const DICT_SCRIPT = `
  var doc = window.document;
  var host = doc.body;
  host.setAttribute('scopedBody', String(!host.__isRealBody));
  host.setAttribute('shortCircuited', String(!!window.__dictInited));
  if (!window.__dictInited) {
    window.__dictInited = true;
    window.addEventListener('click', function () {});
  }
  host.setAttribute('ran', 'yes');
`;

async function main() {
  const { ctx, windowObj, realWindowListeners } = makeContext();

  const blocks = [];
  for (let round = 0; round < 3; round++) {
    const root = makeDictBlock(DICT_SCRIPT);
    await ctx.runDictScripts(root, 'OALDPE');
    blocks.push(root);
  }

  blocks.forEach((root, i) => {
    const round = i + 1;
    assert.strictEqual(
      root.getAttribute('ran'), 'yes',
      `round ${round}: dictionary script did not run for this block`);
    assert.strictEqual(
      root.getAttribute('scopedBody'), 'true',
      `round ${round}: window.document handed the script the REAL document`);
    // 关键回归点：第二、三轮不得被上一轮留在 window 上的标记短路。
    assert.strictEqual(
      root.getAttribute('shortCircuited'), 'false',
      `round ${round}: a previous block's window flag survived and short-circuited this one`);
    assert.strictEqual(
      root.listeners.filter(([type]) => type === 'click').length, 1,
      `round ${round}: window-level listener did not land on this block exactly once`);
  });

  assert.strictEqual(
    realWindowListeners.length, 0,
    'window-level listeners from dictionary scripts leaked onto the real window');
  assert.strictEqual(
    windowObj.__dictInited, undefined,
    'dictionary script wrote its flag onto the real window');

  console.log('popup_dict_script_scope_test.js: all assertions passed');
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
});
