const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

// TODO-1363 行为守卫：content.js 的通用字幕轨 provider。
// 在受控 vm 里真加载 subtitle-adapters.js + content.js（manifest 同序），断言：
//   1) 接收端注册后立刻请求 replayCues（TODO-1219「勾选要刷新/列表空」的注入时序竞态修复）；
//   2) DOM 采样 live 轨：句子出现即入轨（勾选立刻有内容）、结束定格真实 end、倒退回看去重；
//   3) HTML5 video.textTracks 全量收割：原生字幕轨站点直接得到整集列表（含标签清洗与增量刷新）。

const ADAPTERS = path.join(__dirname, 'subtitle-adapters.js');
const CONTENT = path.join(__dirname, 'content.js');

function loadContent(opts) {
  const events = []; // 时序记录：listener 注册 / postMessage
  const intervals = []; // {fn, ms}
  const state = { subText: '' };
  const video = { currentTime: 0, paused: true, textTracks: opts.textTracks || [] };
  const windowObj = {
    addEventListener: (t) => events.push({ type: 'listener', t }),
    postMessage: (msg) => events.push({ type: 'post', msg }),
    innerWidth: 1200,
    innerHeight: 800,
  };
  const sandbox = {
    console: { log() {}, warn() {}, error() {} },
    setTimeout: () => 0,
    clearTimeout() {},
    setInterval: (fn, ms) => { intervals.push({ fn, ms }); return intervals.length; },
    clearInterval() {},
    URL,
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    location: {
      hostname: opts.hostname || 'example.com',
      href: 'https://' + (opts.hostname || 'example.com') + (opts.pathname || '/p') + (opts.search || ''),
      pathname: opts.pathname || '/p',
      origin: 'https://' + (opts.hostname || 'example.com'),
      search: opts.search || '',
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
      querySelectorAll: (sel) => {
        if (sel === '.player-timedtext' && state.subText) {
          return [{ textContent: state.subText }];
        }
        return [];
      },
      createElement: () => ({
        style: {},
        addEventListener() {},
        appendChild() {},
        setAttribute() {},
        remove() {},
        classList: { add() {} },
      }),
    },
    chrome: {
      runtime: {
        id: 'test-ext-id',
        lastError: null,
        onMessage: { addListener() {} },
        sendMessage() {},
      },
      storage: {
        local: { get: () => {}, set() {} },
        onChanged: { addListener() {} },
      },
    },
  };
  const ctx = vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(ADAPTERS, 'utf8'), ctx, { filename: 'subtitle-adapters.js' });
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), ctx, { filename: 'content.js' });
  const sampler = intervals.find((i) => i.ms === 200);
  const harvester = intervals.find((i) => i.ms === 1200);
  return { events, state, video, windowObj, sampler, harvester };
}

test('接收端注册后立刻请求 replayCues（先注册后请求，消除注入时序竞态）', () => {
  const h = loadContent({ hostname: 'www.netflix.com', pathname: '/watch/81001' });
  const listenerIdx = h.events.findIndex((e) => e.type === 'listener' && e.t === 'message');
  const replayIdx = h.events.findIndex(
    (e) => e.type === 'post' && e.msg && e.msg.__hibikiNf === 'replayCues');
  assert.ok(listenerIdx >= 0, '必须注册 message 接收端');
  assert.ok(replayIdx >= 0, '必须发出 replayCues 请求');
  assert.ok(replayIdx > listenerIdx, 'replayCues 必须在接收端注册之后（否则重放也会丢）');
});

test('live 轨：句子出现即入轨、结束定格 end、倒退回看去重（通用站点）', () => {
  const h = loadContent({ hostname: 'example.com', pathname: '/p' });
  assert.ok(h.sampler, '缺 200ms 采样器');
  const notified = [];
  h.windowObj.hibikiSubtitlePanelOnCues = (key) => notified.push(key);

  // 句子出现（t=1.0s）：立刻入轨（暂定 end）——勾选开关此刻就有内容可显示。
  h.video.currentTime = 1.0;
  h.state.subText = 'konnichiwa';
  h.sampler.fn();
  const key = 'example.com/p|live';
  const store = h.windowObj.hibikiEpisodeCues;
  assert.ok(store, 'content.js 必须暴露 hibikiEpisodeCues');
  assert.strictEqual(store[key].length, 1, '句子出现即入 live 轨');
  assert.strictEqual(store[key][0].startMs, 1000);
  assert.strictEqual(store[key][0].text, 'konnichiwa');
  assert.deepStrictEqual(notified, [key], '新句必须通知面板');

  // 同句持续显示：不重复入轨。
  h.video.currentTime = 1.5;
  h.sampler.fn();
  assert.strictEqual(store[key].length, 1);

  // 句子结束（t=3.0s 字幕清空）：定格真实 end。
  h.video.currentTime = 3.0;
  h.state.subText = '';
  h.sampler.fn();
  assert.strictEqual(store[key][0].endMs, 3000, '句子结束必须定格真实 end');

  // 倒退回看同一句（seek 回 t=0.9s）：同文本句首相近 → 去重不重复入轨。
  h.video.currentTime = 0.9;
  h.state.subText = 'konnichiwa';
  h.sampler.fn();
  assert.strictEqual(store[key].length, 1, '倒退回看不得重复入轨');

  // 新句（t=5s）：有序追加。
  h.video.currentTime = 5.0;
  h.state.subText = 'sayounara';
  h.sampler.fn();
  assert.strictEqual(store[key].length, 2);
  assert.strictEqual(store[key][1].startMs, 5000);
});

test('live 轨：YouTube 同一句逐字扩长时就地更新，不把每个快照追加成重复行', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=rolling' });
  const notified = [];
  h.windowObj.hibikiSubtitlePanelOnCues = (key) => notified.push(key);
  const key = 'yt-rolling|live';

  h.video.currentTime = 25.0;
  h.state.subText = '自価総額およそ';
  h.sampler.fn();

  h.video.currentTime = 25.2;
  h.state.subText = '自価総額およそ800';
  h.sampler.fn();
  h.video.currentTime = 25.4;
  h.state.subText = '自価総額およそ800兆円。';
  h.sampler.fn();
  h.video.currentTime = 25.6;
  h.state.subText = '自価総額およそ800兆円。NIAはAIブーム';
  h.sampler.fn();

  const track = h.windowObj.hibikiEpisodeCues[key];
  assert.strictEqual(track.length, 1, '同一句的逐字扩长快照必须合并到一行');
  assert.strictEqual(track[0].startMs, 25000, '就地更新不得改变原句起点');
  assert.strictEqual(track[0].text, '自価総額およそ800兆円。NIAはAIブーム');
  assert.ok(track[0].endMs > 25600, '仍在显示时暂定 end 必须随快照延长');
  assert.strictEqual(notified.length, 4, '每次就地更新仍需通知面板刷新现有行');

  h.video.currentTime = 25.8;
  h.state.subText = '次の文';
  h.sampler.fn();
  assert.strictEqual(track.length, 2, '真正换句仍应新增一行');
  assert.strictEqual(track[0].endMs, 25800, '换句时上一句必须定格真实 end');
  assert.strictEqual(track[1].text, '次の文');
});

test('textTracks 收割：原生字幕轨整轨读出（清洗标签）并增量刷新', () => {
  const cues = [
    { startTime: 1, endTime: 2, text: 'Hello <i>world</i>' },
    { startTime: 3, endTime: 4.5, text: 'Second line' },
  ];
  const h = loadContent({
    hostname: 'example.com',
    pathname: '/p',
    textTracks: [
      { kind: 'subtitles', mode: 'showing', language: 'en', cues },
      { kind: 'metadata', mode: 'showing', language: 'md', cues },
      { kind: 'subtitles', mode: 'disabled', language: 'fr', cues },
    ],
  });
  assert.ok(h.harvester, '缺 1200ms textTracks 收割器');
  const notified = [];
  h.windowObj.hibikiSubtitlePanelOnCues = (key) => notified.push(key);
  h.harvester.fn();
  const store = h.windowObj.hibikiEpisodeCues;
  const key = 'example.com/p|en';
  assert.ok(store[key], '原生字幕轨必须进 store');
  assert.strictEqual(store[key].length, 2);
  assert.strictEqual(store[key][0].startMs, 1000);
  assert.strictEqual(store[key][0].endMs, 2000);
  assert.strictEqual(store[key][0].text, 'Hello world', '行内标签必须清洗');
  assert.strictEqual(store[key][1].endMs, 4500);
  assert.strictEqual(store['example.com/p|md'], undefined, 'metadata 轨不收');
  assert.strictEqual(store['example.com/p|fr'], undefined, 'disabled 轨不收（cues 未加载）');
  assert.deepStrictEqual(notified, [key]);

  // 流媒体渐进加载：cue 变多 → 整轨刷新；没变 → 不重复通知。
  h.harvester.fn();
  assert.deepStrictEqual(notified, [key], '无增量不得重复通知面板');
  cues.push({ startTime: 6, endTime: 7, text: 'Third' });
  h.harvester.fn();
  assert.strictEqual(store[key].length, 3, 'cue 增多必须增量刷新');
  assert.deepStrictEqual(notified, [key, key]);
});

test('videoKey 契约：netflix=watch id、youtube=yt-<v>、其它=host+path', () => {
  const nf = loadContent({ hostname: 'www.netflix.com', pathname: '/watch/81001' });
  assert.strictEqual(nf.windowObj.hibikiVideoKey(), '81001');
  const yt = loadContent({
    hostname: 'www.youtube.com',
    pathname: '/watch',
    search: '?v=abc123',
  });
  // hibikiYoutubeId 从 location.href 解析 v 参数。
  assert.strictEqual(yt.windowObj.hibikiVideoKey(), 'yt-abc123');
  const generic = loadContent({ hostname: 'example.com', pathname: '/show/1' });
  assert.strictEqual(generic.windowObj.hibikiVideoKey(), 'example.com/show/1');
});
