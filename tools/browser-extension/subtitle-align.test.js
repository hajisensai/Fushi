// 网页视频自动对轴 / 波形对轴（反馈 0wkJImhZUp）。
//  ① 纯函数：采样块按 20ms 切片并落到媒体时间；细格 → 100ms 粗格（平方和合并、空洞 = null）；
//     请求体只带窗口内的 cue；服务端回应 → 「当前偏移 + 再平移量」；静音判定。
//  ② content 编排：声音不够先听、攒够自动算并写偏移；换视频后迟到的结果丢弃；跨源视频如实报错；
//     侧边栏状态（续租约 + 细格波形）。
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SRC = fs.readFileSync(path.join(__dirname, 'subtitle-align.js'), 'utf8');

function loadPure() {
  const sandbox = { console, Map, Math };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox, { filename: 'subtitle-align.js' });
  return sandbox.fushiSubtitleAlign;
}

// ───────── ① 纯函数 ─────────

test('栅格常量与 app 同一口径：自动对轴 100ms、波形 20ms；开算门槛不低于服务端最小样本量 20 秒', () => {
  const A = loadPure();
  assert.strictEqual(A.BIN_MS, 100);
  assert.strictEqual(A.FINE_MS, 20);
  assert.ok(A.AUTO_MIN_CAPTURED_MS >= 20000);
  assert.ok(A.MAX_WINDOW_MS / A.BIN_MS <= 12000, '窗口不超过服务端 kCaptureAlignMaxBins');
});

test('splitBlock：一块 2048 样本 @48k 切成 20ms 片，时间戳是片中点的媒体时间；倍速按媒体时间折算', () => {
  const A = loadPure();
  const data = new Float32Array(2048).fill(0.5);
  const chunks = A.splitBlock([data], 48000, 10000, 1);
  assert.deepStrictEqual(Array.from(chunks, (c) => c.n), [960, 960, 128]);
  assert.ok(Math.abs(chunks[0].sumSq - 0.25 * 960) < 1e-6);
  const start = 10000 - 2048 / 48;
  assert.ok(Math.abs(chunks[0].mediaMs - (start + 10)) < 1e-6);
  // 2 倍速：同样 2048 个样本覆盖 2 倍的媒体时间，切片按媒体 20ms 走（样本数减半）。
  const fast = A.splitBlock([data], 48000, 10000, 2);
  assert.strictEqual(fast[0].n, 480);
  assert.ok(Math.abs(fast[0].mediaMs - (10000 - 2 * 2048 / 48 + 10)) < 1e-6);
  // 多声道：样本数按声道累加（RMS 取全部声道）。
  assert.strictEqual(A.splitBlock([data, data], 48000, 10000, 1)[0].n, 1920);
  assert.strictEqual(A.splitBlock([], 48000, 10000, 1).length, 0);
  assert.strictEqual(A.splitBlock([data], 0, 10000, 1).length, 0);
});

test('dbOf：满幅 0 dB、0.1 → -20 dB、纯静音 → SILENCE_DB；没有样本 → null', () => {
  const A = loadPure();
  assert.strictEqual(A.dbOf(1 * 100, 100), 0);
  assert.strictEqual(A.dbOf(0.01 * 100, 100), -20);
  assert.strictEqual(A.dbOf(0, 100), A.SILENCE_DB);
  assert.strictEqual(A.dbOf(0, 0), null);
});

function fill(A, env, fromMs, toMs, amp) {
  for (let t = fromMs; t < toMs; t += A.FINE_MS) A.addChunk(env, t + A.FINE_MS / 2, amp * amp * 960, 960);
}

test('coarseWindow：细格并成 100ms 粗格，窗口从第一个听到的粗格起；拖动留下的空洞是 null', () => {
  const A = loadPure();
  const env = A.createEnvelope();
  fill(A, env, 600000, 610000, 0.1);
  fill(A, env, 620000, 630000, 0.1); // 610–620s 没听过
  const w = A.coarseWindow(env);
  assert.strictEqual(w.startMs, 600000);
  assert.strictEqual(w.rmsDb.length, 300);
  assert.strictEqual(w.rmsDb[0], -20);
  assert.strictEqual(w.rmsDb[150], null);
  assert.strictEqual(w.rmsDb[299], -20);
  assert.strictEqual(w.heardMs, 20000);
  assert.strictEqual(A.heardMs(env), 20000);
  assert.strictEqual(A.coarseWindow(A.createEnvelope()), null);
});

test('buildRequest：只带与窗口相交的 cue（只有时间）；没有可用 cue 返回 null', () => {
  const A = loadPure();
  const env = A.createEnvelope();
  fill(A, env, 600000, 660000, 0.2);
  const req = A.buildRequest(env, [
    { startMs: 500000, endMs: 501000, text: '窗口前' },
    { startMs: 599500, endMs: 600500, text: '跨窗口起点' },
    { startMs: 630000, endMs: 632000, text: '窗口内' },
    { startMs: 700000, endMs: 701000, text: '窗口后' },
    { startMs: 640000, endMs: 640000, text: '退化' },
  ]);
  assert.strictEqual(req.binMs, 100);
  assert.strictEqual(req.startMs, 600000);
  assert.strictEqual(req.rmsDb.length, 600);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(req.cues)), [
    { startMs: 599500, endMs: 600500 },
    { startMs: 630000, endMs: 632000 },
  ]);
  assert.strictEqual(A.buildRequest(env, [{ startMs: 1, endMs: 2 }]), null);
  assert.strictEqual(A.buildRequest(A.createEnvelope(), [{ startMs: 1, endMs: 2 }]), null);
});

test('resultAction：aligned = 发请求时的偏移 + 再平移量；低置信 / noData 不改；app 没开 = offline', () => {
  const A = loadPure();
  assert.deepStrictEqual(
    JSON.parse(JSON.stringify(A.resultAction({ ok: true, data: { status: 'aligned', offsetMs: 1200 } }, 300))),
    { kind: 'aligned', offsetMs: 1500 });
  assert.strictEqual(A.resultAction({ ok: true, data: { status: 'lowConfidence', offsetMs: 900 } }, 0).kind, 'low-confidence');
  assert.strictEqual(A.resultAction({ ok: true, data: { status: 'noData', offsetMs: 0 } }, 0).kind, 'low-confidence');
  assert.strictEqual(A.resultAction({ ok: false, status: 0 }, 0).kind, 'offline');
  assert.strictEqual(A.resultAction(null, 0).kind, 'offline');
});

test('isSilent：听够 10 秒全是静音才算；听到一片有声即解除（片头静音不是终态）', () => {
  const A = loadPure();
  const env = A.createEnvelope();
  fill(A, env, 0, 9000, 0);
  assert.strictEqual(A.isSilent(env), false, '还没听够');
  fill(A, env, 9000, 12000, 0);
  assert.strictEqual(A.isSilent(env), true);
  fill(A, env, 12000, 12100, 0.2);
  assert.strictEqual(A.isSilent(env), false);
});

test('fineSlice：给侧边栏的 20ms 波形，没听过的格是 null，最长 60 秒', () => {
  const A = loadPure();
  const env = A.createEnvelope();
  fill(A, env, 1000, 1100, 0.1);
  const s = A.fineSlice(env, 1000, 1200);
  assert.strictEqual(s.fromMs, 1000);
  assert.strictEqual(s.binMs, 20);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(s.peaks)), [-20, -20, -20, -20, -20, null, null, null, null, null]);
  assert.strictEqual(A.fineSlice(env, 0, 600000).peaks.length, 3000);
});

// ───────── ② content 编排 ─────────

function makeContent(opts) {
  const o = opts || {};
  const toasts = [];
  const sent = [];
  const offsets = [];
  const listeners = [];
  const intervals = [];
  let procRef = null;
  const video = {
    currentTime: 600, paused: false, seeking: false, ended: false, playbackRate: 1,
    captureStream() {
      if (o.captureThrows) { const e = new Error('Cannot capture from element with cross-origin data'); e.name = 'SecurityError'; throw e; }
      return {
        getAudioTracks: () => [{}],
        getTracks: () => [{ stop() {} }],
        addEventListener() {},
      };
    },
  };
  class FakeCtx {
    constructor() { this.state = 'running'; this.destination = {}; }
    createScriptProcessor() { procRef = { connect() {}, disconnect() {}, onaudioprocess: null }; return procRef; }
    createGain() { return { gain: { value: 1 }, connect() {}, disconnect() {} }; }
    createMediaStreamSource() { return { connect() {}, disconnect() {} }; }
    resume() { return Promise.resolve(); }
    close() {}
  }
  let key = o.key || 'site/v1';
  const win = {
    fushiT: (k, p) => (p && p.offset ? k + ':' + p.offset : k),
    fushiToast: (m) => toasts.push(m),
    fushiMainVideo: () => video,
    fushiVideoKey: () => key,
    fushiSubtitleActiveCues: () => (o.cues || [{ startMs: 601000, endMs: 603000, text: 'a' }]),
    fushiSubtitleTrackList: () => ({ offsetMs: 300 }),
    fushiSubtitleSetOffset: (ms) => { offsets.push(ms); return true; },
    AudioContext: o.noAudio ? undefined : FakeCtx,
  };
  const sandbox = {
    console, Map, Math, Promise, Date,
    window: win,
    document: { querySelector: () => video, addEventListener() {}, removeEventListener() {} },
    location: { hostname: 'site', pathname: '/v1' },
    setInterval: (fn) => { intervals.push(fn); return intervals.length; },
    clearInterval() {},
    chrome: {
      runtime: {
        lastError: null,
        onMessage: { addListener: (fn) => listeners.push(fn) },
        sendMessage: (msg, cb) => {
          sent.push(msg);
          Promise.resolve().then(() => cb(o.reply || { ok: true, data: { status: 'aligned', offsetMs: 1200, confidence: 0.6 } }));
        },
      },
    },
  };
  win.document = sandbox.document;
  vm.createContext(sandbox);
  vm.runInContext(SRC, sandbox, { filename: 'subtitle-align.js' });
  // 模拟播放 seconds 秒：每块 2048 样本 @48k，媒体时间随之前进。
  function play(seconds, amp) {
    const blockMs = 2048 / 48;
    const n = Math.ceil(seconds * 1000 / blockMs);
    const data = new Float32Array(2048).fill(amp == null ? 0.3 : amp);
    for (let i = 0; i < n; i++) {
      video.currentTime += blockMs / 1000;
      procRef.onaudioprocess({ inputBuffer: { numberOfChannels: 1, sampleRate: 48000, getChannelData: () => data } });
    }
  }
  return {
    A: win.fushiSubtitleAlign, video, toasts, sent, offsets, listeners, intervals, play,
    setKey: (k) => { key = k; },
  };
}

const flush = () => new Promise((r) => setImmediate(r));

test('自动对轴：声音不够先听并提示还差几秒；攒够自动算，结果 = 当前偏移 + 服务端平移量', async () => {
  const c = makeContent();
  const r = await c.A.autoAlign();
  assert.strictEqual(r.pending, true);
  assert.deepStrictEqual(c.toasts, ['align_toast_listening']);
  assert.strictEqual(c.sent.length, 0);
  c.play(30);
  assert.strictEqual(c.sent.length, 0, '30 秒还不够');
  c.play(16);
  assert.strictEqual(c.sent.length, 1, '攒够 45 秒自动发一次');
  const req = c.sent[0];
  assert.strictEqual(req.type, 'subtitleAlign');
  assert.strictEqual(req.binMs, 100);
  assert.ok(req.startMs >= 600000 && req.startMs < 600100);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(req.cues)), [{ startMs: 601000, endMs: 603000 }]);
  await flush();
  assert.deepStrictEqual(c.offsets, [1500]);
  assert.strictEqual(c.toasts[c.toasts.length - 1], 'align_toast_done:+1.5s');
  c.play(5);
  assert.strictEqual(c.sent.length, 1, '算完不再自动重发');
});

test('暂停 / 拖动中的块不收（包络只记真正播放过的媒体时间）', () => {
  const c = makeContent();
  c.A.waveState(0, 0, true);
  c.video.paused = true;
  c.play(5);
  assert.strictEqual(c.A.waveState(0, 0, true).heardMs, 0);
  c.video.paused = false;
  c.video.seeking = true;
  c.play(5);
  assert.strictEqual(c.A.waveState(0, 0, true).heardMs, 0);
  c.video.seeking = false;
  c.play(2);
  assert.ok(c.A.waveState(0, 0, true).heardMs >= 1900);
});

test('换视频：包络清空；发出去的请求回来时已换视频则丢弃，不把上一个视频的偏移写到新视频上', async () => {
  const c = makeContent();
  c.play(0); // 让监听先建起来
  c.A.waveState(0, 0, true);
  c.play(46);
  const p = c.A.autoAlign();
  assert.strictEqual(c.sent.length, 1);
  c.setKey('site/v2');
  const r = await p;
  assert.strictEqual(r.reason, 'video-changed');
  assert.deepStrictEqual(c.offsets, []);
  assert.strictEqual(c.A.waveState(0, 0, false).heardMs, 0);
});

test('跨源视频 / 浏览器不支持：如实报错，不发请求', async () => {
  const x = makeContent({ captureThrows: true });
  const r = await x.A.autoAlign();
  assert.strictEqual(r.reason, 'cross-origin');
  assert.deepStrictEqual(x.toasts, ['align_err_cross_origin']);
  assert.strictEqual(x.A.waveState(0, 1000, true).status, 'cross-origin');
  const u = makeContent({ noAudio: true });
  assert.strictEqual((await u.A.autoAlign()).reason, 'unsupported');
  assert.strictEqual(u.sent.length, 0);
});

test('没有 Fushi 字幕轨：提示没东西可对，不开始监听', async () => {
  const c = makeContent({ cues: [] });
  const r = await c.A.autoAlign();
  assert.strictEqual(r.reason, 'no-cues');
  assert.deepStrictEqual(c.toasts, ['align_toast_no_cues']);
  assert.strictEqual(c.A.waveState(0, 0, false).status, 'idle');
});

test('服务端低置信 / app 没开：不改偏移，提示原因', async () => {
  const low = makeContent({ reply: { ok: true, data: { status: 'lowConfidence', offsetMs: 900 } } });
  low.A.waveState(0, 0, true);
  low.play(46);
  await low.A.autoAlign();
  assert.deepStrictEqual(low.offsets, []);
  assert.strictEqual(low.toasts[low.toasts.length - 1], 'align_toast_low_confidence');
  const off = makeContent({ reply: { ok: false, status: 0 } });
  off.A.waveState(0, 0, true);
  off.play(46);
  await off.A.autoAlign();
  assert.deepStrictEqual(off.offsets, []);
  assert.strictEqual(off.toasts[off.toasts.length - 1], 'align_toast_offline');
});

test('侧边栏消息：State 续租约并回这一段的细格波形；租约过期且没有待算的对轴就停止监听', () => {
  const c = makeContent();
  assert.strictEqual(c.listeners.length, 1);
  let resp = null;
  c.listeners[0]({ type: 'fushiSubtitleAlignState', fromMs: 600000, toMs: 602000, listen: true }, {}, (r) => { resp = r; });
  assert.strictEqual(resp.status, 'listening');
  c.play(1);
  c.listeners[0]({ type: 'fushiSubtitleAlignState', fromMs: 600000, toMs: 602000, listen: true }, {}, (r) => { resp = r; });
  assert.strictEqual(resp.binMs, 20);
  assert.strictEqual(resp.peaks.length, 100);
  assert.ok(resp.peaks.some((v) => v !== null));
  assert.strictEqual(resp.needMs, c.A.AUTO_MIN_CAPTURED_MS);
  // 不是本模块的消息：不抢答。
  assert.strictEqual(c.listeners[0]({ type: 'fushiSubtitleSidePanelState' }, {}, () => {}), false);
  // 租约检查：Stop 清租约；定时器下一轮即停止监听。
  c.listeners[0]({ type: 'fushiSubtitleAlignStop' }, {}, () => {});
  assert.strictEqual(c.A.waveState(0, 0, false).status, 'idle');
});

test('入口接线：侧边栏偏移行有自动对轴 / 波形对轴两键（带 i18n）与波形面板；播放器菜单项转发到 subtitle-align；manifest 在 subtitle-panel 之后装入', () => {
  const html = fs.readFileSync(path.join(__dirname, 'side-panel.html'), 'utf8');
  assert.match(html, /<button id="align-auto"[^>]*data-i18n-title="align_auto_label"/);
  assert.match(html, /<button id="align-wave"[^>]*aria-pressed="false"[^>]*data-i18n-title="align_wave_label"/);
  assert.match(html, /<section id="align-pane"[^>]*hidden>/);
  assert.match(html, /<canvas id="align-canvas"[^>]*tabindex="0"/);
  const sp = fs.readFileSync(path.join(__dirname, 'side-panel.js'), 'utf8');
  for (const type of ['fushiSubtitleAlignAuto', 'fushiSubtitleAlignState', 'fushiSubtitleAlignStop']) {
    assert.ok(sp.includes("type: '" + type + "'"), '侧边栏发 ' + type);
  }
  // 拖动松手写的是绝对偏移，与手填秒数同一条消息（同一份 trackOffsets）。
  assert.ok(sp.includes("type: 'fushiSubtitleSidePanelOffset', absoluteMs: absoluteMs"));
  const pc = fs.readFileSync(path.join(__dirname, 'player-controls.js'), 'utf8');
  assert.ok(pc.includes("item.id === 'autoAlign'") && pc.includes('A.autoAlign()'));
  const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'manifest.json'), 'utf8'));
  const js = manifest.content_scripts[0].js;
  assert.ok(js.indexOf('subtitle-align.js') > js.indexOf('subtitle-panel.js'));
  const icons = fs.readFileSync(path.join(__dirname, 'icons.js'), 'utf8');
  for (const name of ['auto_awesome', 'graphic_eq']) assert.ok(icons.includes('    ' + name + ": 'M"), name);
  const bg = fs.readFileSync(path.join(__dirname, 'background.js'), 'utf8');
  assert.ok(bg.includes("msg.type === 'subtitleAlign'") && bg.includes("'/api/subtitle/align'"));
});
