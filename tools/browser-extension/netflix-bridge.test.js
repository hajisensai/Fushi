const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1219 复诉根因守卫：主世界 netflix-bridge.js document_start 抓字幕并 postMessage，隔离世界
// content.js document_idle 才注册接收端——先于接收端发出的 cue 消息永久丢失，store 空 → 勾选面板
// 开关无物可挂（用户「必须刷新页面才加载出来」）、只剩预取下一集轨（「面板出现但列表空」）。
// 修复契约：bridge 存档所有已抓 cue payload，收到 {__fushiNf:'replayCues'} 时整批重放。
// 本测试在受控 vm 里真加载 netflix-bridge.js：喂 JSON.parse 一份含 timedtexttracks 的播放清单
// （全语言多轨），等 fetch 完成后清空收件箱，再发 replayCues，断言全部轨被重放。

const BRIDGE = path.join(__dirname, 'netflix-bridge.js');

function loadBridge(opts) {
  opts = opts || {};
  // BUG-769：window.origin 与 location.origin 在 file:// 下不同——前者是 opaque origin 序列化 'null'，
  // 后者是 'file://'。桥的接收端比对期望源现改用 window.origin，故 harness 两者都要能独立设置。
  const locationOrigin = opts.locationOrigin || 'https://www.netflix.com';
  const windowOrigin = opts.windowOrigin || locationOrigin;
  const src = fs.readFileSync(BRIDGE, 'utf8');
  const posted = [];
  const listeners = [];
  const fetched = [];
  // BUG-1728 失败注入：behavior.failing=true 时 fetch reject（模拟 CORS/网络失败），
  // 测试中途翻回 false 验证「失败后同一 URL 可重试」。
  const behavior = { failing: !!opts.failing };
  const windowObj = {
    location: { origin: locationOrigin, pathname: opts.pathname || '/watch/81001' },
    origin: windowOrigin,
    postMessage: (msg, origin) => posted.push({ msg, origin }),
    addEventListener: (t, fn) => { if (t === 'message') listeners.push(fn); },
  };
  // BUG-1949：播放器 API 桩——嗅探到的字幕正文用它取「当前轨」语言。
  const player = {
    track: opts.track === undefined ? { bcp47: 'ja', displayName: '日本語', trackId: 'T:ja-1' } : opts.track,
    time: 0,
    seeks: [],
    // 正片会话 id 以 'watch' 开头；预告 / billboard 会话排在它后面也不能被选中。
    sessionIds: opts.sessionIds || ['watch-81001', 'motion-billboard-1'],
  };
  // 播放器状态通道桩：textTracks = getTimedTextTrackList()；stateUrls（trackId → url）按结构
  // 埋进会话状态深处（与真播放器一样不在固定路径上）；setTimedTextTrack 可选「切过去就下发地址」。
  player.textTracks = opts.textTracks || [];
  player.stateUrls = opts.stateUrls || {};
  player.setCalls = [];
  const watchPlayer = {
    getTimedTextTrackList: () => player.textTracks,
    setTimedTextTrack: (t) => {
      player.setCalls.push(t && t.trackId);
      player.track = t;
      if (opts.urlOnSelect && t && opts.urlOnSelect[t.trackId]) player.stateUrls[t.trackId] = opts.urlOnSelect[t.trackId];
      return Promise.resolve();
    },
    getTimedTextTrack: () => player.track,
    getCurrentTime: () => player.time,
    seek: (ms) => { player.seeks.push(ms); if (!opts.seekNeverLands) player.time = ms; },
  };
  const trailerPlayer = {
    getTimedTextTrack: () => ({ bcp47: 'en', trackId: 'T:trailer' }),
    getCurrentTime: () => 0,
    seek: () => { throw new Error('seek reached the trailer player'); },
  };
  if (opts.withPlayer !== false) {
    windowObj.netflix = {
      appContext: {
        state: {
          playerApp: {
            getState: () => ({
              videoPlayer: {
                cadmiumPlayerRepository: {
                  playersById: {
                    'watch-81001': {
                      a: { b: { buffers: [new ArrayBuffer(8)], c: Object.keys(player.stateUrls).map((id) => ({
                        d: { type: 'timedtext', trackId: id, urls: [{ url: player.stateUrls[id], cdnId: 1 }] },
                      })) } },
                    },
                  },
                },
              },
            }),
            getAPI: () => ({
              videoPlayer: {
                getAllPlayerSessionIds: () => player.sessionIds,
                getVideoPlayerBySessionId: (id) => (String(id).indexOf('watch') === 0 ? watchPlayer : trailerPlayer),
              },
            }),
          },
        },
      },
    };
  }
  // BUG-1949：受控 XMLHttpRequest —— 桥在 document_start 给 prototype 打补丁，测试里构造实例、
  // 设好 responseType/responseText/response 后 send() → fire('load') 模拟播放器自下字幕文件。
  const xhrs = [];
  const intervals = [];
  class FakeXhr {
    constructor() { this.listeners = {}; this.responseType = ''; this.responseText = ''; this.response = null; xhrs.push(this); }
    open(method, url) { this.method = method; this.url = String(url); }
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
    send() { this.sent = true; }
    fire(type) { for (const fn of this.listeners[type] || []) fn({ target: this }); }
  }
  class FakeResponse {
    constructor(url, body) { this.url = url; this.body = body; }
    text() { return Promise.resolve(this.body); }
    arrayBuffer() { return Promise.resolve(new TextEncoder().encode(this.body).buffer); }
  }
  const sandbox = {
    window: windowObj,
    XMLHttpRequest: FakeXhr,
    Response: FakeResponse,
    TextDecoder,
    TextEncoder,
    Uint8Array,
    Math,
    setTimeout: (fn) => { fn(); return 0; },
    setInterval: (fn) => { intervals.push(fn); return 0; },
    Date: opts.Date || Date,
    // BUG-1728：记录 fetch 第二参（init）供「不带 credentials」断言；mock 响应带 ok/status
    //（实现按 r.ok 分流成功/失败）。
    fetch: (url, init) => {
      fetched.push({ url, init });
      if (behavior.failing) return Promise.reject(new Error('mock CORS/network failure'));
      return Promise.resolve({
        ok: true,
        status: 200,
        text: () => Promise.resolve('WEBVTT\n\n00:01.000 --> 00:02.000\nhello from ' + url),
      });
    },
    console: { warn: () => {}, log: () => {}, error: () => {} },
    Array,
    Object,
    Error,
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(src, ctx, { filename: 'netflix-bridge.js' });
  return { posted, listeners, fetched, ctx, windowObj, behavior, player, FakeXhr, FakeResponse, xhrs, intervals,
    tick() { for (const fn of intervals) fn(); } };
}

const TTML_BODY = '<?xml version="1.0" encoding="utf-8"?>\n<tt ttp:contentProfiles="http://www.netflix.com/ns/ttml2/profiles/2023-1/nflx-tt.xml" xmlns="http://www.w3.org/ns/ttml">\n<body><div><p begin="00:00:01.000" end="00:00:02.000">こんにちは</p></div></body></tt>';
const VTT_BODY = 'WEBVTT\n\n00:01.000 --> 00:02.000\nhello from sniffed xhr\n';
const CDN_URL = 'https://ipv4-c092-hkg001-ix.1.oca.nflxvideo.net/?o=1&v=53&e=1&t=abc';

function cuesPosted(h) {
  return h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues');
}

function makeManifest() {
  const track = (lang, url) => ({
    language: lang,
    ttDownloadables: { 'webvtt-lssdh-ios8': { urls: [{ url }] } },
  });
  return {
    movieId: 81001,
    timedtexttracks: [
      track('ja', 'https://cdn/ja.vtt'),
      track('en', 'https://cdn/en.vtt'),
      track('zh-Hans', 'https://cdn/zh.vtt'),
    ],
  };
}

// 按需取轨是 promise 链（每轮地址轮询 = 一次分片遍历 + 250 ms 间隔，harness 的 setTimeout 同步执行），
// 链长随轮询次数变；一次宏任务把全部已排队微任务冲刷干净，不按固定拍数猜。
function drainMicrotasks() {
  return new Promise((resolve) => setImmediate(resolve));
}

async function settle() {
  // fetch().then 链两级微任务：多让几拍确保 postMessage 已发生。
  for (let i = 0; i < 5; i++) await Promise.resolve();
}

test('bridge 抓全语言轨并在 replayCues 时整批重放（修「勾选要刷新/列表空」）', async () => {
  const h = loadBridge();
  // 触发 JSON.parse hook（vm 上下文内的 JSON 已被 bridge 替换）。
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')', h.ctx);
  await settle();
  assert.strictEqual(h.fetched.length, 3, '三条语言轨都必须被抓取（无语言过滤）');
  const first = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues');
  assert.strictEqual(first.length, 3, '三条轨都必须 post 给隔离世界');
  const langs = first.map((p) => p.msg.lang).sort();
  assert.deepStrictEqual(langs, ['en', 'ja', 'zh-Hans'], '语言标签原样透传');
  assert.strictEqual(String(first[0].msg.videoId), '81001');

  // 模拟 content.js 晚注入：此前的消息全部「丢失」（清空收件箱），随后请求重放。
  h.posted.length = 0;
  for (const fn of h.listeners) {
    fn({
      origin: 'https://www.netflix.com',
      source: h.windowObj,
      data: { __fushiNf: 'replayCues' },
    });
  }
  const replayed = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues');
  assert.strictEqual(replayed.length, 3, 'replayCues 必须整批重放已存档的轨');
  assert.deepStrictEqual(replayed.map((p) => p.msg.lang).sort(), ['en', 'ja', 'zh-Hans']);
  // 重放的是同一份 payload（存档非重新抓取）。
  assert.strictEqual(h.fetched.length, 3, '重放不得重新发起网络抓取');
});

test('replayCues 只认同源同窗消息（不被宿主页第三方 iframe 驱动）', async () => {
  const h = loadBridge();
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')', h.ctx);
  await settle();
  h.posted.length = 0;
  for (const fn of h.listeners) {
    fn({ origin: 'https://evil.example', source: h.windowObj, data: { __fushiNf: 'replayCues' } });
    fn({ origin: 'https://www.netflix.com', source: {}, data: { __fushiNf: 'replayCues' } });
  }
  assert.strictEqual(h.posted.length, 0, '跨源/跨窗的 replayCues 必须被忽略');
});

test('BUG-769 opaque origin（file://）下 cue 往返不丢：自投用 "/"、接收端认 window.origin', async () => {
  // file:// 页 opaque origin：window.origin 序列化成 'null'，而 location.origin 返回 'file://'。
  // 旧代码自投用 location.origin('file://') 作 targetOrigin → 与 recipient 真实源 'null' 不匹配 →
  // postMessage 抛错、消息永久丢失（store 空、面板列表空）；接收端 e.origin 比对 location.origin 也永远失败。
  const h = loadBridge({ locationOrigin: 'file://', windowOrigin: 'null' });
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')', h.ctx);
  await settle();
  const cues = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues');
  assert.strictEqual(cues.length, 3, 'file:// 下仍抓全 3 轨');
  // targetOrigin 必须是 "/"（= 仅同源同窗投递，对不透明源成立）；绝不能是 location.origin/'file://'。
  for (const p of cues) {
    assert.strictEqual(p.origin, '/', 'file:// 自投必须用 "/" 作 targetOrigin');
  }

  // content.js 晚注入后请求重放：e.origin 为不透明源序列化 'null'，接收端须认可（ORIGIN=window.origin='null'）。
  h.posted.length = 0;
  for (const fn of h.listeners) {
    fn({ origin: 'null', source: h.windowObj, data: { __fushiNf: 'replayCues' } });
  }
  const replayed = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues');
  assert.strictEqual(replayed.length, 3, 'file:// opaque origin 的 replayCues 必须被接收端认可并整批重放');
  for (const p of replayed) {
    assert.strictEqual(p.origin, '/', '重放同样用 "/" 作 targetOrigin');
  }
});

// ── BUG-1728：整轨拦截静默失败（用户只剩「实时采集」轨）守卫 ──
test('BUG-1728 字幕轨 fetch 不带 credentials（跨源 CDN 回 ACAO:* 时带凭据请求被 CORS 整个拒掉）', async () => {
  const h = loadBridge();
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')', h.ctx);
  await settle();
  assert.strictEqual(h.fetched.length, 3);
  for (const f of h.fetched) {
    const cred = f.init && f.init.credentials;
    assert.ok(cred === undefined || cred === 'omit',
      'timedtext fetch 不得携带 credentials（收到 ' + JSON.stringify(f.init) + '）——' +
      '字幕 CDN *.oca.nflxvideo.net 回 ACAO:* 时带凭据请求会被 CORS 拒掉，整轨链路静默失败');
  }
});

test('BUG-1728 整轨抓取失败后去重标记回滚：同一 URL 在清单重放时可重试', async () => {
  const h = loadBridge({ failing: true });
  const manifestJs = 'JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')';
  vm.runInContext(manifestJs, h.ctx);
  await settle();
  assert.strictEqual(h.fetched.length, 3, '首轮 3 轨都尝试抓取');
  assert.strictEqual(h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues').length, 0,
    '抓取失败不得 post cue');

  // 网络恢复（如 CORS 失败只是暂时 CDN 抖动 / 切轨后重放同清单）：同 URL 必须能重试成功。
  h.behavior.failing = false;
  vm.runInContext(manifestJs, h.ctx);
  await settle();
  assert.strictEqual(h.fetched.length, 6,
    '失败后的清单重放必须重新发起抓取（旧代码去重标记写死在 fetch 前，一次失败=本页永不重试）');
  const cues = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues');
  assert.strictEqual(cues.length, 3, '重试成功后 3 轨全部送达隔离世界');
});

test('BUG-1728 失败的轨不进重放存档（replayCues 不得重放空/坏 payload）', async () => {
  const h = loadBridge({ failing: true });
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')', h.ctx);
  await settle();
  h.posted.length = 0;
  for (const fn of h.listeners) {
    fn({
      origin: 'https://www.netflix.com',
      source: h.windowObj,
      data: { __fushiNf: 'replayCues' },
    });
  }
  assert.strictEqual(h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cues').length, 0,
    '失败轨绝不能进 cueArchive 被重放');
});

// ── BUG-1949：现役 Netflix 清单不经主世界 JSON.parse → 清单钩子零命中；主数据源改为嗅探
// 播放器自下的字幕文件（XHR text / arraybuffer、fetch Response.text），语言取播放器 API 当前轨。──
test('BUG-1949 播放器 XHR(text) 下的 TTML 字幕文件被当整集轨投出（语言=当前轨 bcp47，videoId 取自路径）', () => {
  const h = loadBridge({ track: { bcp47: 'zh-Hans', displayName: '简体中文' } });
  const x = new h.FakeXhr();
  x.open('GET', CDN_URL);
  x.responseType = 'text';
  x.responseText = TTML_BODY;
  x.send();
  x.fire('load');
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1, '嗅探到的字幕文件必须 post 给隔离世界');
  assert.strictEqual(cues[0].msg.format, 'ttml');
  assert.strictEqual(cues[0].msg.lang, 'zh-Hans', '语言取播放器 getTimedTextTrack().bcp47');
  assert.strictEqual(cues[0].msg.videoId, '81001', 'videoId 取自 /watch/<id>');
  assert.strictEqual(cues[0].msg.text, TTML_BODY, '正文原样透传（解析在隔离世界）');
  assert.strictEqual(cues[0].origin, '/');
});

test('BUG-1949 XHR(arraybuffer) 分片只解码开头判格式：媒体分片不投、WebVTT 分片整份解码后投', () => {
  const h = loadBridge();
  const media = new h.FakeXhr();
  media.open('GET', 'https://ipv4-c092-hkg001-ix.1.oca.nflxvideo.net/range/0-999?o=2');
  media.responseType = 'arraybuffer';
  media.response = new Uint8Array(1024).buffer; // 全零 = 媒体分片
  media.send();
  media.fire('load');
  assert.strictEqual(cuesPosted(h).length, 0, '媒体分片不得被当字幕投出');

  const vtt = new h.FakeXhr();
  vtt.open('GET', CDN_URL);
  vtt.responseType = 'arraybuffer';
  vtt.response = new TextEncoder().encode(VTT_BODY).buffer;
  vtt.send();
  vtt.fire('load');
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].msg.format, 'webvtt');
  assert.strictEqual(cues[0].msg.lang, 'ja');
  assert.strictEqual(cues[0].msg.text, VTT_BODY);
});

test('BUG-1949 同一 URL+同长度正文只投一次；切轨（新 URL / 新语言）再投；replayCues 整批重放嗅探轨', async () => {
  const h = loadBridge();
  const send = (url, body) => {
    const x = new h.FakeXhr();
    x.open('GET', url);
    x.responseText = body;
    x.send();
    x.fire('load');
  };
  send(CDN_URL, TTML_BODY);
  send(CDN_URL, TTML_BODY);
  assert.strictEqual(cuesPosted(h).length, 1, '同一份下载（重试/重播）不得重复投');
  h.player.track = { bcp47: 'en' };
  send(CDN_URL + '&t=en', TTML_BODY.replace('こんにちは', 'hello'));
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 2);
  assert.deepStrictEqual(cues.map((p) => p.msg.lang), ['ja', 'en']);

  h.posted.length = 0;
  for (const fn of h.listeners) {
    fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'replayCues' } });
  }
  assert.deepStrictEqual(cuesPosted(h).map((p) => p.msg.lang), ['ja', 'en'],
    '晚注入的 content.js 请求重放时，嗅探轨必须和清单轨一样从存档整批重放');
});

test('BUG-1949 fetch 路径（Response.prototype.text）同样嗅探；非字幕正文不投；无播放器 API 时语言回落 und', async () => {
  const h = loadBridge({ withPlayer: false });
  const sub = new h.FakeResponse(CDN_URL, VTT_BODY);
  await vm.runInContext('(r) => r.text()', h.ctx)(sub);
  await settle();
  const json = new h.FakeResponse('https://www.netflix.com/api/x', '{"a":1}');
  await vm.runInContext('(r) => r.text()', h.ctx)(json);
  await settle();
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1, '只有像字幕的正文才投');
  assert.strictEqual(cues[0].msg.lang, 'und');
  assert.strictEqual(cues[0].msg.format, 'webvtt');
});

test('BUG-1949 清单路径抓到的轨不被 fetch 嗅探二次投递（同一 URL 同一正文只算一次）', async () => {
  const h = loadBridge();
  // 让 mock fetch 返回真 Response 实例，走被补丁的 Response.prototype.text。
  h.ctx.fetch = (url) => {
    h.fetched.push({ url, init: undefined });
    return Promise.resolve(Object.assign(new h.FakeResponse(url, VTT_BODY), { ok: true, status: 200 }));
  };
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(makeManifest())) + ')', h.ctx);
  await settle();
  await settle();
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 3, '3 轨各投一次，不得因嗅探而变 6');
  assert.deepStrictEqual(cues.map((p) => p.msg.lang).sort(), ['en', 'ja', 'zh-Hans'], '清单路径的语言标签优先');
});

// ── 2026-10 Netflix 站点书修复：正片会话选择 / seek 回执 / 轨身份 / 抓取失败回执 ──
function sendSeek(h, ms, id) {
  for (const fn of h.listeners) {
    fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'seek', ms, id } });
  }
  return h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'seekDone').map((p) => p.msg);
}

test('seek 只打到 watch 前缀的正片会话（预告会话排在后面也不选），回执带回 id', () => {
  const h = loadBridge();
  const done = sendSeek(h, 61000, 7);
  assert.deepStrictEqual(h.player.seeks, [61000], 'seek 必须落在正片播放器上');
  assert.strictEqual(done.length, 1);
  assert.strictEqual(done[0].ok, true);
  assert.strictEqual(done[0].id, 7, '回执原样回显 id（调用方只认最后一次 seek）');
});

test('没有正片会话时不退化成「随便最后一个」：seek 失败回执 ok:false', () => {
  const h = loadBridge({ sessionIds: ['motion-billboard-1'] });
  const done = sendSeek(h, 1000, 3);
  assert.strictEqual(done.length, 1);
  assert.strictEqual(done[0].ok, false);
  assert.strictEqual(done[0].id, 3);
  assert.match(done[0].err, /no watch player session/);
});

test('seek 4 s 没落地：回执 ok:false err:timeout（不再假装成功）', () => {
  let now = 0;
  class FakeDate { static now() { now += 500; return now; } }
  const h = loadBridge({ seekNeverLands: true, Date: FakeDate });
  const done = sendSeek(h, 90000, 9);
  assert.strictEqual(done.length, 1);
  assert.strictEqual(done[0].ok, false);
  assert.strictEqual(done[0].err, 'timeout');
  assert.strictEqual(done[0].id, 9);
});

test('window.fushiNetflixPlayer 暴露同一个正片会话判据（glue 共用）', () => {
  const h = loadBridge();
  assert.strictEqual(typeof h.windowObj.fushiNetflixPlayer, 'function');
  assert.strictEqual(h.windowObj.fushiNetflixPlayer().getTimedTextTrack().trackId, 'T:ja-1');
  const none = loadBridge({ sessionIds: ['motion-billboard-1'] });
  assert.strictEqual(none.windowObj.fushiNetflixPlayer(), null);
});

test('嗅探到的整轨带 trackId / 显示名（同语言普通与 CC 轨不再撞 key）', () => {
  const h = loadBridge({ track: { bcp47: 'en', trackId: 'T:en-cc', displayName: 'English [CC]' } });
  const x = new h.FakeXhr();
  x.open('GET', CDN_URL);
  x.responseText = VTT_BODY;
  x.send();
  x.fire('load');
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].msg.lang, 'en');
  assert.strictEqual(cues[0].msg.trackId, 'T:en-cc');
  assert.strictEqual(cues[0].msg.label, 'English [CC]');
});

test('fetch 路径的 Response.arrayBuffer 同样嗅探字幕正文', async () => {
  const h = loadBridge();
  const sub = new h.FakeResponse(CDN_URL + '&ab=1', VTT_BODY);
  await vm.runInContext('(r) => r.arrayBuffer()', h.ctx)(sub);
  await settle();
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1, 'arrayBuffer 取回的字幕必须被投出');
  assert.strictEqual(cues[0].msg.format, 'webvtt');
});

test('清单轨抓取失败投 cuesFailed（带语言与 trackId），消费端据此落成失败态', async () => {
  const h = loadBridge({ failing: true });
  const manifest = makeManifest();
  manifest.timedtexttracks[0].new_track_id = 'T:ja-1';
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify(manifest)) + ')', h.ctx);
  await settle();
  const failed = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cuesFailed').map((p) => p.msg);
  assert.strictEqual(failed.length, 3);
  const ja = failed.find((m) => m.lang === 'ja');
  assert.strictEqual(ja.trackId, 'T:ja-1');
  assert.strictEqual(ja.videoId, '81001');
});

// ── 播放器状态通道（清单钩子与正文嗅探都零命中时的主数据源，asbplayer 同判据） ──
const NF_TRACKS = [
  { trackId: 'T:off', isNoneTrack: true },
  { trackId: 'T:ja-cc', bcp47: 'ja', displayName: '日本語 [CC]', rawTrackType: 'CLOSEDCAPTIONS' },
  { trackId: 'T:en', bcp47: 'en', displayName: 'English' },
  { trackId: 'T:img', bcp47: 'zh', displayName: '中文', isImageBased: true },
  { trackId: 'T:forced', bcp47: 'ja', displayName: '日本語(強制)', isForcedNarrative: true },
];

test('状态通道：轨清单投成 tracks 占位（跳过关/图片/强制轨），状态里已有地址的轨直接整轨下载', async () => {
  const h = loadBridge({
    track: NF_TRACKS[1],
    textTracks: NF_TRACKS,
    stateUrls: { 'T:ja-cc': 'https://cdn/ja-cc.imsc' },
  });
  h.tick();
  await settle();
  const tracksMsgs = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'tracks').map((p) => p.msg);
  assert.strictEqual(tracksMsgs.length, 1);
  assert.strictEqual(tracksMsgs[0].videoId, '81001');
  assert.strictEqual(JSON.stringify(tracksMsgs[0].tracks.map((t) => t.trackId)), JSON.stringify(['T:ja-cc', 'T:en']));
  assert.strictEqual(h.fetched.length, 1);
  assert.strictEqual(h.fetched[0].url, 'https://cdn/ja-cc.imsc');
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].msg.lang, 'ja');
  assert.strictEqual(cues[0].msg.trackId, 'T:ja-cc');
  assert.strictEqual(cues[0].msg.label, '日本語 [CC]');
  // 再来一拍：清单没变不重复投 tracks，同一地址不重复下载。
  h.tick();
  await settle();
  assert.strictEqual(h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'tracks').length, 1);
  assert.strictEqual(h.fetched.length, 1);
  // replayCues 也重放轨清单（隔离世界晚就绪时不丢占位）。
  h.posted.length = 0;
  for (const fn of h.listeners) fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'replayCues' } });
  assert.strictEqual(h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'tracks').length, 1);
});

test('状态通道：fetchTrack 取无地址的轨 = 临时切过去等地址 → 切回原轨 → 整轨下载', async () => {
  const h = loadBridge({
    track: NF_TRACKS[1],
    textTracks: NF_TRACKS,
    stateUrls: {},
    urlOnSelect: { 'T:en': 'https://cdn/en.imsc' },
  });
  for (const fn of h.listeners) fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'fetchTrack', trackId: 'T:en' } });
  await drainMicrotasks();
  assert.strictEqual(JSON.stringify(h.player.setCalls), JSON.stringify(['T:en', 'T:ja-cc']), '切过去再切回原轨');
  assert.strictEqual(h.fetched.length, 1);
  assert.strictEqual(h.fetched[0].url, 'https://cdn/en.imsc');
  const cues = cuesPosted(h);
  assert.strictEqual(cues.length, 1);
  assert.strictEqual(cues[0].msg.trackId, 'T:en');
});

test('状态通道：地址始终不来 → 切回原轨并投 cuesFailed（不无限等）', async () => {
  const h = loadBridge({ track: NF_TRACKS[1], textTracks: NF_TRACKS, stateUrls: {} });
  for (const fn of h.listeners) fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'fetchTrack', trackId: 'T:en' } });
  await drainMicrotasks();
  assert.strictEqual(JSON.stringify(h.player.setCalls), JSON.stringify(['T:en', 'T:ja-cc']));
  const failed = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cuesFailed').map((p) => p.msg);
  assert.strictEqual(failed.length, 1);
  assert.strictEqual(failed[0].trackId, 'T:en');
  assert.strictEqual(h.fetched.length, 0);
});

test('状态通道：页面数据不可信——状态成环 / getter 抛错 / urls 形状不对 / 播放器 API 缺方法时降级为 cuesFailed，不抛出', async () => {
  const h = loadBridge({ track: NF_TRACKS[1], textTracks: NF_TRACKS, stateUrls: {} });
  const cyc = { type: 'timedtext', trackId: 'T:en', urls: 'not-an-array' };
  cyc.self = cyc;
  const evil = {};
  Object.defineProperty(evil, 'boom', { enumerable: true, get() { throw new Error('getter'); } });
  const brokenPlayer = {
    getTimedTextTrackList: () => NF_TRACKS,
    getTimedTextTrack: () => NF_TRACKS[1],
    // 网飞改版删了 setTimedTextTrack：临时切轨那步必然抛 TypeError。
  };
  h.windowObj.netflix = {
    appContext: { state: { playerApp: {
      getState: () => ({ videoPlayer: { cadmiumPlayerRepository: { playersById: { 'watch-81001': { cyc, evil, list: [cyc, null, 3] } } } } }),
      getAPI: () => ({ videoPlayer: {
        getAllPlayerSessionIds: () => ['watch-81001'],
        getVideoPlayerBySessionId: () => brokenPlayer,
      } }),
    } } },
  };
  assert.doesNotThrow(() => { for (let i = 0; i < 10; i++) h.tick(); });
  await settle();
  assert.strictEqual(h.fetched.length, 0, '形状不对的 urls 不当成下载地址');
  for (const fn of h.listeners) fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'fetchTrack', trackId: 'T:en' } });
  await drainMicrotasks();
  const failed = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cuesFailed').map((p) => p.msg);
  assert.strictEqual(failed.length, 1);
  assert.strictEqual(failed[0].trackId, 'T:en');
  // 整个网飞对象消失（未登录页 / 改版）：拍子与按需取轨都静默降级。
  delete h.windowObj.netflix;
  assert.doesNotThrow(() => h.tick());
  for (const fn of h.listeners) fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'fetchTrack', trackId: 'T:en' } });
  await drainMicrotasks();
  assert.strictEqual(h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cuesFailed').length, 2);
});

// ── 状态树节点预算（页面数据大小不由我们定：遍历分片、单次封顶） ──
function useState(h, root) {
  const api = h.windowObj.netflix.appContext.state.playerApp.getAPI;
  h.windowObj.netflix = { appContext: { state: { playerApp: {
    getState: () => ({ videoPlayer: { cadmiumPlayerRepository: { playersById: { 'watch-81001': root } } } }),
    getAPI: api,
  } } } };
}

test('状态通道：每拍只遍历一片（≤ 20000 节点），大状态分几拍走完、地址照样找到', async () => {
  const h = loadBridge({ track: NF_TRACKS[1], textTracks: NF_TRACKS, stateUrls: {} });
  let visits = 0;
  const wide = [];
  for (let i = 0; i < 50000; i++) {
    const n = {};
    Object.defineProperty(n, 'probe', { enumerable: true, get() { visits++; return 0; } });
    wide.push(n);
  }
  // LIFO：wide 后压栈、先出栈，timedtext 所在的 x 排在 5 万个节点之后。
  useState(h, { x: { y: { type: 'timedtext', trackId: 'T:ja-cc', urls: [{ url: 'https://cdn/ja-cc.imsc' }] } }, wide });
  h.tick();
  await settle();
  assert.ok(visits > 0 && visits <= 20000, '第一拍只走一片：' + visits);
  assert.strictEqual(h.fetched.length, 0, '一片走不到 5 万节点之后的地址');
  h.tick();
  h.tick();
  await settle();
  assert.strictEqual(visits, 50000, '三拍走完整棵树，每个节点只访问一次');
  assert.strictEqual(h.fetched.length, 1);
  assert.strictEqual(h.fetched[0].url, 'https://cdn/ja-cc.imsc');
});

test('状态通道：单次遍历超 1 000 000 节点即放弃并降级——只诊断一次，按需取轨不临时切轨、直接投 cuesFailed', async () => {
  const h = loadBridge({ track: NF_TRACKS[1], textTracks: NF_TRACKS, stateUrls: {} });
  const warns = [];
  h.ctx.console = { warn: (...a) => warns.push(a.join(' ')), log() {}, error() {} };
  const wide = new Array(1000005);
  for (let i = 0; i < wide.length; i++) wide[i] = {};
  useState(h, { x: { y: { type: 'timedtext', trackId: 'T:en', urls: [{ url: 'https://cdn/en.imsc' }] } }, wide });
  for (const fn of h.listeners) fn({ origin: 'https://www.netflix.com', source: h.windowObj, data: { __fushiNf: 'fetchTrack', trackId: 'T:en' } });
  await drainMicrotasks();
  assert.strictEqual(JSON.stringify(h.player.setCalls), '[]', '超预算不去切轨（切了也找不到地址）');
  assert.strictEqual(h.fetched.length, 0, '放弃的遍历不会摸到排在后面的地址');
  const failed = h.posted.filter((p) => p.msg && p.msg.__fushiNf === 'cuesFailed').map((p) => p.msg);
  assert.strictEqual(failed.length, 1);
  assert.strictEqual(failed[0].err, 'player state too large');
  assert.strictEqual(warns.filter((w) => w.includes('state channel degraded')).length, 1);
  // 拍子里的遍历同样封顶、不抛，诊断不重复打。
  assert.doesNotThrow(() => { for (let i = 0; i < 60; i++) h.tick(); });
  assert.strictEqual(h.fetched.length, 0);
  assert.strictEqual(warns.filter((w) => w.includes('state channel degraded')).length, 1);
});

test('轨身份三通道同源：清单条目 / 播放器当前轨 / 状态轨清单对同一条轨算出同一个 lang（bcp47 优先）', async () => {
  // language 与 bcp47 不同的轨：旧实现清单通道取 language、状态通道取 bcp47，同一条轨落两个 key。
  const track = { trackId: 'T:pt', bcp47: 'pt-BR', language: 'pt', displayName: 'Português (Brasil)' };
  const h = loadBridge({ track, textTracks: [track], stateUrls: {} });
  h.tick();
  const placeholder = h.posted.find((p) => p.msg && p.msg.__fushiNf === 'tracks').msg.tracks[0];
  vm.runInContext('JSON.parse(' + JSON.stringify(JSON.stringify({
    movieId: 81001,
    timedtexttracks: [{ new_track_id: 'T:pt', bcp47: 'pt-BR', language: 'pt', displayName: 'Português (Brasil)',
      ttDownloadables: { 'webvtt-lssdh-ios8': { urls: [{ url: 'https://cdn/pt.vtt' }] } } }],
  })) + ')', h.ctx);
  await settle();
  const manifestCue = cuesPosted(h).find((p) => p.msg.trackId === 'T:pt').msg;
  assert.strictEqual(placeholder.lang, 'pt-BR');
  assert.strictEqual(manifestCue.lang, placeholder.lang, '清单通道与状态通道同一个 lang');
  assert.strictEqual(manifestCue.trackId, placeholder.trackId);
  assert.strictEqual(manifestCue.label, placeholder.label);
  // 正文嗅探取的是播放器当前轨，同样经共用函数。
  const xhr = new h.FakeXhr();
  xhr.open('GET', CDN_URL);
  xhr.responseText = VTT_BODY;
  xhr.send();
  xhr.fire('load');
  await settle();
  const sniffed = cuesPosted(h).filter((p) => p.msg.text === VTT_BODY).map((p) => p.msg);
  assert.strictEqual(sniffed.length, 1);
  assert.strictEqual(sniffed[0].lang, 'pt-BR');
  assert.strictEqual(sniffed[0].trackId, 'T:pt');
});
