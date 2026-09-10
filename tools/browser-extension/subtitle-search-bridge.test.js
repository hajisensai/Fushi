// 「查字幕」扩展桥的统一化守卫。
//
// 起因：Side Panel 的查字幕**只有 Jimaku 一家**（消息 jimakuSearch/jimakuFetch → app 的
// /api/subtitle/jimaku/*，那条链路直连 JimakuClient），而 app 内视频页的「找字幕」早就
// 走 VideoSubtitleRegistry，Jimaku / OpenSubtitles / AJATT 三家都在。于是同一个用户在两个
// 入口能力不同：没填 Jimaku key 的人在扩展里一个来源都没有，哪怕零配置的 AJATT 就摆在那。
//
// 本文件钉两侧的 wire：
// - background.js：消息类型 → 端点 URL + body（可在 vm 里真跑）；
// - side-panel.js：来源标签、错误码文案分支、部分失败提示（源码断言——渲染这一段需要
//   整份 DOM 宿主，而这里要守的恰恰是「有没有把 provider 显示出来」这类字段级契约）。
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const flush = async () => { for (let i = 0; i < 6; i++) await new Promise((r) => setImmediate(r)); };

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

function loadBackground(responseData) {
  const posts = [];
  const messageListeners = [];
  const chromeMock = new Proxy({}, {
    get(_t, key) {
      if (key === 'runtime') {
        return new Proxy({}, {
          get(_t2, k2) {
            if (k2 === 'onMessage') return { addListener(fn) { messageListeners.push(fn); } };
            return permissive();
          },
        });
      }
      return permissive();
    },
  });
  const sandbox = {
    chrome: chromeMock, console,
    fetch: (url, init) => {
      posts.push({
        url: String(url),
        body: init && init.body ? JSON.parse(init.body) : null,
        signal: init && init.signal,
      });
      return Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve(responseData || { ok: true }),
      });
    },
    setTimeout, clearTimeout, setInterval: () => 1, clearInterval,
    URL, TextEncoder, TextDecoder, Promise, Date, Number, String, JSON, Array, Object, Math,
    performance, AbortController, AbortSignal, Error, RegExp, Map, Set, Boolean, isNaN,
    parseInt, parseFloat,
    crypto: require('node:crypto').webcrypto,
    btoa: (s) => Buffer.from(s, 'binary').toString('base64'),
    atob: (s) => Buffer.from(s, 'base64').toString('binary'),
  };
  sandbox.self = sandbox;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8'),
      sandbox, { filename: 'background.js' });
  const replies = [];
  return {
    posts,
    replies,
    send(msg) { for (const fn of messageListeners) fn(msg, {}, (v) => replies.push(v)); },
  };
}

async function postFor(msg, responseData) {
  const bg = loadBackground(responseData);
  bg.send(msg);
  await flush();
  return bg;
}

test('搜索走通用端点 /api/subtitle/search（不再是 jimaku 专用路径）', async () => {
  const bg = await postFor({ type: 'subtitleSearch', query: 'ぼっち・ざ・ろっく', episode: 3 });
  const hits = bg.posts.filter((p) => p.url.endsWith('/api/subtitle/search'));
  assert.equal(hits.length, 1, '应当只打一次通用搜索端点');
  assert.equal(hits[0].body.query, 'ぼっち・ざ・ろっく');
  assert.equal(hits[0].body.episode, 3);
  assert.ok(!bg.posts.some((p) => p.url.includes('/subtitle/jimaku/')),
      '不得再打 jimaku 专用端点——那条路只留给滞留的旧扩展副本');
});

test('下载走 /api/subtitle/fetch，body 只带 handle', async () => {
  const bg = await postFor({ type: 'subtitleFetch', handle: 'ajatt:anime_tv/x.html:ep01.srt' });
  const hits = bg.posts.filter((p) => p.url.endsWith('/api/subtitle/fetch'));
  assert.equal(hits.length, 1);
  assert.deepEqual(hits[0].body, { handle: 'ajatt:anime_tv/x.html:ep01.srt' });
});

test('集数非整数不发 episode 键（server 据此判「不过滤集数」）', async () => {
  const bg = await postFor({ type: 'subtitleSearch', query: 'x', episode: NaN });
  const body = bg.posts.filter((p) => p.url.endsWith('/api/subtitle/search'))[0].body;
  assert.ok(!('episode' in body));
});

test('搜索超时留给 AJATT 首次拉目录：明显长于普通端点', () => {
  const src = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  const block = src.slice(src.indexOf("msg.type === 'subtitleSearch'"),
      src.indexOf("msg.type === 'subtitleFetch'"));
  const timeout = /AbortSignal\.timeout\((\d+)\)/.exec(block);
  assert.ok(timeout, '搜索仍须带超时，不能挂死');
  assert.ok(Number(timeout[1]) >= 40000,
      'AJATT 第一次要拉约 9MB 静态目录，20 秒会在零配置用户的第一次使用上稳定超时');
});

test('响应原样回给 Side Panel（含 candidates / failures，不在 background 里裁字段）', async () => {
  const payload = {
    ok: true,
    candidates: [{ handle: 'ajatt:a:b.srt', provider: 'ajatt', fileName: 'b.srt' }],
    failures: [{ provider: 'opensubtitles', error: 'rate-limited' }],
  };
  const bg = await postFor({ type: 'subtitleSearch', query: 'x' }, payload);
  assert.equal(bg.replies.length, 1);
  assert.deepEqual(bg.replies[0].data, payload);
});

// ── Side Panel 侧：字段级契约（渲染整块需要完整 DOM 宿主，这里守的是「有没有用上」）──
const SIDE_PANEL = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');

test('Side Panel 发的是通用消息类型', () => {
  assert.match(SIDE_PANEL, /type: 'subtitleSearch'/);
  assert.match(SIDE_PANEL, /type: 'subtitleFetch'/);
  assert.ok(!/type: 'jimakuSearch'/.test(SIDE_PANEL));
  assert.ok(!/type: 'jimakuFetch'/.test(SIDE_PANEL));
});

test('三家来源都有展示名，候选行把 provider 显示出来', () => {
  assert.match(SIDE_PANEL, /jimaku: 'Jimaku'/);
  assert.match(SIDE_PANEL, /opensubtitles: 'OpenSubtitles'/);
  assert.match(SIDE_PANEL, /ajatt: 'AJATT'/);
  assert.match(SIDE_PANEL, /providerLabel\(candidate\.provider\)/,
      '同一部作品三家都可能有，不显示来源就没法选');
});

test('no-provider 有独立文案：不能再一律说「去填 Jimaku API key」', () => {
  assert.match(SIDE_PANEL, /error === 'no-provider'/);
  const branch = SIDE_PANEL.slice(SIDE_PANEL.indexOf("error === 'no-provider'"));
  const text = branch.slice(0, branch.indexOf('\n', branch.indexOf('return')) + 1);
  assert.match(text, /AJATT/, '零配置的 AJATT 是没填 key 的用户唯一能直接开的来源，得提到它');
});

test('部分来源失败时结果照出，另外提示少了谁', () => {
  assert.match(SIDE_PANEL, /failedProviderNames/);
  const search = SIDE_PANEL.slice(SIDE_PANEL.indexOf('async function subsSearch'));
  const renderAt = search.indexOf('renderSubsResults(');
  const failedAt = search.indexOf('failedProviderNames(data)');
  assert.ok(renderAt > 0 && failedAt > renderAt,
      '必须先渲染结果再提示失败来源——反过来就成了「一家挂了就当没搜到」');
});
