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
const CONTENT = process.env.FUSHI_CONTENT_UNDER_TEST ||
  path.join(__dirname, 'content.js');

// BUG-1718：真实运行时（manifest content_scripts / side-panel.html）里 vendor/dict-media.js
// 恒在 content.js / side-panel.js 之前加载，后者依赖它导出的 applyFushiPopupCss 与
// installDictMediaPlaceholderResolver。测试沙箱必须照同样顺序装，否则跑的是一个真实
// 世界里不存在的、缺半个脚本集的环境。
const FUSHI_DICT_MEDIA = path.join(__dirname, 'vendor', 'dict-media.js');
function loadFushiDictMedia(ctx) {
  vm.runInContext(fs.readFileSync(FUSHI_DICT_MEDIA, 'utf8'), ctx,
    { filename: 'vendor/dict-media.js' });
}

function loadContent(opts) {
  const events = []; // 时序记录：listener 注册 / postMessage
  const intervals = []; // {fn, ms}
  const state = { subText: '', videoPresent: true, video: null };
  function createVideo(currentTime, textTracks) {
    const listeners = Object.create(null);
    return {
      currentTime: currentTime || 0,
      paused: true,
      seeking: false,
      textTracks: textTracks || [],
      addEventListener(type, listener) {
        (listeners[type] || (listeners[type] = new Set())).add(listener);
      },
      removeEventListener(type, listener) {
        if (listeners[type]) listeners[type].delete(listener);
      },
      emit(type) {
        for (const listener of listeners[type] || []) listener.call(this);
      },
    };
  }
  const video = createVideo(0, opts.textTracks);
  state.video = video;
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
      querySelector: (sel) => (
        sel === 'video' && state.videoPresent ? state.video : null
      ),
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
  loadFushiDictMedia(ctx);
  vm.runInContext(fs.readFileSync(CONTENT, 'utf8'), ctx, { filename: 'content.js' });
  const sampler = intervals.find((i) => i.ms === 200);
  const harvester = intervals.find((i) => i.ms === 1200);
  return {
    events,
    state,
    video,
    windowObj,
    location: sandbox.location,
    sampler,
    harvester,
    seekTo(seconds) {
      state.video.seeking = true;
      state.video.emit('seeking');
      state.video.currentTime = seconds;
      state.video.seeking = false;
      state.video.emit('seeked');
    },
    remountVideo(seconds) {
      state.video = createVideo(seconds, state.video.textTracks);
      state.videoPresent = true;
      return state.video;
    },
    destroyVideo() {
      state.videoPresent = false;
    },
  };
}

test('接收端注册后立刻请求 replayCues（先注册后请求，消除注入时序竞态）', () => {
  const h = loadContent({ hostname: 'www.netflix.com', pathname: '/watch/81001' });
  const listenerIdx = h.events.findIndex((e) => e.type === 'listener' && e.t === 'message');
  const replayIdx = h.events.findIndex(
    (e) => e.type === 'post' && e.msg && e.msg.__fushiNf === 'replayCues');
  assert.ok(listenerIdx >= 0, '必须注册 message 接收端');
  assert.ok(replayIdx >= 0, '必须发出 replayCues 请求');
  assert.ok(replayIdx > listenerIdx, 'replayCues 必须在接收端注册之后（否则重放也会丢）');
});

test('live 轨：句子出现即入轨、结束定格 end、倒退回看去重（通用站点）', () => {
  const h = loadContent({ hostname: 'example.com', pathname: '/p' });
  assert.ok(h.sampler, '缺 200ms 采样器');
  const notified = [];
  h.windowObj.fushiSubtitlePanelOnCues = (key) => notified.push(key);

  // 句子出现（t=1.0s）：立刻入轨（暂定 end）——勾选开关此刻就有内容可显示。
  h.video.currentTime = 1.0;
  h.state.subText = 'konnichiwa';
  h.sampler.fn();
  const key = 'example.com/p|live';
  const store = h.windowObj.fushiEpisodeCues;
  assert.ok(store, 'content.js 必须暴露 fushiEpisodeCues');
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
  h.windowObj.fushiSubtitlePanelOnCues = (key) => notified.push(key);
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

  const track = h.windowObj.fushiEpisodeCues[key];
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

test('BUG-1270：YouTube 累积 DOM 分段，回跳同一时间不再插入短快照', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=seek-back' });
  const key = 'yt-seek-back|live';

  const growingParts = [
    '工場です。', 'パイプ', 'ラインです。', 'その中に', '赤と', '白の', '煙突が',
    '見えます。', 'その', '先端', '部分に', '向かって', '折れて', 'いく',
  ];
  let cumulative = '';
  for (let i = 0; i < growingParts.length; i++) {
    cumulative += growingParts[i];
    h.video.currentTime = 193.0 + i;
    h.state.subText = cumulative;
    h.sampler.fn();
  }

  const track = h.windowObj.fushiEpisodeCues[key];
  assert.strictEqual(track.length, 2, '累积 DOM 必须按时间切成有界 cue');
  assert.strictEqual(track[0].startMs, 193000);
  assert.strictEqual(track[0].endMs, 205000);
  assert.strictEqual(track[0].text, growingParts.slice(0, 12).join(''));
  assert.strictEqual(track[1].startMs, 205000);
  assert.strictEqual(track[1].text, '折れていく');

  // 从 3:29 回跳到 3:13：YouTube 先给旧 cue 的短前缀，再继续逐字扩长。
  // 两次采样都只能进入 replay 状态，不能生成截图中第二条 3:13。
  h.seekTo(193.0);
  h.state.subText = '工場です。';
  h.sampler.fn();
  h.video.currentTime = 193.2;
  h.state.subText = '工場です。パイプラインです。';
  h.sampler.fn();
  assert.strictEqual(track.length, 2, '回跳旧区间不得插入同时间短快照');
  assert.strictEqual(track.filter((c) => c.startMs === 193000).length, 1);
});

test('短采样停顿：1.6 秒正向增长不是 seek，新增后缀不丢', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=pause' });
  h.video.currentTime = 10;
  h.state.subText = 'A';
  h.sampler.fn();
  h.video.currentTime = 11.6;
  h.state.subText = 'AB';
  h.sampler.fn();
  const track = h.windowObj.fushiEpisodeCues['yt-pause|live'];
  assert.strictEqual(track.length, 1);
  assert.strictEqual(track[0].text, 'AB');
});

test('非前缀更正与缩短各自成句，不回写上一 cue', () => {
  const correction = loadContent({
    hostname: 'www.youtube.com',
    pathname: '/watch',
    search: '?v=correction',
  });
  correction.video.currentTime = 20;
  correction.state.subText = 'alpha';
  correction.sampler.fn();
  correction.video.currentTime = 20.2;
  correction.state.subText = 'alpX';
  correction.sampler.fn();
  assert.strictEqual(
    correction.windowObj.fushiEpisodeCues['yt-correction|live']
      .map((cue) => cue.text)
      .join('|'),
    'alpha|alpX',
  );

  const shortening = loadContent({
    hostname: 'www.youtube.com',
    pathname: '/watch',
    search: '?v=shortening',
  });
  shortening.video.currentTime = 30;
  shortening.state.subText = 'abcdef';
  shortening.sampler.fn();
  shortening.video.currentTime = 30.2;
  shortening.state.subText = 'abc';
  shortening.sampler.fn();
  assert.strictEqual(
    shortening.windowObj.fushiEpisodeCues['yt-shortening|live']
      .map((cue) => cue.text)
      .join('|'),
    'abcdef|abc',
  );
});

test('SPA 换视频：同文也建新轨，前缀增长不得污染旧视频 cue', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=one' });
  h.video.currentTime = 10;
  h.state.subText = 'same';
  h.sampler.fn();

  h.location.search = '?v=two';
  h.location.href = 'https://www.youtube.com/watch?v=two';
  h.state.subText = 'same';
  h.sampler.fn();
  h.video.currentTime = 10.2;
  h.state.subText = 'same-new';
  h.sampler.fn();

  const store = h.windowObj.fushiEpisodeCues;
  assert.strictEqual(store['yt-one|live'][0].text, 'same');
  assert.strictEqual(store['yt-two|live'].length, 1);
  assert.strictEqual(store['yt-two|live'][0].text, 'same-new');
});

test('SPA A→B→A：回访已有轨的短前缀只读 replay，不追加重复 cue', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=A' });
  h.video.currentTime = 10;
  h.state.subText = 'line-full';
  h.sampler.fn();

  h.location.search = '?v=B';
  h.location.href = 'https://www.youtube.com/watch?v=B';
  h.state.subText = 'other';
  h.sampler.fn();

  h.location.search = '?v=A';
  h.location.href = 'https://www.youtube.com/watch?v=A';
  h.state.subText = 'line';
  h.sampler.fn();
  h.state.video.currentTime = 10.2;
  h.state.subText = 'line-full';
  h.sampler.fn();

  const track = h.windowObj.fushiEpisodeCues['yt-A|live'];
  assert.strictEqual(track.length, 1);
  assert.strictEqual(track.map((cue) => cue.text).join('|'), 'line-full');
});

test('SPA A→B→A：回访已有短轨的长前缀快照也只读 replay', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=A-long' });
  h.video.currentTime = 10;
  h.state.subText = 'line';
  h.sampler.fn();

  h.location.search = '?v=B-long';
  h.location.href = 'https://www.youtube.com/watch?v=B-long';
  h.state.subText = 'other';
  h.sampler.fn();

  h.location.search = '?v=A-long';
  h.location.href = 'https://www.youtube.com/watch?v=A-long';
  h.state.subText = 'line-full';
  h.sampler.fn();

  const track = h.windowObj.fushiEpisodeCues['yt-A-long|live'];
  assert.strictEqual(track.length, 1);
  assert.strictEqual(track.map((cue) => cue.text).join('|'), 'line');
});

test('player 销毁：定格当前代且不凭空插入 t=0 cue', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=gone' });
  h.video.currentTime = 10;
  h.state.subText = 'line-full';
  h.sampler.fn();
  h.destroyVideo();
  h.sampler.fn();
  const track = h.windowObj.fushiEpisodeCues['yt-gone|live'];
  assert.strictEqual(track.length, 1);
  assert.strictEqual(track.filter((cue) => cue.startMs === 0).length, 0);

  // 同 key 播放器稍后重建：短前缀与后续增长仍是旧窗 replay，不造第二条。
  h.remountVideo(10);
  h.state.subText = 'line';
  h.sampler.fn();
  h.state.video.currentTime = 10.2;
  h.state.subText = 'line-full';
  h.sampler.fn();
  assert.strictEqual(track.length, 1);
  assert.strictEqual(track[0].text, 'line-full');
});

test('同视频 remount：旧代引用清空、旧轨稳定，离开 replay 后恢复新增', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=remount' });
  h.video.currentTime = 10;
  h.state.subText = 'same';
  h.sampler.fn();
  const track = h.windowObj.fushiEpisodeCues['yt-remount|live'];

  h.remountVideo(10);
  h.sampler.fn();
  h.state.video.currentTime = 10.2;
  h.state.subText = 'same-new';
  h.sampler.fn();
  assert.strictEqual(track.length, 1, 'remount 的同窗快照只能只读 replay');
  assert.strictEqual(track[0].text, 'same', '新代不得持有并改写旧代 liveCue 引用');

  h.state.video.currentTime = 12;
  h.state.subText = 'fresh';
  h.sampler.fn();
  assert.strictEqual(track.length, 2, '离开 replay 后正常字幕必须恢复写轨');
  assert.strictEqual(track[1].text, 'fresh');
});

test('真实 seeking/seeked：seek 前定格，多次前后跳不重复旧轨', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=multi-seek' });
  h.video.currentTime = 10;
  h.state.subText = 'A';
  h.sampler.fn();
  h.video.currentTime = 11;
  h.sampler.fn();
  h.seekTo(20);
  h.state.subText = 'B';
  h.sampler.fn();
  h.video.currentTime = 21;
  h.state.subText = '';
  h.sampler.fn();
  h.seekTo(10);
  h.state.subText = 'A';
  h.sampler.fn();
  h.seekTo(20);
  h.state.subText = 'B';
  h.sampler.fn();

  const track = h.windowObj.fushiEpisodeCues['yt-multi-seek|live'];
  assert.strictEqual(track.find((cue) => cue.text === 'A').endMs, 11000);
  assert.strictEqual(track.filter((cue) => cue.text === 'A').length, 1);
  assert.strictEqual(track.filter((cue) => cue.text === 'B').length, 1);
});

test('只观察到 seeked 时仍按末次真实采样定格旧 cue', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=seeked-only' });
  h.video.currentTime = 10;
  h.state.subText = 'A';
  h.sampler.fn();
  h.video.currentTime = 11;
  h.sampler.fn();

  // 模拟 content script 绑定较晚/站点封装只让隔离世界观察到 seeked。
  h.video.currentTime = 20;
  h.video.emit('seeked');
  h.state.subText = 'B';
  h.sampler.fn();

  const track = h.windowObj.fushiEpisodeCues['yt-seeked-only|live'];
  assert.strictEqual(track.find((cue) => cue.text === 'A').endMs, 11000);
  assert.strictEqual(track.find((cue) => cue.text === 'B').startMs, 20000);
});

test('seek 后空白帧不消费 replay 门，短前缀稍后到达仍不重复', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=blank-seek' });
  h.video.currentTime = 1;
  h.state.subText = 'AB';
  h.sampler.fn();
  h.video.currentTime = 2;
  h.state.subText = '';
  h.sampler.fn();

  h.seekTo(1);
  h.sampler.fn();
  h.state.subText = 'A';
  h.sampler.fn();

  const track = h.windowObj.fushiEpisodeCues['yt-blank-seek|live'];
  assert.strictEqual(track.length, 1);
  assert.strictEqual(track[0].text, 'AB');
});

test('replay 窗口与文本关系保持窄匹配，窗外/仅子串相似均不得抑制', () => {
  const h = loadContent({ hostname: 'www.youtube.com', pathname: '/watch', search: '?v=boundary' });
  h.video.currentTime = 1;
  h.state.subText = 'xxsameyy';
  h.sampler.fn();
  h.video.currentTime = 2;
  h.state.subText = '';
  h.sampler.fn();

  h.seekTo(1);
  h.state.subText = 'same';
  h.sampler.fn();
  h.seekTo(10);
  h.state.subText = 'xxsameyy';
  h.sampler.fn();

  const track = h.windowObj.fushiEpisodeCues['yt-boundary|live'];
  assert.strictEqual(track.filter((cue) => cue.startMs === 1000).length, 2,
    '仅子串相似不是前缀相关，不能误判 replay');
  assert.strictEqual(track.filter((cue) => cue.startMs === 10000).length, 1,
    '同文但落在旧 cue 窗外必须作为新句');
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
    ],
  });
  assert.ok(h.harvester, '缺 1200ms textTracks 收割器');
  const notified = [];
  h.windowObj.fushiSubtitlePanelOnCues = (key) => notified.push(key);
  h.harvester.fn();
  const store = h.windowObj.fushiEpisodeCues;
  const key = 'example.com/p|en';
  assert.ok(store[key], '原生字幕轨必须进 store');
  assert.strictEqual(store[key].length, 2);
  assert.strictEqual(store[key][0].startMs, 1000);
  assert.strictEqual(store[key][0].endMs, 2000);
  assert.strictEqual(store[key][0].text, 'Hello world', '行内标签必须清洗');
  assert.strictEqual(store[key][1].endMs, 4500);
  assert.strictEqual(store['example.com/p|md'], undefined, 'metadata 轨不收');
  assert.deepStrictEqual(notified, [key]);

  // 流媒体渐进加载：cue 变多 → 归并入轨；没变 → 不重复通知。
  h.harvester.fn();
  assert.deepStrictEqual(notified, [key], '无增量不得重复通知面板');
  cues.push({ startTime: 6, endTime: 7, text: 'Third' });
  h.harvester.fn();
  assert.strictEqual(store[key].length, 3, 'cue 增多必须增量刷新');
  assert.deepStrictEqual(notified, [key, key]);
});

test('textTracks 收割：disabled 语言轨强制升 hidden，下一轮收齐全部语言轨', () => {
  // 浏览器对 disabled 轨不加载 cues → 以前直接跳过 = 侧边栏语言轨永远只有播放器当前开着
  // 的那条。现在收割器把 disabled 升为 hidden（加载 cues 但不渲染），下一轮即可收割。
  const enCues = [{ startTime: 1, endTime: 2, text: 'Hello' }];
  const frTrack = { kind: 'subtitles', mode: 'disabled', language: 'fr', cues: null };
  const h = loadContent({
    hostname: 'example.com',
    pathname: '/p',
    textTracks: [
      { kind: 'subtitles', mode: 'showing', language: 'en', cues: enCues },
      frTrack,
    ],
  });
  const store = h.windowObj.fushiEpisodeCues;
  h.harvester.fn();
  assert.strictEqual(frTrack.mode, 'hidden', 'disabled 字幕轨必须被升为 hidden 以触发 cue 加载');
  assert.strictEqual(store['example.com/p|fr'], undefined, '升 hidden 当轮 cues 未就绪，先不入 store');
  // 模拟浏览器在下一轮轮询前加载完 hidden 轨的 cues。
  frTrack.cues = [{ startTime: 1, endTime: 2, text: 'Bonjour' }];
  h.harvester.fn();
  assert.ok(store['example.com/p|fr'], 'hidden 轨 cues 就绪后必须进 store');
  assert.strictEqual(store['example.com/p|fr'][0].text, 'Bonjour');
  assert.strictEqual(store['example.com/p|en'].length, 1, 'en 轨不受影响');
  // 站点播放器（hls.js 等）把 mode 拨回 disabled = 它在管理轨道：同一轨只升一次，
  // 不得形成 1.2s 轮询的无限翻转拉锯。
  frTrack.mode = 'disabled';
  h.harvester.fn();
  assert.strictEqual(frTrack.mode, 'disabled', '同一轨只尝试升 hidden 一次，站点拨回后尊重站点');
});

test('textTracks 收割：同语言多轨（English 与 English [CC]）分 key，不得穿插归并', () => {
  const h = loadContent({
    hostname: 'example.com',
    pathname: '/p',
    textTracks: [
      {
        kind: 'subtitles', mode: 'showing', language: 'en', label: 'English',
        cues: [{ startTime: 1, endTime: 2, text: 'Hello' }],
      },
      {
        kind: 'captions', mode: 'hidden', language: 'en', label: 'English [CC]',
        cues: [{ startTime: 1, endTime: 2, text: '[door slams] Hello' }],
      },
    ],
  });
  const store = h.windowObj.fushiEpisodeCues;
  h.harvester.fn();
  const keys = Object.keys(store).filter((k) => k.startsWith('example.com/p|'));
  assert.strictEqual(keys.length, 2, '同语言两条轨必须落成两个独立 key');
  for (const k of keys) {
    assert.strictEqual(store[k].length, 1, '每条轨只含自己的 cue，不得互相穿插');
  }
});

test('textTracks 收割：分片字幕整批替换按归并合并，旧区间不丢、新区间进得来', () => {
  // hls.js/Shaka 会随 back-buffer 回收/seek 把 tt.cues 整批换成另一时间窗（条数可能不变或
  // 变少）。旧实现「条数没长就跳过、长了整轨覆盖」两个方向都丢字幕；归并后轨只增不减。
  const track = {
    kind: 'subtitles', mode: 'showing', language: 'en',
    cues: [
      { startTime: 1, endTime: 2, text: 'One' },
      { startTime: 3, endTime: 4, text: 'Two' },
    ],
  };
  const h = loadContent({ hostname: 'example.com', pathname: '/p', textTracks: [track] });
  const store = h.windowObj.fushiEpisodeCues;
  const key = 'example.com/p|en';
  h.harvester.fn();
  assert.strictEqual(store[key].length, 2);
  // seek 后整批换窗：条数没变多（旧实现在这里整段跳过 → 新区间永远进不来）。
  track.cues = [{ startTime: 100, endTime: 101, text: 'Later' }];
  h.harvester.fn();
  assert.strictEqual(store[key].length, 3, '换窗后的新 cue 必须并入');
  assert.ok(store[key].some((c) => c.text === 'One'), '旧区间 cue 不得被整轨覆盖抹掉');
  assert.ok(store[key].some((c) => c.text === 'Later'), '新区间 cue 必须进 store');
  // 回看已收割区间：同 cue 重复收割去重，不得翻倍。
  track.cues = [
    { startTime: 1, endTime: 2, text: 'One' },
    { startTime: 3, endTime: 4, text: 'Two' },
  ];
  h.harvester.fn();
  assert.strictEqual(store[key].length, 3, '重复收割必须去重');
});

test('videoKey 契约：netflix=watch id、youtube=yt-<v>、其它=host+path', () => {
  const nf = loadContent({ hostname: 'www.netflix.com', pathname: '/watch/81001' });
  assert.strictEqual(nf.windowObj.fushiVideoKey(), '81001');
  const yt = loadContent({
    hostname: 'www.youtube.com',
    pathname: '/watch',
    search: '?v=abc123',
  });
  // fushiYoutubeId 从 location.href 解析 v 参数。
  assert.strictEqual(yt.windowObj.fushiVideoKey(), 'yt-abc123');
  const generic = loadContent({ hostname: 'example.com', pathname: '/show/1' });
  assert.strictEqual(generic.windowObj.fushiVideoKey(), 'example.com/show/1');
});
