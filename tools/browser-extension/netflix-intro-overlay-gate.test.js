// BUG-2170 守卫：Netflix 批量自动制卡**切集后**必须先把片头年龄分级 overlay 播过去再开录。
//
// 复诉根因：批量状态机到达目标集后只 `fushiWaitForPlayer` + `sleep(800)` 就开 tabCapture 并
// 逐句录制，而 Netflix 每集开播时会在左上角显示数秒年龄分级 overlay（"RATED 13+ / 暴力, 自杀"）。
// tabCapture 录的是**合成后的标签页画面**，于是这段窗内的 clip 把提示烧进了卡片图。常驻 CSS
// 隐藏（TODO-1391）不是保证——它受用户开关 netflixHideNextEpisode 门控，选择器也随 Netflix
// 哈希类名漂移，所以录制侧另加一道与选择器无关的时间门。
//
// 本文件在受控 vm 里真加载 content.js，钉住三条**做错了会静默退化**的性质：
//   ① 等待判据是「播放推进量」，不是墙钟、也不是绝对位置——中途续播的集，提示同样在开播那
//      几秒出现，只看绝对位置会让续播集直接放行（等于没修）。
//   ② 等待有上界：DRM/弱网推不动时返回 false 让批量继续跑，绝不无限等卡死整批。
//   ③ 落在提示窗内的队列项被**放弃**（不 seek 不录），且不从队列里删——用户排的卡不静默丢。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const CONTENT = path.join(__dirname, 'content.js');
const FUSHI_DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');

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

// 加载期 content.js 会挂一个 1500ms 的批量续跑定时器（真实运行时要的，测试里跑起来会去够
// chrome.* 桩）。故加载阶段吞掉定时器，加载完再放真 setTimeout 给被测函数用。
function loadContent() {
  const src = fs.readFileSync(CONTENT, 'utf8');
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
    location: { hostname: 'www.netflix.com', href: 'https://www.netflix.com/watch/1', pathname: '/watch/1' },
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
  vm.runInContext(fs.readFileSync(FUSHI_DICT_MEDIA, 'utf8'), sandbox,
    { filename: 'vendor/dict-media.js' });
  vm.runInContext(src, sandbox, { filename: 'content.js' });
  loading = false;
  // content.js 自己不定义 fushiToast（由页面注入那一节挂），这里补一个可观测的。
  sandbox.window.fushiToast = (msg) => { toasts.push(String(msg)); };
  return { sandbox, toasts };
}

// 提示窗长度是 content.js 里的 const（vm 的词法作用域，取不到属性），用同一 context 求值读回，
// 免得测试自己抄一份常量、改代码时两边悄悄分叉。
function introSec(sandbox) {
  return vm.runInContext('kNfIntroOverlaySec', sandbox);
}

// 假 <video>：currentTime 由「已播放的墙钟 × rate」推出。rate 放大只是为了让测试跑得快，
// 被测逻辑看到的仍是「媒体时间在前进」这一个事实。
function makeVideo(startSec, rate) {
  const v = {
    paused: true,
    playCalls: 0,
    _base: startSec,
    _since: 0,
    play() { if (v.paused) { v.paused = false; v._since = Date.now(); } v.playCalls++; return Promise.resolve(); },
  };
  Object.defineProperty(v, 'currentTime', {
    get() {
      if (v.paused) return v._base;
      return v._base + ((Date.now() - v._since) / 1000) * rate;
    },
  });
  return v;
}

test('①a 从头开播：把提示窗真播过去才放行', async () => {
  const { sandbox } = loadContent();
  const sec = introSec(sandbox);
  assert.ok(sec > 0, 'kNfIntroOverlaySec 必须是正数秒');
  const v = makeVideo(0, 200); // 200× 媒体时间，窗内耗时 ≈ sec/200 秒
  const t0 = Date.now();
  const ok = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 5000);
  assert.strictEqual(ok, true, '播过窗应返回 true');
  assert.ok(v.currentTime >= sec, '返回时媒体位置必须已越过提示窗');
  assert.ok(Date.now() - t0 >= 1, '不能同步放行（同步放行=完全没等）');
  assert.ok(v.playCalls > 0, '暂停态必须补 play()，否则永远等不到推进');
});

test('①b 中途续播：判据是推进量而不是绝对位置（只看位置会让续播集直接放行）', async () => {
  const { sandbox } = loadContent();
  const sec = introSec(sandbox);
  const v = makeVideo(600, 200); // 已在第 10 分钟：绝对位置远超窗，但这一集刚开播
  const ok = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 5000);
  assert.strictEqual(ok, true);
  assert.ok(v.currentTime - 600 >= sec,
    '必须相对开始等待时的位置再推进一整个提示窗，不能因绝对位置大就放行');
});

test('②  推不动时有上界返回 false，不无限等卡死批量', async () => {
  const { sandbox } = loadContent();
  const v = makeVideo(0, 0); // rate=0：play() 了也不前进（DRM/弱网）
  const t0 = Date.now();
  const ok = await sandbox.fushiWaitPastNetflixIntroOverlay(v, 400);
  assert.strictEqual(ok, false, '到上界仍没播过窗必须返回 false 让批量继续');
  assert.ok(Date.now() - t0 < 3000, '必须在 maxMs 量级内返回');
  assert.ok(v.playCalls > 0, '等待期间应反复补 play()');
});

test('②b 没有 <video> 时立即返回 false（不 hang）', async () => {
  const { sandbox } = loadContent();
  assert.strictEqual(await sandbox.fushiWaitPastNetflixIntroOverlay(null, 400), false);
});

test('③  片头窗内的队列项被放弃，窗外的照录', () => {
  const { sandbox } = loadContent();
  const ms = introSec(sandbox) * 1000;
  const items = [
    { id: 'a', startV: 0 },
    { id: 'b', startV: ms - 1 },
    { id: 'c', startV: ms },        // 边界：窗结束即可录
    { id: 'd', startV: ms + 60000 },
    { id: 'e' },                    // 缺 startV → 当 0 处理，同样放弃
  ];
  const split = sandbox.fushiSplitNetflixIntroOverlayItems(items);
  // Array.from：vm 里造的数组原型属于另一个 realm，deepStrictEqual 会因原型不同而假红。
  assert.deepStrictEqual(Array.from(split.skipped, (q) => q.id), ['a', 'b', 'e']);
  assert.deepStrictEqual(Array.from(split.recordable, (q) => q.id), ['c', 'd']);
  // 放弃 ≠ 丢弃：原数组不被改动，队列项仍在（真正的出队只在 fushiRemoveQueued(okIds)）。
  assert.strictEqual(items.length, 5);
});

test('③b 空输入不炸', () => {
  const { sandbox } = loadContent();
  for (const bad of [undefined, null, []]) {
    const split = sandbox.fushiSplitNetflixIntroOverlayItems(bad);
    assert.deepStrictEqual(Array.from(split.skipped), []);
    assert.deepStrictEqual(Array.from(split.recordable), []);
  }
});

test('③c 放弃必须可见：有被跳过的句就明确告知，0 张时不打扰', () => {
  const { sandbox, toasts } = loadContent();
  sandbox.fushiToastNetflixIntroSkipped(0);
  assert.strictEqual(toasts.length, 0, '没跳过任何句时不应弹提示');
  sandbox.fushiToastNetflixIntroSkipped(3);
  assert.strictEqual(toasts.length, 1);
  assert.match(toasts[0], /3/, '提示里要有被放弃的张数');
  assert.match(toasts[0], /队列/, '要说明卡还留在队列里（没有被静默丢掉）');
});
