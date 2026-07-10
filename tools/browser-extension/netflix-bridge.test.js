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

function loadBridge() {
  const src = fs.readFileSync(BRIDGE, 'utf8');
  const posted = [];
  const listeners = [];
  const fetched = [];
  const windowObj = {
    location: { origin: 'https://www.netflix.com' },
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
