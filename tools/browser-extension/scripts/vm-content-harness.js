// 在受控 `node:vm` 里加载 `content.js` 的共享 harness。
//
// 为什么住在 `scripts/`：`tools/browser-extension/` 是随 app 打包的扩展的唯一真相源，
// 整目录被镜像进 `fushi/assets/browser_extension/`（守卫
// `fushi/test/build/browser_extension_mirror_full_guard_test.dart`）。镜像清单只排除
// `*.test.js` 与 `scripts/`，所以测试专用的 helper 只能放这两处之一——放别处就会被
// 要求镜像进 app 资产包，还得同步改三份清单。
//
// 抽出来的动机是 Sonar 的 new_duplicated_lines_density（3% 门）：DOM 桩 + vm 沙箱
// 这两段近百行在每个新 `*.test.js` 里逐字重复一遍。`.sonarcloud.properties` 的
// cpd 排除项只覆盖上游 vendor 与被守卫强制的镜像，测试自己的复制不在其中——
// 按该文件自己写的原则（共享 PS1 头部就抽成了 `_verify_common.ps1`），抽共享模块
// 才是正解，加排除项不是。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const EXT_ROOT = path.join(__dirname, '..');

/// 最小 DOM 元素桩：只实现 content.js 实际用到的那些面。
function makeEl(tag) {
  const el = {
    tagName: (tag || 'div').toUpperCase(),
    _id: '',
    className: '',
    textContent: '',
    style: { cssText: '', setProperty() {}, getPropertyValue: () => '' },
    dataset: {},
    children: [],
    parentNode: null,
    setAttribute(k, v) { if (k === 'id') el._id = v; },
    getAttribute() { return null; },
    classList: { add() {}, remove() {}, toggle() {} },
    addEventListener() {},
    appendChild(child) { child.parentNode = el; el.children.push(child); return child; },
    removeChild(child) {
      const i = el.children.indexOf(child);
      if (i >= 0) el.children.splice(i, 1);
      child.parentNode = null;
      return child;
    },
    remove() { if (el.parentNode) el.parentNode.removeChild(el); },
    contains(x) { return x === el || el.children.some((c) => c.contains && c.contains(x)); },
    getBoundingClientRect() {
      return { x: 0, y: 0, left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
    },
  };
  Object.defineProperty(el, 'id', { get: () => el._id, set: (v) => { el._id = v; } });
  return el;
}

/// 在受控 vm 里加载 `vendor/dict-media.js` + `content.js`，返回 `{sandbox, toasts}`。
///
/// 加载顺序与真实运行时一致（BUG-1718：manifest 里 vendor/dict-media.js 恒在
/// content.js 之前，后者依赖它导出的 applyFushiPopupCss 等；顺序反了就是在跑一个
/// 现实中不存在的、缺半个脚本集的环境）。
///
/// 加载期 content.js 会挂一个 1500ms 的批量续跑定时器（真实运行时要的，测试里跑起来
/// 会去够 chrome.* 桩）。故加载阶段吞掉 setTimeout，加载完再放真的给被测函数用。
function loadContentSandbox(options) {
  const opts = options || {};
  const src = fs.readFileSync(path.join(EXT_ROOT, 'content.js'), 'utf8');
  const head = makeEl('head');
  const body = makeEl('body');
  const html = makeEl('html');
  html.appendChild(head);
  const toasts = [];
  let loading = true;
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: (fn, ms) => (loading ? 0 : setTimeout(fn, ms)),
    clearTimeout: (h) => clearTimeout(h),
    setInterval: () => 0,
    clearInterval() {},
    requestAnimationFrame: () => 0,
    getComputedStyle: () => ({ getPropertyValue: () => '' }),
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: opts.location || {
      hostname: 'www.netflix.com',
      href: 'https://www.netflix.com/watch/1',
      pathname: '/watch/1',
    },
  };
  sandbox.document = {
    documentElement: html,
    head,
    body,
    fullscreenElement: null,
    addEventListener() {},
    getElementById: () => null,
    querySelector: () => null,
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
    createTreeWalker: () => ({ nextNode: () => null }),
  };
  sandbox.chrome = {
    runtime: {
      id: 'test-ext-id',
      getURL: (rel) => `chrome-extension://test-ext-id/${rel}`,
      lastError: null,
      onMessage: { addListener() {} },
      sendMessage() {},
    },
    storage: {
      local: {
        get: (keys, cb) => { if (cb) cb({}); return Promise.resolve({}); },
        set: (patch, cb) => { if (cb) cb(); return Promise.resolve(); },
      },
      onChanged: { addListener() {} },
    },
  };
  sandbox.window = {
    addEventListener() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
    fushiSelection: {
      getCharacterAtPoint: () => null,
      selectFromPosition: () => '',
      clearSelection() {},
    },
    flutter_inappwebview: { callHandler() {} },
  };
  sandbox.window.window = sandbox.window;

  vm.createContext(sandbox);
  vm.runInContext(
    fs.readFileSync(path.join(EXT_ROOT, 'vendor', 'dict-media.js'), 'utf8'),
    sandbox,
    { filename: 'vendor/dict-media.js' },
  );
  vm.runInContext(src, sandbox, { filename: 'content.js' });
  loading = false;
  // content.js 自己不定义 fushiToast（由页面注入那一节挂），这里补一个可观测的。
  sandbox.window.fushiToast = (msg) => { toasts.push(String(msg)); };
  return { sandbox, toasts };
}

/// 读回 content.js 里的一个 const（vm 的词法作用域取不到属性）。
///
/// 存在的理由：测试自己抄一份常量，改代码时两边会悄悄分叉。
function readConst(sandbox, name) {
  return vm.runInContext(name, sandbox);
}

module.exports = { makeEl, loadContentSandbox, readConst };
