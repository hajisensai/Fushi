// PR #804 审查缺陷 2 守卫：youtube-bridge 三路取轨全空时的退避。
//
// 回归形状：acquire() 失败时把在途锁 fetchingFor 清空，而驱动它的是 setInterval(acquire, 1000)
// → 任何**没有字幕轨**的 YouTube 视频都会让扩展每秒发一次 credentials:'same-origin' 的
// POST /youtubei/v1/player，直到用户离开页面。这里用假 fetch + 假时钟数请求次数把它钉死。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SOURCE = fs.readFileSync(path.join(__dirname, 'youtube-bridge.js'), 'utf8');

// 起一个「该视频没有任何字幕轨」的宿主页：#movie_player 不存在、ytInitialPlayerResponse 不存在、
// Innertube 返回 !ok —— 正是线上最常见的无字幕视频形态。
function loadBridge(initialId) {
  let now = 1000000;
  const fetches = [];
  const intervals = [];
  const docListeners = {};
  const winListeners = {};
  let videoParam = initialId;

  const windowObject = {
    ytcfg: { get(key) { return key === 'INNERTUBE_API_KEY' ? 'FAKE_KEY' : 'en'; } },
    addEventListener(type, fn) { (winListeners[type] = winListeners[type] || []).push(fn); },
    postMessage() {},
  };
  const sandbox = {
    window: windowObject,
    document: {
      querySelector() { return null; },
      addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
    },
    location: {
      get pathname() { return '/watch'; },
      get search() { return '?v=' + videoParam; },
      get href() { return 'https://www.youtube.com/watch?v=' + videoParam; },
    },
    URL, URLSearchParams, DOMParser: function () {},
    Date: { now() { return now; } },
    setInterval(fn) { intervals.push(fn); return intervals.length; },
    clearInterval() {},
    fetch(url, init) {
      fetches.push({ url: String(url), method: (init && init.method) || 'GET' });
      return Promise.resolve({ ok: false, status: 404 });
    },
  };
  vm.runInNewContext(SOURCE, sandbox, { filename: 'youtube-bridge.js' });

  // acquire() 里串了 await；用一个宏任务把所有微任务排干。
  const flush = async () => { for (let i = 0; i < 4; i++) await new Promise((r) => setImmediate(r)); };
  return {
    fetches,
    advance(ms) { now += ms; },
    async tick() { for (const fn of intervals) fn(1); await flush(); },
    async navigate(nextId) {
      videoParam = nextId;
      for (const fn of docListeners['yt-navigate-finish'] || []) fn({});
      await flush();
    },
    flush,
  };
}

test('无字幕视频：1s 轮询不得变成 1 req/s —— 失败按 2^n 退避且有放弃上限', async () => {
  const h = loadBridge('novid');
  await h.flush(); // 载入时的首次 acquire
  assert.strictEqual(h.fetches.length, 1, '载入应恰好试一次');
  assert.strictEqual(h.fetches[0].method, 'POST');

  // 退避窗口内空转 30 次（模拟 30 秒轮询）：一次请求都不许再发。
  for (let i = 0; i < 30; i++) await h.tick();
  assert.strictEqual(h.fetches.length, 1, '退避窗口内不得重发（回归时这里会是 31）');

  // 时间推进到退避到期 → 允许再试一次，并把下次窗口翻倍。
  h.advance(2000);
  await h.tick();
  assert.strictEqual(h.fetches.length, 2);
  h.advance(2000);            // 第 2 次失败后窗口是 4s，只推 2s 不够
  await h.tick();
  assert.strictEqual(h.fetches.length, 2, '退避必须是指数增长，不是固定 2s');

  // 一路快进：即使时间无限推进，总次数也停在放弃上限，不再骚扰 YouTube。
  for (let i = 0; i < 50; i++) { h.advance(10 * 60 * 1000); await h.tick(); }
  assert.strictEqual(h.fetches.length, 6, '达到放弃上限后必须彻底停手');
});

test('换视频（yt-navigate-finish）重置退避账本：上个视频的失败不拖累新视频', async () => {
  const h = loadBridge('novid');
  await h.flush();
  for (let i = 0; i < 40; i++) { h.advance(10 * 60 * 1000); await h.tick(); }
  const exhausted = h.fetches.length;
  assert.strictEqual(exhausted, 6);

  await h.navigate('other');
  assert.strictEqual(h.fetches.length, exhausted + 1, '换视频后必须立刻重新取轨一次');
  // 新视频同样无轨 → 重新走完整退避，而不是继承旧账本立刻放弃。
  h.advance(2000);
  await h.tick();
  assert.strictEqual(h.fetches.length, exhausted + 2);
});

test('cue 存档有容量上限（SPA 连刷视频不得无界增长）', () => {
  assert.match(SOURCE, /var CACHE_LIMIT = \d+;/);
  assert.match(SOURCE, /while \(cache\.size > CACHE_LIMIT\)/);
});
