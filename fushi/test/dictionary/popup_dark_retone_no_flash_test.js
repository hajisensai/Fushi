// M3E 暗色下词典浅底的调色（__fushiToneDictColors）不能因为无关写入而闪回原色。
// 本文件真执行 popup.js 里提取出的函数，断言：
//   * 调色输入签名忽略瞬态写入——滚动指示每个 scroll 事件都 classList.add
//     popup-scroll-active（类已在也照样产生 mutation 记录）、nudge 写 opacity、宽度 / zoom
//     注入——却能捕捉 data-theme、主题 CSS 变量、颜色声明的变化；
//   * __fushiRetoneDictColors 不同步复原：复原挂起到重调那一帧开头，与重调同帧完成。
// 修复前：同步复原、下一帧才重调，中间那一帧画出词典原色（Chromium 实测每次滚动 / nudge
// 露出一帧浅底），连续滚动时一直停在原色。
//
// 运行：node fushi/test/dictionary/popup_dark_retone_no_flash_test.js
// 由同名 .dart wrapper 通过 Process.run('node', ...) 驱动（无 node 时 skip）。

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const popupSrc = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'assets', 'popup', 'popup.js'), 'utf8');

function extract(pattern, what) {
  const m = popupSrc.match(pattern);
  assert.ok(m, `popup.js 里找不到 ${what}`);
  return m[0];
}

const signatureSrc = extract(
  /var __FUSHI_M3E_TRANSIENT_CLASSES = [^\n]*\nfunction __fushiM3eToneSignature\(\) \{[\s\S]*?\n\}/,
  '__fushiM3eToneSignature');
const retoneSrc = extract(
  /var __fushiM3eRestorePending = false;\nfunction __fushiRetoneDictColors\(\) \{[\s\S]*?\n\}/,
  '__fushiRetoneDictColors');
const scheduleSrc = extract(
  /function __fushiScheduleM3eDictTone\(root\) \{[\s\S]*?\n\}/,
  '__fushiScheduleM3eDictTone');

class FakeStyle {
  constructor() { this._m = new Map(); }
  get length() { return this._m.size; }
  setProperty(k, v) { this._m.set(k, v); this._sync(); }
  getPropertyValue(k) { return this._m.get(k) || ''; }
  _sync() { [...this._m.keys()].forEach((k, i) => { this[i] = k; }); }
}

class FakeHost {
  constructor() {
    this.attrs = new Map();
    this.classList = new Set();
    this.style = new FakeStyle();
  }
  getAttribute(k) { return this.attrs.has(k) ? this.attrs.get(k) : null; }
  setAttribute(k, v) { this.attrs.set(k, v); }
}

const root = new FakeHost();
root.classList.add('fushi-m3e');
root.setAttribute('data-theme', 'dark');
const container = new FakeHost();

const calls = [];
const rafQueue = [];
const context = {
  document: { documentElement: root },
  window: {},
  requestAnimationFrame: (cb) => { rafQueue.push(cb); return rafQueue.length; },
  getComputedStyle: () => ({}),
  __fushiContainer: () => container,
  __fushiM3eDarkSurface: () => root.getAttribute('data-theme') === 'dark',
  __fushiDictUnifiedEnabled: () => false,
  __fushiRestoreDictTone: () => calls.push('restore'),
  __fushiClearDictToneMarks: () => calls.push('clearMarks'),
  __fushiClearDictUnify: () => {},
  __fushiToneDictColors: () => calls.push('tone'),
  __fushiUnifyDictStyles: () => {},
  __fushiPruneDetachedTone: () => {},
  __fushiObserveM3eToneHosts: () => {},
  __fushiM3eToneRoots: null,
  __fushiM3eToneRaf: 0,
  __fushiM3eKnownRoots: null,
  __fushiM3eLastDark: null,
  __fushiM3eLastToneSignature: null,
};
vm.createContext(context);
vm.runInContext(`${signatureSrc}\n${retoneSrc}\n${scheduleSrc}\n` +
  'this.sig = __fushiM3eToneSignature; this.retone = __fushiRetoneDictColors;', context);

// ── 1. 签名：瞬态写入不变，颜色输入才变 ──
const base = context.sig();
assert.strictEqual(typeof base, 'string');

root.classList.add('popup-scroll-active');
container.classList.add('popup-scroll-active');
assert.strictEqual(context.sig(), base, '滚动指示类不能改变调色签名');
root.style.setProperty('opacity', '0.999');
root.style.setProperty('zoom', '1.25');
root.style.setProperty('width', '420px');
assert.strictEqual(context.sig(), base, 'opacity / zoom / 宽度不能改变调色签名');

root.style.setProperty('--background-color', '#101418');
const withVar = context.sig();
assert.notStrictEqual(withVar, base, '主题 CSS 变量热更新必须改变签名（需要重调）');
container.style.setProperty('color', 'rgb(1, 2, 3)');
const withColor = context.sig();
assert.notStrictEqual(withColor, withVar, '颜色声明必须改变签名');
root.setAttribute('data-theme', 'light');
assert.notStrictEqual(context.sig(), withColor, 'data-theme 必须改变签名');
root.setAttribute('data-theme', 'dark');
root.classList.add('fushi-other-theme-class');
assert.notStrictEqual(context.sig(), withColor, '非瞬态类必须改变签名');

// ── 2. 重调色：同步不复原，复原与重调同帧、复原在前 ──
context.__fushiM3eKnownRoots = new Set([container]);
container.isConnected = true;
calls.length = 0;
context.retone();
assert.ok(!calls.includes('restore'),
  `__fushiRetoneDictColors 不能同步复原（会露出一帧词典原色），实得 ${calls}`);
assert.strictEqual(rafQueue.length, 1, '应排一帧重调');
calls.length = 0;
rafQueue.shift()();
assert.deepStrictEqual(calls, ['restore', 'tone'],
  `重调那一帧必须先复原再调色，实得 ${calls}`);
assert.strictEqual(context.__fushiM3eLastToneSignature, context.sig(),
  '调色完成后记下当时的签名，后续无关写入才能被跳过');

// 普通排调色（没有挂起的复原）不复原。
calls.length = 0;
vm.runInContext('__fushiScheduleM3eDictTone(__fushiContainer());', context);
rafQueue.shift()();
assert.deepStrictEqual(calls, ['tone'], `无挂起复原时只调色，实得 ${calls}`);

console.log('all assertions passed');
