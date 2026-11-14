// 网页视频字幕对轴：自动对轴 + 波形对轴（反馈 0wkJImhZUp：「浏览器扩展里也要有自动对轴和波形对轴」）。
//
// app 视频页的对轴从媒体文件里用 ffmpeg 抽「逐窗 RMS 能量包络」，再与字幕 cue 做互相关
// （fushi/lib/src/media/video/subtitle_auto_align.dart，互相关本体在 Rust）。网页视频没有可读的
// 文件（MSE / blob / 跨源流），能拿到声音的只有正在播的 <video> 本身：
//
//   <video>.captureStream() ─▶ AudioContext ─▶ ScriptProcessor（每块按 20ms 切片算 RMS）
//                                               └─▶ 按**媒体时间**（video.currentTime）落格
//
// captureStream 只是旁路一份音轨，元素照常对用户发声（不像 tabCapture 会把整页声音改道）；处理节点
// 经 0 增益接到 destination，不会多出第二份声音。暂停 / 拖动中 / 结束的块不收，所以包络是媒体时间上
// 「听过的格」，拖动进度条留下的空洞就是没听过的格（null）。
//
// · 自动对轴：攒够 AUTO_MIN_CAPTURED_MS 的声音后，把 100ms 栅格的包络（dBFS，与 ffmpeg astats
//   RMS_level 同义）+ 当前轨已套偏移的 cue 交给 app（background `subtitleAlign` → POST
//   /api/subtitle/align），服务端用 app 那套算法算出「再平移多少」，这里加到当前偏移上。不够就
//   继续听，够了自动算（播放器菜单 / 侧边栏按一次即可）。
// · 波形对轴：侧边栏画 20ms 栅格的波形（与 app 波形视图同一密度）+ cue 条，拖动 cue 条改偏移。
//   侧边栏每次轮询续一次「租约」，租约过期且没有待算的自动对轴就停止监听——侧边栏关掉不会一直占着
//   音频图。
//
// 拿不到声音时如实说原因，不假装成功：浏览器没有 captureStream（unsupported）、跨源视频
// （cross-origin，浏览器禁止读它的采样）、读到的全是静音（silent：DRM 保护的流常见）、自动播放策略
// 挂起了 AudioContext（needs-gesture：在页面上点一下即恢复）。
//
// 纯函数部分（包络缓冲 / 切片 / 栅格化 / 请求体）无 DOM、node 可测；采集与消息只在 content script 里装。
(function () {
  'use strict';
  var g = (typeof window !== 'undefined') ? window : ((typeof self !== 'undefined') ? self : null);
  if (!g) return;

  // 自动对轴栅格：必须等于 app kSubtitleAutoAlignBinMs（服务端只认这个栅格，Dart 测试交叉比对）。
  var BIN_MS = 100;
  // 波形栅格：与 app 波形视图 kSubtitleWaveformWindowMs 同一密度（50 根柱 / 秒）。
  var FINE_MS = 20;
  // 静音块的 dB（ffmpeg astats 的 -inf 在 app 里映射成同一个有限值）。
  var SILENCE_DB = -120;
  // 自动对轴开算门槛：听到 45 秒。必须 ≥ 服务端最小样本量（kCaptureAlignMinCapturedBins × 100ms =
  // 20 秒，Dart 测试交叉比对）；多留余量是因为网页上常有片头曲 / 无对白段，20 秒可能只有几句话。
  var AUTO_MIN_CAPTURED_MS = 45000;
  // 发给服务端的窗口上限：20 分钟（服务端 kCaptureAlignMaxBins = 12000 格 @100ms）。
  var MAX_WINDOW_MS = 20 * 60 * 1000;
  // 内存上限：最多记 30 分钟的细格（超出按最早写入的先丢）。
  var MAX_FINE_BINS = 90000;
  // 听了这么久仍全部低于 SILENT_DB → 判定读不到声音（DRM 流 captureStream 给的是静音）。
  var SILENT_PROBE_MS = 10000;
  var SILENT_DB = -90;
  // 侧边栏波形的租约：每次取状态续 4 秒；过期且没有待算的自动对轴就停止监听。
  var LEASE_MS = 4000;
  // 侧边栏一次最多要 60 秒的波形（3000 个细格）。
  var MAX_SLICE_MS = 60000;

  // ── 纯函数：包络缓冲 ────────────────────────────────────────────────────

  // 细格 → [平方和, 样本数]。Map 按插入序，超上限时丢最早写入的格。loud = 听到过高于 SILENT_DB
  // 的切片（O(1) 判「读到的全是静音」，不必每块都扫一遍全部格）。
  function createEnvelope() {
    return { bins: new Map(), loud: false };
  }

  function addChunk(env, mediaMs, sumSq, n) {
    if (!env || !(n > 0) || !isFinite(mediaMs) || mediaMs < 0 || !isFinite(sumSq)) return;
    var idx = Math.floor(mediaMs / FINE_MS);
    if (!env.loud) {
      var db = dbOf(sumSq, n);
      if (db !== null && db > SILENT_DB) env.loud = true;
    }
    var cur = env.bins.get(idx);
    if (cur) { cur[0] += sumSq; cur[1] += n; return; }
    env.bins.set(idx, [sumSq, n]);
    while (env.bins.size > MAX_FINE_BINS) env.bins.delete(env.bins.keys().next().value);
  }

  function dbOf(sumSq, n) {
    if (!(n > 0)) return null;
    var rms = Math.sqrt(sumSq / n);
    if (!(rms > 0)) return SILENCE_DB;
    var db = 20 * Math.log10(rms);
    return db < SILENCE_DB ? SILENCE_DB : Math.round(db * 10) / 10;
  }

  function heardMs(env) {
    return env ? env.bins.size * FINE_MS : 0;
  }

  // 听够 SILENT_PROBE_MS 仍没有一片高于 SILENT_DB = 读到的是静音流（DRM 流的旁路常见）。
  // 片头真静音也会暂时命中；一旦听到声音就自动回到 listening（见 onBlock），不是终态。
  function isSilent(env) {
    return !!env && heardMs(env) >= SILENT_PROBE_MS && !env.loud;
  }

  // 一段媒体时间 [fromMs, toMs) 的细格波形（dBFS 或 null = 没听过），侧边栏画波形用。
  function fineSlice(env, fromMs, toMs) {
    var from = Math.floor(Math.max(0, Number(fromMs) || 0) / FINE_MS);
    var to = Math.ceil(Math.max(0, Number(toMs) || 0) / FINE_MS);
    if (to - from > MAX_SLICE_MS / FINE_MS) to = from + MAX_SLICE_MS / FINE_MS;
    var out = [];
    for (var i = from; i < to; i++) {
      var v = env ? env.bins.get(i) : null;
      out.push(v ? dbOf(v[0], v[1]) : null);
    }
    return { fromMs: from * FINE_MS, binMs: FINE_MS, peaks: out };
  }

  // 细格合并成自动对轴的 100ms 栅格：窗口取「最后听到的格」往前至多 MAX_WINDOW_MS。
  // 每个粗格的电平 = 其中全部样本的 RMS（平方和合并，不是 dB 求平均）；整格没听过 = null。
  function coarseWindow(env) {
    if (!env || env.bins.size === 0) return null;
    var ratio = BIN_MS / FINE_MS;
    var minC = Infinity, maxC = -Infinity;
    env.bins.forEach(function (_v, idx) {
      var c = Math.floor(idx / ratio);
      if (c < minC) minC = c;
      if (c > maxC) maxC = c;
    });
    var startC = Math.max(minC, maxC + 1 - MAX_WINDOW_MS / BIN_MS);
    var len = maxC + 1 - startC;
    var sq = new Array(len), n = new Array(len), heard = 0;
    for (var k = 0; k < len; k++) { sq[k] = 0; n[k] = 0; }
    env.bins.forEach(function (v, idx) {
      var c = Math.floor(idx / ratio) - startC;
      if (c < 0 || c >= len) return;
      sq[c] += v[0]; n[c] += v[1];
    });
    var rmsDb = new Array(len);
    for (var j = 0; j < len; j++) {
      rmsDb[j] = n[j] > 0 ? dbOf(sq[j], n[j]) : null;
      if (rmsDb[j] !== null) heard += BIN_MS;
    }
    return { startMs: startC * BIN_MS, rmsDb: rmsDb, heardMs: heard };
  }

  // 自动对轴请求体（background `subtitleAlign` 原样转发给 /api/subtitle/align）。cue 只带与窗口
  // 相交的那些（服务端本来也只看窗口内），且只带时间不带文字。没有可用窗口 / cue 返回 null。
  function buildRequest(env, cues) {
    var w = coarseWindow(env);
    if (!w || !Array.isArray(cues)) return null;
    var endMs = w.startMs + w.rmsDb.length * BIN_MS;
    var out = [];
    for (var i = 0; i < cues.length; i++) {
      var c = cues[i];
      if (!c) continue;
      var s = Number(c.startMs), e = Number(c.endMs);
      if (!isFinite(s) || !isFinite(e) || e <= s) continue;
      if (e <= w.startMs || s >= endMs) continue;
      out.push({ startMs: Math.round(s), endMs: Math.round(e) });
    }
    if (!out.length) return null;
    return { binMs: BIN_MS, startMs: w.startMs, rmsDb: w.rmsDb, cues: out };
  }

  // 一块采样 → 若干 20ms 切片的 {mediaMs（切片中点的媒体时间）, sumSq, n}。
  // channels：每声道一个 Float32Array（同长）；endMediaMs：块末尾对应的媒体时间（处理回调时的
  // currentTime）；rate：播放倍速（1 秒墙钟 = rate 秒媒体时间）。多声道取全部声道样本的 RMS。
  function splitBlock(channels, sampleRate, endMediaMs, rate) {
    if (!channels || !channels.length || !(sampleRate > 0) || !isFinite(endMediaMs)) return [];
    var len = channels[0].length;
    if (!len) return [];
    var r = rate > 0 ? rate : 1;
    var chunk = Math.max(1, Math.round(sampleRate * FINE_MS / 1000 / r));
    var msPerSample = 1000 * r / sampleRate;
    var startMediaMs = endMediaMs - len * msPerSample;
    var out = [];
    for (var at = 0; at < len; at += chunk) {
      var stop = Math.min(len, at + chunk);
      var sumSq = 0, n = 0;
      for (var ch = 0; ch < channels.length; ch++) {
        var data = channels[ch];
        for (var i = at; i < stop; i++) { var x = data[i]; sumSq += x * x; }
        n += stop - at;
      }
      out.push({ mediaMs: startMediaMs + (at + stop) / 2 * msPerSample, sumSq: sumSq, n: n });
    }
    return out;
  }

  // 服务端回应 → 动作。base = 发请求时的偏移（cue 是按它平移过的），结果是「再平移多少」。
  function resultAction(resp, baseOffsetMs) {
    var data = resp && resp.ok === true && resp.data && typeof resp.data === 'object' ? resp.data : null;
    if (!data) return { kind: 'offline' };
    if (data.status === 'aligned' && typeof data.offsetMs === 'number' && isFinite(data.offsetMs)) {
      return { kind: 'aligned', offsetMs: Math.round((Number(baseOffsetMs) || 0) + data.offsetMs) };
    }
    return { kind: 'low-confidence' };
  }

  // 状态 → 侧边栏 / 提示文案键（null = 不是错误态）。
  var ERROR_KEYS = {
    unsupported: 'align_err_unsupported',
    'cross-origin': 'align_err_cross_origin',
    silent: 'align_err_silent',
    'needs-gesture': 'align_err_needs_gesture',
  };

  var api = {
    BIN_MS: BIN_MS,
    FINE_MS: FINE_MS,
    SILENCE_DB: SILENCE_DB,
    AUTO_MIN_CAPTURED_MS: AUTO_MIN_CAPTURED_MS,
    MAX_WINDOW_MS: MAX_WINDOW_MS,
    LEASE_MS: LEASE_MS,
    ERROR_KEYS: ERROR_KEYS,
    createEnvelope: createEnvelope,
    addChunk: addChunk,
    dbOf: dbOf,
    heardMs: heardMs,
    isSilent: isSilent,
    fineSlice: fineSlice,
    coarseWindow: coarseWindow,
    buildRequest: buildRequest,
    splitBlock: splitBlock,
    resultAction: resultAction,
  };
  g.fushiSubtitleAlign = api;

  // ── content script：采集 + 编排 ─────────────────────────────────────────
  if (typeof document === 'undefined' || typeof g.document === 'undefined') return;

  function tr(key, params) {
    return (typeof g.fushiT === 'function') ? g.fushiT(key, params) : key;
  }
  function toast(msg) {
    try { if (typeof g.fushiToast === 'function') g.fushiToast(msg); } catch (_) {}
  }
  function mainVideo() {
    if (typeof g.fushiMainVideo === 'function') {
      var v = g.fushiMainVideo();
      if (v) return v;
    }
    return document.querySelector('video');
  }
  function currentVideoKey() {
    try {
      if (typeof g.fushiVideoKey === 'function') {
        var k = g.fushiVideoKey();
        if (typeof k === 'string' && k) return k;
      }
    } catch (_) {}
    return location.hostname + location.pathname;
  }
  function activeCues() {
    try {
      if (typeof g.fushiSubtitleActiveCues === 'function') {
        var c = g.fushiSubtitleActiveCues();
        if (Array.isArray(c)) return c;
      }
    } catch (_) {}
    return [];
  }
  function currentOffset() {
    try {
      if (typeof g.fushiSubtitleTrackList === 'function') {
        var info = g.fushiSubtitleTrackList();
        return info && typeof info.offsetMs === 'number' ? info.offsetMs : 0;
      }
    } catch (_) {}
    return 0;
  }

  var cap = {
    env: createEnvelope(),
    key: null,           // 包络属于哪个视频（换视频清空）
    video: null,
    stream: null,
    ctx: null,
    source: null,
    proc: null,
    mute: null,
    status: 'idle',      // idle | listening | unsupported | cross-origin | silent | needs-gesture
    leaseUntil: 0,
    pending: false,      // 等声音攒够后自动对轴
    inflight: false,
    leaseTimer: null,
    gestureHook: null,
  };

  function syncVideoKey() {
    var key = currentVideoKey();
    if (key !== cap.key) {
      cap.key = key;
      cap.env = createEnvelope();
      cap.pending = false;
      if (cap.status === 'silent') cap.status = cap.ctx ? 'listening' : 'idle';
      // 换视频：已发出的对轴结果属于上一个视频，回来后不再套用（见 runAlign 的 key 比对）。
    }
  }

  function teardownGraph() {
    try { if (cap.proc) { cap.proc.onaudioprocess = null; cap.proc.disconnect(); } } catch (_) {}
    try { if (cap.source) cap.source.disconnect(); } catch (_) {}
    try { if (cap.mute) cap.mute.disconnect(); } catch (_) {}
    try { if (cap.ctx && typeof cap.ctx.close === 'function') cap.ctx.close(); } catch (_) {}
    // 只停旁路出来的那份轨：元素自己的播放不受影响。
    try { if (cap.stream) cap.stream.getTracks().forEach(function (t) { t.stop(); }); } catch (_) {}
    if (cap.gestureHook) {
      document.removeEventListener('pointerdown', cap.gestureHook, true);
      document.removeEventListener('keydown', cap.gestureHook, true);
      cap.gestureHook = null;
    }
    cap.proc = cap.source = cap.mute = cap.ctx = cap.stream = cap.video = null;
  }

  function stopListening() {
    teardownGraph();
    if (cap.leaseTimer) { clearInterval(cap.leaseTimer); cap.leaseTimer = null; }
    // 不再听：「在听 / 待激活 / 听到的全是静音」都只描述监听中的状态，停了就回 idle；
    // 跨源 / 不支持是这个视频本身的事实，保留给侧边栏如实显示。
    if (cap.status === 'listening' || cap.status === 'needs-gesture' || cap.status === 'silent') cap.status = 'idle';
  }

  function onBlock(e) {
    var v = cap.video;
    if (!v || v.paused || v.seeking || v.ended) return;
    syncVideoKey();
    var buf = e.inputBuffer;
    var channels = [];
    for (var ch = 0; ch < buf.numberOfChannels; ch++) channels.push(buf.getChannelData(ch));
    var chunks = splitBlock(channels, buf.sampleRate, v.currentTime * 1000, v.playbackRate);
    for (var i = 0; i < chunks.length; i++) addChunk(cap.env, chunks[i].mediaMs, chunks[i].sumSq, chunks[i].n);
    var silent = isSilent(cap.env);
    if (cap.status === 'listening' && silent) cap.status = 'silent';
    else if (cap.status === 'silent' && !silent) cap.status = 'listening';
    if (cap.pending && !cap.inflight && heardMs(cap.env) >= AUTO_MIN_CAPTURED_MS) {
      cap.pending = false;
      runAlign();
    }
  }

  function connectSource() {
    if (!cap.ctx || !cap.stream || !cap.proc) return;
    if (!cap.stream.getAudioTracks().length) return; // 还没有音轨：等 addtrack
    try { if (cap.source) cap.source.disconnect(); } catch (_) {}
    try {
      cap.source = cap.ctx.createMediaStreamSource(cap.stream);
      cap.source.connect(cap.proc);
    } catch (_) {
      cap.source = null;
    }
  }

  function resumeContext() {
    if (!cap.ctx || cap.ctx.state !== 'suspended') return;
    var p = null;
    try { p = cap.ctx.resume(); } catch (_) {}
    var after = function () {
      if (!cap.ctx) return;
      if (cap.ctx.state === 'running') {
        if (cap.status === 'needs-gesture') cap.status = 'listening';
        return;
      }
      // 自动播放策略：页面还没有用户激活。下一次在页面上点 / 按键时再恢复。
      cap.status = 'needs-gesture';
      if (!cap.gestureHook) {
        cap.gestureHook = function () { resumeContext(); };
        document.addEventListener('pointerdown', cap.gestureHook, true);
        document.addEventListener('keydown', cap.gestureHook, true);
      }
    };
    if (p && typeof p.then === 'function') p.then(after, after); else after();
  }

  // 开始（或保持）监听当前正片。返回当前状态。
  function startListening() {
    syncVideoKey();
    var v = mainVideo();
    if (!v) return cap.status;
    if (cap.video === v && cap.ctx) { resumeContext(); return cap.status; }
    teardownGraph();
    var Ctx = g.AudioContext || g.webkitAudioContext;
    // 只认标准 captureStream：Firefox 的 mozCaptureStream 会把元素自己的声音拿走（用户听不到）。
    if (typeof v.captureStream !== 'function' || !Ctx) {
      cap.status = 'unsupported';
      return cap.status;
    }
    try {
      cap.stream = v.captureStream();
    } catch (err) {
      var msg = err && (String(err.name || '') + ' ' + String(err.message || ''));
      cap.status = /secur|cross-origin|origin/i.test(msg || '') ? 'cross-origin' : 'unsupported';
      cap.stream = null;
      return cap.status;
    }
    try {
      cap.ctx = new Ctx();
      cap.proc = cap.ctx.createScriptProcessor(2048, 2, 1);
      cap.mute = cap.ctx.createGain();
      cap.mute.gain.value = 0;
      cap.proc.onaudioprocess = onBlock;
      cap.proc.connect(cap.mute);
      cap.mute.connect(cap.ctx.destination);
    } catch (_) {
      teardownGraph();
      cap.status = 'unsupported';
      return cap.status;
    }
    cap.video = v;
    cap.status = isSilent(cap.env) ? 'silent' : 'listening';
    // 换源（MSE 换清晰度 / 下一集）时旁路流会换音轨：重新接上。
    try { cap.stream.addEventListener('addtrack', connectSource); } catch (_) {}
    connectSource();
    resumeContext();
    if (!cap.leaseTimer) {
      cap.leaseTimer = setInterval(function () {
        if (!cap.pending && !cap.inflight && Date.now() > cap.leaseUntil) stopListening();
      }, 1000);
    }
    return cap.status;
  }

  // 读不到声音的终态（换视频前不会自己好）。silent 不算：片头静音也会暂时命中，听到声音即恢复。
  function isError(status) {
    return status === 'unsupported' || status === 'cross-origin';
  }

  function sendAlignRequest(body) {
    return new Promise(function (resolve) {
      try {
        chrome.runtime.sendMessage(Object.assign({ type: 'subtitleAlign' }, body), function (resp) {
          try { if (chrome.runtime.lastError) return resolve(null); } catch (_) { return resolve(null); }
          resolve(resp || null);
        });
      } catch (_) { resolve(null); }
    });
  }

  function runAlign() {
    var cues = activeCues();
    var body = buildRequest(cap.env, cues);
    if (!body) {
      toast(tr(cues.length ? 'align_toast_low_confidence' : 'align_toast_no_cues'));
      return Promise.resolve({ ok: false, reason: cues.length ? 'low-confidence' : 'no-cues' });
    }
    var base = currentOffset();
    var key = cap.key;
    cap.inflight = true;
    return sendAlignRequest(body).then(function (resp) {
      cap.inflight = false;
      syncVideoKey();
      if (cap.key !== key) return { ok: false, reason: 'video-changed' };
      var act = resultAction(resp, base);
      if (act.kind === 'aligned') {
        var ok = typeof g.fushiSubtitleSetOffset === 'function' && g.fushiSubtitleSetOffset(act.offsetMs) === true;
        if (!ok) { toast(tr('align_toast_no_cues')); return { ok: false, reason: 'no-cues' }; }
        toast(tr('align_toast_done', { offset: (act.offsetMs >= 0 ? '+' : '') + (act.offsetMs / 1000).toFixed(1) + 's' }));
        return { ok: true, offsetMs: act.offsetMs };
      }
      toast(tr(act.kind === 'offline' ? 'align_toast_offline' : 'align_toast_low_confidence'));
      return { ok: false, reason: act.kind };
    });
  }

  // 自动对轴入口（播放器菜单 / 侧边栏 / 消息）：声音够了立刻算，不够就开始听、攒够后自动算。
  function autoAlign() {
    if (cap.inflight) return Promise.resolve({ ok: true, pending: true });
    if (!activeCues().length) {
      toast(tr('align_toast_no_cues'));
      return Promise.resolve({ ok: false, reason: 'no-cues' });
    }
    var status = startListening();
    if (isError(status)) {
      toast(tr(ERROR_KEYS[status]));
      return Promise.resolve({ ok: false, reason: status });
    }
    var heard = heardMs(cap.env);
    if (heard >= AUTO_MIN_CAPTURED_MS) return runAlign();
    cap.pending = true;
    var key = ERROR_KEYS[status] || 'align_toast_listening';
    toast(tr(key, { seconds: String(Math.ceil((AUTO_MIN_CAPTURED_MS - heard) / 1000)) }));
    return Promise.resolve({ ok: true, pending: true });
  }

  // 侧边栏波形一轮：续租约（保持监听）+ 回状态与这一段的细格波形。
  function waveState(fromMs, toMs, keepListening) {
    if (keepListening) {
      cap.leaseUntil = Date.now() + LEASE_MS;
      startListening();
    } else {
      syncVideoKey();
    }
    var v = cap.video || mainVideo();
    var slice = fineSlice(cap.env, fromMs, toMs);
    return {
      ok: true,
      status: cap.status,
      heardMs: heardMs(cap.env),
      pending: cap.pending,
      inflight: cap.inflight,
      needMs: AUTO_MIN_CAPTURED_MS,
      currentTimeMs: v && typeof v.currentTime === 'number' ? Math.round(v.currentTime * 1000) : 0,
      paused: !v || !!v.paused,
      rate: v && v.playbackRate > 0 ? v.playbackRate : 1,
      fromMs: slice.fromMs,
      binMs: slice.binMs,
      peaks: slice.peaks,
    };
  }

  api.autoAlign = autoAlign;
  api.waveState = waveState;
  api.stopListening = function () {
    cap.leaseUntil = 0;
    if (!cap.pending && !cap.inflight) stopListening();
  };

  try {
    chrome.runtime.onMessage.addListener(function (msg, _sender, sendResponse) {
      if (!msg || typeof msg.type !== 'string' || msg.type.indexOf('fushiSubtitleAlign') !== 0) return false;
      if (msg.type === 'fushiSubtitleAlignState') {
        sendResponse(waveState(Number(msg.fromMs) || 0, Number(msg.toMs) || 0, msg.listen === true));
        return false;
      }
      if (msg.type === 'fushiSubtitleAlignStop') {
        api.stopListening();
        sendResponse({ ok: true });
        return false;
      }
      if (msg.type === 'fushiSubtitleAlignAuto') {
        autoAlign().then(function (r) { sendResponse(r); }, function () { sendResponse({ ok: false }); });
        return true;
      }
      return false;
    });
  } catch (_) {}
})();
