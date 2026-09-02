// fushiClipSource() 的守卫：制卡走批量队列还是立即出卡，判据是「本页的原始媒体能不能按
// 时间窗裁」+ 用哪种裁法，不是站点名枚举。
//
// 这是「B 站外挂字幕制卡没有截图 + 例句」那条 bug 的结构性部分：判据写成站点名时，每加一个
// 站点都要改一处 if，而 bilibili.com 从来没被加进去，就永远落在「普通网页」分支上。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(
  path.join(__dirname, 'subtitle-providers.js'), 'utf8');

// subtitle-providers.js 是浏览器脚本：顶层有 setInterval 采样器和 window 消息监听。
// 这里只关心站点判定这几个纯函数，其余全部 stub 成 no-op（定时器若真跑起来，node --test
// 会因为句柄未释放而挂住）。
function load(href) {
  const url = new URL(href);
  const ctx = {
    location: {
      href: href,
      hostname: url.hostname,
      pathname: url.pathname,
      search: url.search,
    },
    document: {
      querySelector: () => null,
      querySelectorAll: () => [],
      addEventListener: () => {},
    },
    window: {
      addEventListener: () => {},
      postMessage: () => {},
    },
    setInterval: () => 0,
    clearInterval: () => {},
    setTimeout: () => 0,
    URL,
    WeakSet,
    MutationObserver: function () {
      return { observe: () => {}, disconnect: () => {} };
    },
    console,
  };
  ctx.window.location = ctx.location;
  vm.createContext(ctx);
  vm.runInContext(SRC, ctx);
  return ctx;
}

// vm 里造出来的对象与本 realm 的 Object 原型不同，deepStrictEqual 会判「结构相同但引用不等」。
// 逐字段比，顺带把断言写得更明确。
function assertClip(actual, expected, msg) {
  assert.ok(actual, `${msg}: 期望有可裁源，实际 ${actual}`);
  for (const k of Object.keys(expected)) {
    assert.strictEqual(actual[k], expected[k], `${msg}: 字段 ${k}`);
  }
}

test('bilibili.com 稿件页 → immediate 档（服务端从原始流裁，点一下即出卡）', () => {
  const ctx = load('https://www.bilibili.com/video/BV1Este6wExx');
  assert.strictEqual(ctx.fushiSite(), 'bilibili');
  assertClip(ctx.fushiClipSource(), {
    kind: 'bilibili', id: 'BV1Este6wExx', part: 1, mode: 'immediate',
  }, 'bilibili 稿件页');
});

test('分 P 号从 ?p= 取（不同 P 是不同 cid，服务端要靠它裁对音轨）', () => {
  const ctx = load('https://www.bilibili.com/video/BV1Este6wExx?p=13&t=61');
  assert.strictEqual(ctx.fushiClipSource().part, 13);
});

test('畸形 / 缺失 / 非法 p 一律按第 1 P，不产生 NaN', () => {
  for (const q of ['', '?p=', '?p=abc', '?p=0', '?p=-3']) {
    const ctx = load('https://www.bilibili.com/video/BV1Este6wExx' + q);
    assert.strictEqual(ctx.fushiClipSource().part, 1, `query=${q}`);
  }
});

test('B 站番剧页不谎报可裁（pgc 走另一套 epid→cid，服务端还没有解析器）', () => {
  const ctx = load('https://www.bilibili.com/bangumi/play/ep1234567');
  assert.strictEqual(ctx.fushiSite(), 'bilibili');
  assert.strictEqual(ctx.fushiClipSource(), null,
    '拿不到 bvid 就该返回 null —— 卡照样出（解码帧+例句），只是没有句子音频');
});

test('bilibili.tv（国际站）不是 bilibili.com，不得混为一谈', () => {
  const ctx = load('https://www.bilibili.tv/en/video/4789543858810880');
  assert.strictEqual(ctx.fushiSite(), 'other');
  assert.strictEqual(ctx.fushiClipSource(), null);
});

test('Netflix / YouTube 仍是 queue 档，行为不变', () => {
  assertClip(load('https://www.netflix.com/watch/81234567').fushiClipSource(),
    { kind: 'netflix', id: '81234567', mode: 'queue' }, 'netflix');

  assertClip(
    load('https://www.youtube.com/watch?v=dQw4w9WgXcQ').fushiClipSource(),
    { kind: 'youtube', id: 'dQw4w9WgXcQ', mode: 'queue' }, 'youtube');

  assertClip(load('https://youtu.be/dQw4w9WgXcQ').fushiClipSource(),
    { kind: 'youtube', id: 'dQw4w9WgXcQ', mode: 'queue' }, 'youtu.be');
});

test('无法定位视频 id 时不给出半个可裁源', () => {
  const nf = load('https://www.netflix.com/browse');
  assert.strictEqual(nf.fushiClipSource(), null);
  const yt = load('https://www.youtube.com/feed/subscriptions');
  assert.strictEqual(yt.fushiClipSource(), null);
});

test('普通网页没有可裁源（但这不妨碍它出卡）', () => {
  const ctx = load('https://example.com/article/1');
  assert.strictEqual(ctx.fushiSite(), 'other');
  assert.strictEqual(ctx.fushiClipSource(), null);
});

test('videoKey 对 B 站仍是 host+path —— 站点判定改动不得动既有字幕轨 key', () => {
  const ctx = load('https://www.bilibili.com/video/BV1Este6wExx?p=2');
  assert.strictEqual(ctx.fushiVideoKey(),
    'www.bilibili.com/video/BV1Este6wExx',
    '轨 key 一旦变化，用户已挂上的外挂字幕就会找不到');
});
