// YouTube 批量制卡在 service worker 里跑（用户 2026-10-04：「点进去放一会儿视频才能制卡，能不能
// 全自动，比如开始生成点完帮忙打开视频之类的」）。
//
// 根因：生成本来只是逐条 {videoId, 起止} → POST /api/mine，服务端自己从真实流裁 GIF+音频，
// 与页面无关；但旧循环写在 YouTube 页的 content script 里，按钮只在 YouTube 页可点，用户只能
// 「点队列条目跳到视频页 → 等页面加载 → 再点生成」。现在循环在 background，任何 tab 都能跑。
//
// 这里在 vm 里真跑 background.js（+ 共用分类器 mine-outcome.js），经 popup 的 fushiIconAction
// 消息入口驱动，断言：非 YouTube tab 也真发了 /api/mine、只出队成功项、结果 toast 回到点击时
// 的 tab、重复点击不开第二条循环、进度经 fushiYtBatchStatus 可查且结束后归零。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const flush = async () => { for (let i = 0; i < 30; i++) await new Promise((r) => setImmediate(r)); };

function permissive() {
  return new Proxy(function () {}, {
    get(_t, key) {
      if (key === 'then' || key === Symbol.toPrimitive) return undefined;
      if (key === 'addListener' || key === 'removeListener') return function () {};
      return permissive();
    },
    apply() { return Promise.resolve({}); },
  });
}

/**
 * @param {object[]} queue 初始 fushiQueue
 * @param {(body: object) => object} respond 每次 /api/mine 的服务端 JSON（或 {__status} 表示非 2xx）
 */
function loadBackground(queue, respond) {
  const store = { fushiQueue: queue };
  const posts = [];
  const toasts = [];
  const broadcasts = [];
  const tabUpdates = [];
  const listeners = [];
  let releaseFetch; // 置为函数时 fetch 挂起，直到测试放行
  let holdAt = 0; // 第 n 次 /api/mine 挂起（模拟那一条慢到 SW 被杀）
  const local = {
    get(keys, cb) {
      const out = {};
      for (const k of [].concat(keys || [])) if (k in store) out[k] = JSON.parse(JSON.stringify(store[k]));
      if (cb) { cb(out); return undefined; }
      return Promise.resolve(out);
    },
    set(obj, cb) { Object.assign(store, JSON.parse(JSON.stringify(obj))); if (cb) cb(); return Promise.resolve(); },
    remove(keys) { for (const k of [].concat(keys)) delete store[k]; return Promise.resolve(); },
  };
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'storage') return new Proxy({ local }, { get: (t, k) => t[k] || permissive() });
      if (key === 'tabs') {
        return new Proxy({}, {
          get(_t2, k2) {
            if (k2 === 'sendMessage') return (tabId, msg, cb) => { toasts.push({ tabId, msg }); if (cb) cb(); };
            if (k2 === 'update') return async (tabId, props) => { tabUpdates.push({ tabId, props }); return {}; };
            return permissive();
          },
        });
      }
      if (key === 'runtime') {
        return new Proxy({}, {
          get(_t2, k2) {
            if (k2 === 'onMessage') return { addListener(fn) { listeners.push(fn); } };
            if (k2 === 'sendMessage') return (msg, cb) => { broadcasts.push(msg); if (cb) cb(); };
            if (k2 === 'lastError') return undefined;
            return permissive();
          },
        });
      }
      return permissive();
    },
  });
  const sandbox = {
    chrome: chromeMock, console,
    fetch: async (url, init) => {
      const body = init && init.body ? JSON.parse(init.body) : null;
      if (!String(url).endsWith('/api/mine')) {
        return { ok: true, status: 200, json: async () => ({}) };
      }
      posts.push(body);
      if (typeof releaseFetch === 'function' || posts.length === holdAt) {
        await new Promise((r) => { releaseFetch = r; });
      }
      const res = respond(body);
      if (res && res.__status) return { ok: false, status: res.__status, json: async () => null };
      return { ok: true, status: 200, json: async () => res };
    },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String, JSON, Array, Object, Math,
    performance, AbortController, Error, RegExp, Map, Set, Boolean, isNaN, parseInt, parseFloat,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'mine-outcome.js'), 'utf8'), sandbox, { filename: 'mine-outcome.js' });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'), sandbox, { filename: 'background.js' });
  return {
    store, posts, toasts, broadcasts, tabUpdates,
    holdFetch() { releaseFetch = () => {}; },
    holdNth(n) { holdAt = n; },
    release() { const r = releaseFetch; releaseFetch = undefined; if (typeof r === 'function') r(); },
    send(msg) {
      let resp;
      for (const fn of listeners) fn(msg, {}, (r) => { resp = r; });
      return resp;
    },
  };
}

const yt = (id, vid, extra) => Object.assign({
  id, site: 'youtube', youtubeId: vid, startV: 1000, endV: 3000,
  fields: { expression: id }, sentence: 's-' + id,
}, extra || {});

test('generates YouTube cards from a non-YouTube tab and keeps only failures + Netflix items queued', async () => {
  const nf = { id: 'n1', site: 'netflix', netflixId: '42' };
  const bg = loadBackground([yt('a', 'vidA'), nf, yt('b', 'vidB')],
    (body) => (body.youtubeVideoId === 'vidA'
      ? { result: 'success' }
      : { result: 'error', message: 'YouTube 视频流解析失败，未制卡' }));
  bg.send({ type: 'fushiIconAction', tab: { id: 7, url: 'https://example.com/' } });
  await flush();

  assert.deepStrictEqual(bg.posts.map((b) => [b.youtubeVideoId, b.clipStartMs, b.clipEndMs]),
    [['vidA', 1000, 3000], ['vidB', 1000, 3000]]);
  assert.deepStrictEqual(bg.store.fushiQueue.map((q) => q.id), ['n1', 'b']);
  const last = bg.toasts[bg.toasts.length - 1];
  assert.strictEqual(last.tabId, 7);
  assert.strictEqual(last.msg.type, 'fushiToastMsg');
  assert.ok(last.msg.text.includes('gen_done_processed'), last.msg.text);
  assert.ok(last.msg.text.includes('YouTube 视频流解析失败'), '失败原因要随结果给出：' + last.msg.text);
  assert.strictEqual(last.msg.sticky, false);
});

test('Netflix tab with only YouTube items still generates YouTube (no wrong-site dead end)', async () => {
  const bg = loadBackground([yt('a', 'vidA')], () => ({ result: 'duplicate' }));
  bg.send({ type: 'fushiIconAction', tab: { id: 3, url: 'https://www.netflix.com/browse' } });
  await flush();
  assert.strictEqual(bg.posts.length, 1);
  assert.deepStrictEqual(bg.store.fushiQueue, []);
});

test('progress is queryable while running, a second click does not start another loop, and it resets after', async () => {
  const bg = loadBackground([yt('a', 'vidA'), yt('b', 'vidB')], () => ({ result: 'success' }));
  bg.holdFetch();
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
  await flush();
  assert.deepStrictEqual(JSON.parse(JSON.stringify(bg.send({ type: 'fushiYtBatchStatus' }).batch)), { done: 0, total: 2 });
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
  await flush();
  assert.strictEqual(bg.posts.length, 1, '重复点击不应开第二条循环');
  bg.release();
  await flush();
  bg.release();
  await flush();
  assert.strictEqual(bg.posts.length, 2);
  assert.strictEqual(bg.send({ type: 'fushiYtBatchStatus' }).batch, null);
  const progress = bg.broadcasts.filter((m) => m && m.type === 'fushiYtBatchProgress');
  assert.ok(progress.some((m) => m.batch && m.batch.done === 1 && m.batch.total === 2));
  assert.strictEqual(progress[progress.length - 1].batch, null, '结束必须广播空闲，popup 才会解锁按钮');
  assert.deepStrictEqual(bg.store.fushiQueue, []);
});

test('Anki not configured keeps the items and says so; settings-fixable HTTP errors offer the settings link', async () => {
  const bg = loadBackground([yt('a', 'vidA')], () => ({ result: 'notConfigured' }));
  bg.send({ type: 'fushiIconAction', tab: { id: 2, url: 'https://example.com/' } });
  await flush();
  assert.deepStrictEqual(bg.store.fushiQueue.map((q) => q.id), ['a']);
  assert.ok(bg.toasts[bg.toasts.length - 1].msg.text.includes('gen_partial_anki_unconfigured'));

  const bg401 = loadBackground([yt('a', 'vidA')], () => ({ __status: 401 }));
  bg401.send({ type: 'fushiIconAction', tab: { id: 2, url: 'https://example.com/' } });
  await flush();
  const last = bg401.toasts[bg401.toasts.length - 1].msg;
  assert.ok(last.text.includes('mine_err_401'), last.text);
  assert.strictEqual(last.openSettings, true);
});

// ── 审查回归：SW 生命周期 / 竞态 / 与 popup 判据一致 ──
test('double click (two messages in the same tick) runs one loop, each card mined once', async () => {
  const bg = loadBackground([yt('a', 'vidA'), yt('b', 'vidB')], () => ({ result: 'success' }));
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
  await flush();
  assert.deepStrictEqual(bg.posts.map((b) => b.youtubeVideoId), ['vidA', 'vidB']);
});

test('a URL that merely contains netflix.com is not a Netflix page', async () => {
  const bg = loadBackground([{ id: 'n1', site: 'netflix', netflixId: '42' }, yt('a', 'vidA')],
    () => ({ result: 'success' }));
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://www.google.com/search?q=netflix.com' } });
  await flush();
  assert.strictEqual(bg.posts.length, 1, '应生成 YouTube，而不是在 Google 页上起 Netflix 录制');
  assert.strictEqual(bg.store.fushiNfBatch, undefined);
});

test('each success leaves the queue at once, so an SW killed mid-batch never re-mines finished cards', async () => {
  const bg = loadBackground([yt('a', 'vidA'), yt('b', 'vidB')], () => ({ result: 'success' }));
  bg.holdNth(2); // 第二条慢到 SW 被杀：此刻 a 必须已经出队
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
  await flush();
  assert.strictEqual(bg.posts.length, 2);
  assert.deepStrictEqual(bg.store.fushiQueue.map((q) => q.id), ['b']);
});

test('cards removed from the queue mid-batch are not mined and are not counted as failures', async () => {
  let bg = null;
  bg = loadBackground([yt('a', 'vidA'), yt('b', 'vidB')], (body) => {
    if (body.youtubeVideoId === 'vidA') bg.store.fushiQueue = bg.store.fushiQueue.filter((q) => q.id !== 'b');
    return { result: 'success' };
  });
  bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
  await flush();
  assert.deepStrictEqual(bg.posts.map((b) => b.youtubeVideoId), ['vidA']);
  const last = bg.toasts[bg.toasts.length - 1].msg.text;
  assert.ok(!last.includes('gen_done_failed_suffix'), '用户删掉的不算失败：' + last);
});

// EMI05fe8RJ：付费电影的卡（服务端 errorKind:permanent）旧实现永远留在待生成队列里，每次生成都
// 先把它们重新解析一遍（每条都走 5 个 client 的网络请求），拖慢并淹没新卡。
test('permanent failure leaves the pending queue for the Failed group and is not re-mined next run', async () => {
  const bg = loadBackground([yt('paid', 'vidPaid'), yt('ok', 'vidOk')],
    (body) => (body.youtubeVideoId === 'vidPaid'
      ? { result: 'error', message: 'YouTube 视频流解析失败，未制卡', errorKind: 'permanent' }
      : { result: 'success' }));
  bg.send({ type: 'fushiIconAction', tab: { id: 7, url: 'https://example.com/' } });
  await flush();
  assert.deepStrictEqual(bg.posts.map((b) => b.youtubeVideoId), ['vidPaid', 'vidOk']);
  assert.strictEqual(bg.store.fushiQueue.length, 1, '失败项留在存储里（失败分组），成功项出队');
  const failed = bg.store.fushiQueue[0];
  assert.strictEqual(failed.id, 'paid');
  assert.strictEqual(failed.failed, true);
  assert.strictEqual(failed.lastError, 'YouTube 视频流解析失败，未制卡');
  const summary = bg.toasts[bg.toasts.length - 1].msg.text;
  assert.ok(summary.includes('gen_done_moved_failed_suffix'), summary);

  // 第二次生成：失败分组里的项不再 POST /api/mine。
  bg.send({ type: 'fushiIconAction', tab: { id: 7, url: 'https://example.com/' } });
  await flush();
  assert.strictEqual(bg.posts.length, 2, '失败项不应再次制卡');
});

test('server-tagged transient errors (AnkiConnect down / bot check) never move the queue to Failed', async () => {
  const bg = loadBackground([yt('a', 'vidA'), yt('b', 'vidB')],
    () => ({ result: 'error', message: 'AnkiConnect 不可达', errorKind: 'transient' }));
  for (let i = 0; i < 5; i++) {
    bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
    await flush();
  }
  assert.strictEqual(bg.posts.length, 10, '每次生成都重试全部待生成项');
  for (const it of bg.store.fushiQueue) {
    assert.strictEqual(it.failed, undefined, it.id + ' 不应因环境类失败被判失败');
    assert.strictEqual(it.attempts, undefined, it.id + ' 不计次');
  }
});

test('untyped server errors (legacy server, no errorKind) escalate to Failed after the attempt cap; unreachable app never counts', async () => {
  let down = true;
  const bg = loadBackground([yt('t', 'vidT')],
    () => (down ? { __status: 502 } : { result: 'error', message: 'timeout' }));
  for (let i = 0; i < 4; i++) {
    bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
    await flush();
  }
  assert.strictEqual(bg.store.fushiQueue[0].failed, undefined, '环境类失败（app 不可达 / 5xx）不计入该项');
  assert.strictEqual(bg.store.fushiQueue[0].attempts, undefined);
  down = false;
  const before = bg.posts.length;
  for (let i = 0; i < 5; i++) {
    bg.send({ type: 'fushiIconAction', tab: { id: 1, url: 'https://example.com/' } });
    await flush();
  }
  assert.strictEqual(bg.posts.length - before, 3, '达到 3 次后移入失败分组，不再重试');
  assert.strictEqual(bg.store.fushiQueue[0].failed, true);
});

// EMI05fe8RJ：Netflix 批量的剧集列表必须与「进 Netflix 分支」同一判据（只认待生成项）。旧实现只要
// 队列里有该集的项就排进批——只剩失败项的那集仍会被导航、等播放器 / 片头门、开录屏后空跑一趟。
test('Netflix batch skips episodes whose queue items are all in the Failed group', async () => {
  const bg = loadBackground([
    { id: 'f1', site: 'netflix', netflixId: '111', failed: true, lastError: 'x' },
    { id: 'p2', site: 'netflix', netflixId: '222' },
    { id: 'f3', site: 'netflix', netflixId: '333', failed: true },
  ], () => ({ result: 'success' }));
  // 当前正播的就是只剩失败项的 111：不能就地开录屏，而是导航到唯一有待生成项的 222。
  bg.send({ type: 'fushiIconAction', tab: { id: 3, url: 'https://www.netflix.com/watch/111' } });
  await flush();
  assert.ok(bg.store.fushiNfBatch, '有待生成项时应起 Netflix 批');
  assert.deepStrictEqual(bg.store.fushiNfBatch.episodes, ['222'], '只剩失败项的剧集不进批');
  assert.deepStrictEqual(bg.tabUpdates.map((u) => u.props.url), ['https://www.netflix.com/watch/222']);
  assert.strictEqual(bg.posts.length, 0, 'Netflix 分支不走 YouTube 队列');
});
