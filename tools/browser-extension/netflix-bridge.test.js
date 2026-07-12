const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1219 复诉根因守卫：主世界 netflix-bridge.js document_start 抓字幕并 postMessage，隔离世界
// content.js document_idle 才注册接收端——先于接收端发出的 cue 消息永久丢失，store 空 → 勾选面板
// 开关无物可挂（用户「必须刷新页面才加载出来」）、只剩预取下一集轨（「面板出现但列表空」）。
// 修复契约：bridge 存档所有已抓 cue payload，收到 {__hibikiNf:'replayCues'} 时整批重放。
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
  const windowObj = {
    location: { origin: locationOrigin },
    origin: windowOrigin,
    postMessage: (msg, origin) => posted.push({ msg, origin }),
    addEventListener: (t, fn) => { if (t === 'message') listeners.push(fn); },
  };
  const sandbox = {
    window: windowObj,
    setTimeout: (fn) => { fn(); return 0; },
    fetch: (url) => {
      fetched.push(url);
      return Promise.resolve({
        text: () => Promise.resolve('WEBVTT\n\n00:01.000 --> 00:02.000\nhello from ' + url),
      });
    },
    Date,
    Array,
    Object,
    Error,
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(src, ctx, { filename: 'netflix-bridge.js' });
  return { posted, listeners, fetched, ctx, windowObj };
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
  const first = h.posted.filter((p) => p.msg && p.msg.__hibikiNf === 'cues');
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
      data: { __hibikiNf: 'replayCues' },
    });
  }
  const replayed = h.posted.filter((p) => p.msg && p.msg.__hibikiNf === 'cues');
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
    fn({ origin: 'https://evil.example', source: h.windowObj, data: { __hibikiNf: 'replayCues' } });
    fn({ origin: 'https://www.netflix.com', source: {}, data: { __hibikiNf: 'replayCues' } });
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
  const cues = h.posted.filter((p) => p.msg && p.msg.__hibikiNf === 'cues');
  assert.strictEqual(cues.length, 3, 'file:// 下仍抓全 3 轨');
  // targetOrigin 必须是 "/"（= 仅同源同窗投递，对不透明源成立）；绝不能是 location.origin/'file://'。
  for (const p of cues) {
    assert.strictEqual(p.origin, '/', 'file:// 自投必须用 "/" 作 targetOrigin');
  }

  // content.js 晚注入后请求重放：e.origin 为不透明源序列化 'null'，接收端须认可（ORIGIN=window.origin='null'）。
  h.posted.length = 0;
  for (const fn of h.listeners) {
    fn({ origin: 'null', source: h.windowObj, data: { __hibikiNf: 'replayCues' } });
  }
  const replayed = h.posted.filter((p) => p.msg && p.msg.__hibikiNf === 'cues');
  assert.strictEqual(replayed.length, 3, 'file:// opaque origin 的 replayCues 必须被接收端认可并整批重放');
  for (const p of replayed) {
    assert.strictEqual(p.origin, '/', '重放同样用 "/" 作 targetOrigin');
  }
});
