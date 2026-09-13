// BUG-2447 的**行为级**守卫：查词弹窗里词典分组的 `<summary>`（点它展开/折叠）
// 在主键 mousedown 上必须取消默认动作，否则该节点会拿到 DOM 焦点。
//
// 为什么这条值得单测（别把它当「一行 preventDefault」）：节点获焦在 macOS WebKit 上
// 会把承载它的 WKWebView 变成窗口 first responder，而 macOS 侧**没有任何东西能把
// first responder 还回来**（Flutter 引擎的 FlutterMutatorView /
// FlutterPlatformViewController 整层无 firstResponder 代码；`PageFocusOwnership`
// 只动 Flutter 自己的焦点树；Windows 那条兜底是 fork 的 custom_platform_view 在每次
// onPointerDown 里 requestFocus，依赖 WebView2 的无窗口合成，真原生 WKWebView 上不
// 存在）。于是「展开一次词典分组」= 宿主页面快捷键整条失效，且关掉弹窗也回不来。
// `<summary>` 是弹窗里唯一「鼠标点一下就获焦」的元素——按钮与链接在 macOS WebKit 下
// 按平台惯例 `isMouseFocusable` 恒为 false，释义正文与留白根本不可聚焦。
//
// 分层说明：
//   * 本文件真执行 popup.js 里提取出的 `createGlossarySection`，拿到它**实际挂上去
//     的** mousedown 监听再派发事件，所以测的是出货代码，不是复刻品。
//   * 「取消 mousedown 默认动作确实能阻止节点获焦」是 DOM 规范语义，只有真浏览器
//     的真用户手势能验（合成事件不是 trusted，默认动作本就不跑），不在本层。
//   * `<details>` 的开合是 `click` 的 activation behavior，与 mousedown 的默认动作
//     无关——这正是这条修复不会把展开/折叠一起掐掉的原因。
//
// 运行：node fushi/test/dictionary/popup_summary_mouse_focus_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupPath = path.resolve(
  __dirname, '..', '..', 'assets', 'popup', 'popup.js');
const popupSrc = fs.readFileSync(popupPath, 'utf8');

// ---- 最小 fake DOM ---------------------------------------------------------
// 只实现被测代码真正用到的原语：属性赋值（el 用 `key in element` 分流）、子节点
// 挂载、classList、以及 addEventListener/dispatchEvent（本测试的观测面）。
class FakeEvent {
  constructor(type, button) {
    this.type = type;
    this.button = button;
    this.defaultPrevented = false;
  }

  preventDefault() {
    this.defaultPrevented = true;
  }
}

class FakeClassList {
  constructor() {
    this._set = new Set();
  }

  add(name) {
    this._set.add(name);
  }

  remove(name) {
    this._set.delete(name);
  }

  contains(name) {
    return this._set.has(name);
  }
}

class FakeElement {
  constructor(tagName) {
    this.nodeType = 1;
    this.tagName = String(tagName).toUpperCase();
    this.className = '';
    this.textContent = '';
    this.innerHTML = '';
    this.open = false;
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = {};
    this.classList = new FakeClassList();
    this._listeners = new Map();
  }

  appendChild(child) {
    this.childNodes.push(child);
    if (child && typeof child === 'object') child.parentNode = this;
    return child;
  }

  append(...children) {
    for (const child of children) this.appendChild(child);
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name)
      ? this.attributes[name]
      : null;
  }

  addEventListener(type, handler) {
    if (!this._listeners.has(type)) this._listeners.set(type, []);
    this._listeners.get(type).push(handler);
  }

  /// 派发到本节点上注册的监听（不冒泡：被测监听就挂在 summary 自己身上）。
  dispatchEvent(event) {
    for (const handler of this._listeners.get(event.type) || []) {
      handler(event);
    }
    return !event.defaultPrevented;
  }

  querySelectorAll() {
    return [];
  }
}

// ---- 提取被测函数（不执行整个 popup.js：它依赖真实 DOM/window） -------------
function extract(pattern, what) {
  const match = popupSrc.match(pattern);
  assert.ok(match, 'popup.js must define ' + what);
  return match[0];
}

const elFn = extract(
  /function el\(tag, props = \{\}, children = \[\]\) \{[\s\S]*?\n\}/,
  'el(tag, props, children)',
);
const displayNameFn = extract(
  /function __fushiDictDisplayName\(name\)\{[\s\S]*?\n\}/,
  '__fushiDictDisplayName(name)',
);
const autoExpandFn = extract(
  /function autoExpandCount\(totalDicts\) \{[\s\S]*?\n\}/,
  'autoExpandCount(totalDicts)',
);
const sectionFn = extract(
  /function createGlossarySection\(dictName, contents, dictIdx, entryIdx, totalDicts\) \{[\s\S]*?\n\}/,
  'createGlossarySection(dictName, contents, dictIdx, entryIdx, totalDicts)',
);

// 派生判据必须独立于被测源码：这两条只用来保证我们抓到的确实是**唯一**那处
// summary mousedown 监听，抓错了下面的行为断言就成了自证。
const summaryMouseDownSites =
  popupSrc.match(/summary\.addEventListener\('mousedown'/g) || [];
assert.strictEqual(
  summaryMouseDownSites.length, 1,
  'popup.js must register exactly one mousedown listener on the dict <summary>; '
  + 'found ' + summaryMouseDownSites.length);

const timers = [];
const context = {
  console,
  JSON,
  Set,
  Math,
  Number,
  Object,
  Array,
  RegExp,
  setTimeout: (fn, ms) => {
    timers.push({ fn, ms });
    return timers.length;
  },
  clearTimeout: (id) => {
    if (id >= 1 && id <= timers.length) timers[id - 1].cancelled = true;
  },
  document: {
    createElement: (tag) => new FakeElement(tag),
  },
  window: {},
  selectedDictionaries: {},
  // createGlossarySection 在本测试关心的那段之外还会碰到的协作者，一律最小桩：
  // 它们与 summary 的鼠标聚焦语义无关，桩掉不影响本文件的判据。
  dictColumns: () => 1,
  ensureDictionaryStyle: () => {},
  constructDictCss: (css) => css,
  parseTags: () => [],
  createGlossaryTags: () => null,
  tagGlossaryContent: () => {},
  renderStructuredContent: () => {},
  rewriteDictLinks: (html) => html,
  runDictScripts: () => {},
  NUMERIC_TAG: /^\d+$/,
  isPartOfSpeech: () => false,
};
vm.createContext(context);
vm.runInContext(
  elFn + '\n' + displayNameFn + '\n' + autoExpandFn + '\n' + sectionFn +
  '\nthis.__createGlossarySection = createGlossarySection;',
  context,
);
const createGlossarySection = context.__createGlossarySection;

function buildSection() {
  timers.length = 0;
  context.selectedDictionaries = {};
  const details = createGlossarySection(
    '三省堂国語辞典', [{ content: 'かいせつ', glossaryIndex: 0 }], 0, 0, 1);
  const summary = details.childNodes.find((n) => n.tagName === 'SUMMARY');
  assert.ok(summary, 'createGlossarySection must build a <summary> header');
  return { details, summary };
}

// ---- ① 主键 mousedown 必须取消默认动作（= 不让 <summary> 拿到 DOM 焦点）------
{
  const { summary } = buildSection();
  const event = new FakeEvent('mousedown', 0);
  summary.dispatchEvent(event);
  assert.strictEqual(
    event.defaultPrevented, true,
    'primary-button mousedown on the dict <summary> must be default-prevented, '
    + 'otherwise the node takes DOM focus and (on macOS WebKit) hands the window '
    + 'first responder to the WKWebView with no way back — BUG-2447');
}

// ---- ② 非主键不受影响（中键/右键要留给弹窗输入桥的 Mouse<n> 转发）----------
for (const button of [1, 2, 3, 4]) {
  const { summary } = buildSection();
  const event = new FakeEvent('mousedown', button);
  summary.dispatchEvent(event);
  assert.strictEqual(
    event.defaultPrevented, false,
    'non-primary mousedown (button ' + button + ') on the dict <summary> must be '
    + 'left alone: it never focuses the node, and the popup input bridge still '
    + 'needs it for Mouse<n> forwarding');
}

// ---- ③ 长按选词典（制卡用）没有被这条修复掐掉 ------------------------------
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  const armed = timers.filter((t) => !t.cancelled && t.ms === 500);
  assert.strictEqual(
    armed.length, 1,
    'primary-button mousedown must still arm the 500ms long-press timer that '
    + 'selects this dictionary for mining');
  armed[0].fn();
  assert.strictEqual(
    summary.classList.contains('selected'), true,
    'the long-press must still mark the dictionary as selected');
}

// ---- ④ mouseup / mouseleave 仍然撤销长按（回归防线）------------------------
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  summary.dispatchEvent(new FakeEvent('mouseup', 0));
  assert.strictEqual(
    timers.filter((t) => !t.cancelled).length, 0,
    'mouseup must still cancel the pending long-press timer');
}

console.log('all assertions passed');
