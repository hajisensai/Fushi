// 制卡队列「报成功」必须等于「真的写进了 chrome.storage.local」（反馈 heMh1hn8n4：网页制卡
// 一直提示「已加入队列 (N)」，统一生成时少了一大截，攒到十几条以后全丢）。
//
// 根因：旧 fushiEnqueue 往内存镜像 push 后 fire-and-forget 一次 storage.set（不 await，
// try/catch 只接得住同步抛），再按**内存镜像**的长度回报成功：
//   · 写入被拒（配额 / 扩展已更新后旧 content script 的 context invalidated）照样报成功；
//   · 写入内容是内存镜像而非 storage 现值——镜像会被延迟到达的 storage.onChanged 旧值覆盖，
//     下一次入队就把旧镜像整份写回，前一条（或别的标签 / 图标 popup 刚改的）被冲掉。
//
// 这里在 vm 里真加载 content.js，storage 用可控替身（set 可拒绝、onChanged 可延迟投递），断言：
//   1) set 被拒 → 入队返回 ok:false / persist-failed，storage 不变，句子草稿不清；
//   2) 扩展上下文失效（chrome.runtime.id 消失、storage 调用同步抛）→ context-invalidated；
//   3) 连续入队 + 迟到的 onChanged 旧值不丢项；
//   4) 别处（图标 popup / background）刚改过的 storage 不会被本标签的旧镜像写回；
//   5) 回报的 count 是落盘后的真实长度。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const PROVIDERS = path.join(__dirname, 'subtitle-providers.js');
const CONTENT = path.join(__dirname, 'content.js');
const DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
const POPUP_SIZE = path.join(__dirname, 'popup-size.js');

const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };
const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));

/**
 * @param {{ initialQueue?: object[] }} opts
 */
function loadContent(opts = {}) {
  const store = { fushiQueue: clone(opts.initialQueue || []) };
  const changeListeners = [];
  const pendingChanges = []; // 已写入、onChanged 尚未投递（模拟事件迟到）
  const ctl = {
    rejectSet: null, // Error → set 返回被拒的 Promise
    invalidated: false, // true → storage 调用同步抛 + runtime.id 消失
    holdChanges: false, // true → onChanged 攒着，等测试手动投递
  };
  const runtime = { lastError: null, onMessage: { addListener() {} }, sendMessage() {} };
  Object.defineProperty(runtime, 'id', { get: () => (ctl.invalidated ? undefined : 'test-ext-id') });
  const invalidatedError = () => new Error('Extension context invalidated.');
  const local = {
    get(keys, cb) {
      if (ctl.invalidated) throw invalidatedError();
      const out = {};
      for (const k of [].concat(keys || [])) if (k in store) out[k] = clone(store[k]);
      if (cb) { cb(out); return undefined; }
      return Promise.resolve(out);
    },
    set(obj) {
      if (ctl.invalidated) throw invalidatedError();
      if (ctl.rejectSet) return Promise.reject(ctl.rejectSet);
      const changes = {};
      for (const k of Object.keys(obj)) {
        changes[k] = { oldValue: clone(store[k]), newValue: clone(obj[k]) };
        store[k] = clone(obj[k]);
      }
      pendingChanges.push(changes);
      if (!ctl.holdChanges) deliverChanges();
      return Promise.resolve();
    },
  };
  /** 投递攒着的 onChanged；[limit] 给了就只投前 limit 条（模拟只有较早那次写入的事件先到）。 */
  function deliverChanges(limit) {
    let n = limit === undefined ? Infinity : limit;
    while (pendingChanges.length && n-- > 0) {
      const c = pendingChanges.shift();
      for (const fn of changeListeners) fn(c, 'local');
    }
  }
  const video = { currentTime: 4.2, paused: true, seeking: false, textTracks: [],
    addEventListener() {}, removeEventListener() {} };
  const windowObj = {
    addEventListener() {},
    postMessage() {},
    innerWidth: 1200,
    innerHeight: 800,
    matchMedia: () => ({ matches: false }),
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: () => 1,
    clearInterval() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    performance: { now: () => 0 },
    location: {
      hostname: 'www.netflix.com',
      href: 'https://www.netflix.com/watch/81001',
      pathname: '/watch/81001',
      origin: 'https://www.netflix.com',
      search: '',
    },
    window: windowObj,
    document: {
      documentElement: { dataset: {}, setAttribute() {} },
      head: { appendChild() {} },
      body: { appendChild() {}, style: {} },
      fullscreenElement: null,
      addEventListener() {},
      getElementById: () => null,
      querySelector: (sel) => (sel === 'video' ? video : null),
      querySelectorAll: () => [],
      createElement: () => ({
        style: {}, addEventListener() {}, appendChild() {}, setAttribute() {}, remove() {},
        classList: { add() {} },
      }),
    },
    chrome: {
      runtime,
      storage: { local, onChanged: { addListener(fn) { changeListeners.push(fn); } } },
    },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), ctx, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(DICT_MEDIA, 'utf8'), ctx, { filename: 'vendor/dict-media.js' });
  vm.runInContext(fs.readFileSync(POPUP_SIZE, 'utf8'), ctx, { filename: 'popup-size.js' });
  vm.runInContext(fs.readFileSync(PROVIDERS, 'utf8'), ctx, { filename: 'subtitle-providers.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), ctx, { filename: 'content.js' });
  windowObj.fushiActiveFullTrack = () => ({ lang: 'ja', cues: [
    { startMs: 1000, endMs: 2000, text: '第一句' },
    { startMs: 4000, endMs: 5000, text: '第三句 当前' },
    { startMs: 7000, endMs: 8000, text: '第五句' },
  ] });
  return { windowObj, store, ctl, deliverChanges, ctx };
}

const words = (h) => (h.store.fushiQueue || []).map((q) => q.fields.expression);
const plain = (v) => JSON.parse(JSON.stringify(v));

test('storage.set 被拒（配额满等）→ 入队报失败，不冒充成功，storage 不变', async () => {
  const h = loadContent({ initialQueue: [] });
  await flush();
  h.ctl.rejectSet = new Error('QUOTA_BYTES quota exceeded');
  h.windowObj.fushiSetSentenceContext(1, 0);
  const r = await h.windowObj.fushiEnqueue({ expression: '当前' }, '');
  assert.strictEqual(r.ok, false, '写盘失败必须如实报失败');
  assert.strictEqual(r.reason, 'persist-failed');
  assert.deepStrictEqual(words(h), []);
  assert.strictEqual(h.windowObj.fushiSentenceContextPreview({}).total, 1,
    '没入队成功，一次性句子草稿不得被清掉');
  assert.strictEqual(h.windowObj.fushiIsEntryQueued({ expression: '当前' }), false,
    '按钮状态不能显示「已在队列」');
});

test('扩展已更新（旧 content script 的 context invalidated）→ 入队报 context-invalidated', async () => {
  const h = loadContent({ initialQueue: [] });
  await flush();
  h.ctl.invalidated = true;
  const r = await h.windowObj.fushiEnqueue({ expression: '当前' }, '');
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.reason, 'context-invalidated');
  h.ctl.invalidated = false;
  assert.deepStrictEqual(words(h), []);
});

test('连续入队 + 迟到的 onChanged 旧值：一条不丢，count 是落盘后的真实长度', async () => {
  const h = loadContent({ initialQueue: [] });
  await flush();
  h.ctl.holdChanges = true;
  const a = await h.windowObj.fushiEnqueue({ expression: 'A' }, '');
  const b = await h.windowObj.fushiEnqueue({ expression: 'B' }, '');
  // A 那次写入的 onChanged 现在才到（B 的还在路上）：镜像被拉回 [A]。
  h.deliverChanges(1);
  // 旧实现在这里把镜像 [A] 加上 C 整份写回 → B 丢失。
  const c = await h.windowObj.fushiEnqueue({ expression: 'C' }, '');
  h.ctl.holdChanges = false;
  h.deliverChanges();
  assert.deepStrictEqual(plain([a.count, b.count, c.count]), [1, 2, 3]);
  assert.deepStrictEqual(words(h), ['A', 'B', 'C']);
});

test('同一刻并发入队（不 await 前一次）也逐条落盘', async () => {
  const h = loadContent({ initialQueue: [] });
  await flush();
  const rs = await Promise.all([
    h.windowObj.fushiEnqueue({ expression: 'A' }, ''),
    h.windowObj.fushiEnqueue({ expression: 'B' }, ''),
  ]);
  assert.ok(rs.every((r) => r.ok));
  assert.deepStrictEqual(words(h).slice().sort(), ['A', 'B']);
});

test('别处刚改过的 storage（popup 删项 / 别的标签入队）不会被本标签的旧镜像写回', async () => {
  const h = loadContent({ initialQueue: [] });
  await flush();
  await h.windowObj.fushiEnqueue({ expression: 'A' }, '');
  // 图标 popup 删掉了 A、另一个标签加了 X；本标签的 onChanged 还没到。
  h.ctl.holdChanges = true;
  const other = plain(h.store.fushiQueue);
  other[0] = Object.assign({}, other[0], { id: 'x', fields: { expression: 'X' } });
  h.store.fushiQueue = other;
  const r = await h.windowObj.fushiEnqueue({ expression: 'B' }, '');
  assert.strictEqual(r.ok, true);
  assert.strictEqual(r.count, 2);
  assert.deepStrictEqual(words(h), ['X', 'B'], '入队按 storage 现值读-改-写，不复活已删项、不冲掉别处新增');
});

test('重复入队按 storage 现值判定，回报 duplicate 与真实长度', async () => {
  const h = loadContent({ initialQueue: [] });
  await flush();
  await h.windowObj.fushiEnqueue({ expression: 'A' }, '');
  const again = await h.windowObj.fushiEnqueue({ expression: 'A' }, '');
  assert.strictEqual(again.ok, true);
  assert.strictEqual(again.duplicate, true);
  assert.strictEqual(again.count, 1);
  assert.deepStrictEqual(words(h), ['A']);
});

// 队列设计上跨刷新 / 跨剧集 / 跨会话累积，每项带整份释义 HTML（glossary + singleGlossaries），
// 而 chrome.storage.local 默认只有 10 MB 配额——攒到十几条重释义的卡就写不进去了。
// unlimitedStorage 在 Chrome 上不弹权限提示；两份 manifest（真源 + app 打包镜像）都要有。
test('两份 manifest 都声明 unlimitedStorage（制卡队列不受 storage.local 10 MB 配额限制）', () => {
  for (const dir of [__dirname, path.join(__dirname, '..', '..', 'fushi', 'assets', 'browser_extension')]) {
    const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
    assert.ok((manifest.permissions || []).includes('unlimitedStorage'),
      dir + '/manifest.json 缺 unlimitedStorage');
  }
});
