// ZdghRxjVCm 的**行为级**守卫：查词弹窗词典分组 `<summary>` 上，「长按选词典（制卡
// 用）」与「单击展开/折叠」是同一次按下的两种结局，只能二选一。
//
// 根因：`<details>` 的开合是 `<summary>` 上 click 的 activation behavior。鼠标长按
// 500ms 触发选词典后松开，浏览器照样派发 click → 分组被折叠/展开。触屏那条由
// touchend 的 preventDefault 掐掉合成 click，鼠标没有对应的一步。
//
// 本文件真执行 popup.js 里提取出的 `createGlossarySection`，拿它**实际挂上去的**
// 监听按真实顺序（mousedown → 500ms 计时到点 → mouseup → click）派发事件，断言：
//   ① 长按后的 click 被取消默认动作（= 不开合）；
//   ② 普通单击的 click 不受影响（照常开合）；
//   ③ 长按消费后复位：紧接着的下一次单击照常开合；
//   ④ 键盘 / 手柄长按入口（__fushiDictLongPress）不会让下一次真点击被误吞；
//   ⑤ 触屏长按 touchend 取消默认动作（掐合成 click）——用事件参数，不靠 window.event。
// 「preventDefault 能阻止 <details> 开合」是 DOM 规范语义（activation behavior 被取消），
// 合成事件在这里只验监听决策。
//
// 运行：node fushi/test/dictionary/popup_dict_label_long_press_no_toggle_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'popup.js'),
  'utf8',
);

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
  dictColumns: () => 1,
  ensureDictionaryStyle: () => {},
  constructDictCss: (css) => css,
  parseTags: () => [],
  createGlossaryTags: () => null,
  tagGlossaryContent: () => {},
  renderStructuredContent: () => {},
  rewriteDictLinks: (html) => html,
  runDictScripts: () => {},
  __fushiChunkLongGlossary: () => {},
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
    '大辞林 第四版', [{ content: 'ほんちょうし', glossaryIndex: 0 }], 0, 0, 1);
  const summary = details.childNodes.find((n) => n.tagName === 'SUMMARY');
  assert.ok(summary, 'createGlossarySection must build a <summary> header');
  return { details, summary };
}

function fireArmedLongPress() {
  const armed = timers.filter((t) => !t.cancelled && t.ms === 500);
  assert.strictEqual(armed.length, 1, 'press must arm exactly one 500ms long-press timer');
  armed[0].cancelled = true;
  armed[0].fn();
}

function click(summary) {
  const event = new FakeEvent('click', 0);
  summary.dispatchEvent(event);
  return event;
}

// ① 鼠标长按 → 松开后的 click 不得开合分组。
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  fireArmedLongPress();
  assert.strictEqual(summary.classList.contains('selected'), true,
    'long-press must select the dictionary for mining');
  summary.dispatchEvent(new FakeEvent('mouseup', 0));
  const event = click(summary);
  assert.strictEqual(event.defaultPrevented, true,
    'the click that follows a mouse long-press must be default-prevented, otherwise '
    + '<details> also collapses/expands the dictionary (ZdghRxjVCm)');
}

// ② 普通单击照常开合。
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  summary.dispatchEvent(new FakeEvent('mouseup', 0));
  const event = click(summary);
  assert.strictEqual(event.defaultPrevented, false,
    'a plain click must keep toggling the dictionary group');
  assert.strictEqual(summary.classList.contains('selected'), false,
    'a plain click must not select the dictionary');
}

// ③ 长按被消费后复位：下一次单击照常开合。
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  fireArmedLongPress();
  summary.dispatchEvent(new FakeEvent('mouseup', 0));
  click(summary);
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  summary.dispatchEvent(new FakeEvent('mouseup', 0));
  const event = click(summary);
  assert.strictEqual(event.defaultPrevented, false,
    'after the long-press click is swallowed, the next plain click must toggle again');
}

// ④ 键盘 / 手柄长按入口不污染下一次真点击。
{
  const { summary } = buildSection();
  assert.strictEqual(context.window.__fushiDictLongPress(summary), true,
    '__fushiDictLongPress must drive the summary toggle');
  assert.strictEqual(summary.classList.contains('selected'), true,
    'keyboard long-press must select the dictionary');
  summary.dispatchEvent(new FakeEvent('mousedown', 0));
  summary.dispatchEvent(new FakeEvent('mouseup', 0));
  const event = click(summary);
  assert.strictEqual(event.defaultPrevented, false,
    'a keyboard/gamepad long-press has no trailing click; it must not make the next '
    + 'real click get swallowed');
}

// ⑤ 触屏长按：touchend 用事件参数取消默认动作（掐掉合成 click）。
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('touchstart', 0));
  fireArmedLongPress();
  const end = new FakeEvent('touchend', 0);
  summary.dispatchEvent(end);
  assert.strictEqual(end.defaultPrevented, true,
    'touchend after a touch long-press must be default-prevented via its own event');
  const event = click(summary);
  assert.strictEqual(event.defaultPrevented, true,
    'a synthesized click that still arrives after a touch long-press must not toggle');
}

// ⑥ 触屏短按照常开合。
{
  const { summary } = buildSection();
  summary.dispatchEvent(new FakeEvent('touchstart', 0));
  const end = new FakeEvent('touchend', 0);
  summary.dispatchEvent(end);
  assert.strictEqual(end.defaultPrevented, false, 'a short tap must not be prevented');
  assert.strictEqual(click(summary).defaultPrevented, false,
    'a short tap must keep toggling the dictionary group');
}

console.log('all assertions passed');
