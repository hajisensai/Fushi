// 网页视频的沉浸时间 → Fushi 学习统计（先支持视频；用户 2026-09-18）。
//
// 扩展只当一个「远端播放源」：视频播放期间每秒、以及 play / pause / seek / 倍速 / ended
// 时刻，把 {mediaKey, title, positionMs, durationMs, playing, speed} 样本经 background
// （`studySample` 消息 → POST /api/extension/study）交给 app；app 侧
// `BrowserVideoStudyBridge` 为每个 mediaKey 建一个 VideoWatchTracker + StudyClock（显式记账、
// 只计首次覆盖、覆盖并集按视频身份持久化），口径与 app 内视频页完全一致——回放 / 拖回 /
// 次日重看不计，切走标签仍在播照常计（视频面不设前台门）。这里**不算时长**，只报位置。
//
// 身份：`web:` + fushiVideoKey()（YouTube 'yt-<id>'、Netflix movieId、其它 host+path），
// 与字幕轨 store 同一把 key。标题用 document.title（app 侧 study_segments.title 快照）。
//
// 只追踪「像正片」的 <video>：画面尺寸 ≥ 200×120、时长 ≥ 30s（直播 Infinity 也算）——
// YouTube 首页的悬停预览、Netflix 的卡片预告片也是 <video>，不能把刷首页算成看片。
// 一页同时只追踪一个视频：当前在播的那个。
//
// 字幕门（用户 2026-09-21）：光是「有个视频在播」不足以算沉浸——没有字幕的视频、或者用户
// 在读站点自己的字幕时，这段时间对学习的意义和刷普通视频没有区别，计进去只会把沉浸曲线
// 稀释。所以默认只在 **Fushi 真的在出字幕**（抓到的整集轨或用户拖进来的外挂字幕，
// subtitle-panel.js 的 fushiSubtitleStudyState().showing）时才上报，判据与什么算数由
// 设置 `studyTrackVideoCondition` 决定：
//   'fushiSubtitle'（默认）Fushi 字幕 / 外挂字幕正在用；
//   'anySubtitle'          这个视频有任何 Fushi 认得出的字幕轨（含站点原生采样的 live 轨
//                          与按需加载的占位轨），不要求用户已经在读；
//   'always'               任何正片都计（旧行为）。
// 门是**持续**判定的：字幕中途才加载 → 那一刻开始计；用户中途关掉字幕 → 立刻停表（发
// ended，与换视频同一条路径）。app 侧按 mediaKey 持久化覆盖并集，停表再续不会重复计。
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  var SETTING_KEY = 'studyTrackVideo';
  var CONDITION_KEY = 'studyTrackVideoCondition';
  // content.js 的 Shift+H（fushiToggleSubtitleHiding）落的键：原生字幕与 Fushi 自绘一起藏。
  // 用户把字幕全藏了还算「开着 Fushi 字幕」说不过去，默认档一票否决。
  var HIDDEN_KEY = 'subtitleHidden';
  var CONDITION_DEFAULT = 'fushiSubtitle';
  // 未知值（旧版写的、手改 storage 写歪的）一律回落默认档，不静默变成「全都计」。
  var CONDITIONS = { fushiSubtitle: 1, anySubtitle: 1, always: 1 };
  var SAMPLE_MS = 1000;
  var MIN_DURATION_S = 30;
  var MIN_W = 200, MIN_H = 120;

  var enabled = true;
  var condition = CONDITION_DEFAULT;
  // 候选 = 最近一次开播的正片。门没开时也留着：字幕晚到几秒是常态（整集轨要抓 / 用户
  // 看了一会儿才拖外挂字幕），丢掉候选就只能等下一次 play 事件，而那可能整集都不会再来。
  var candidate = null;
  var subtitleHidden = false;
  var tracked = null;      // 当前追踪的 <video>
  var trackedKey = '';     // 追踪开始时的 mediaKey（换视频 = key 变）
  var timer = 0;
  var lastSentAt = 0;

  function applySetting(saved) {
    saved = saved || {};
    if (typeof saved[SETTING_KEY] === 'boolean') enabled = saved[SETTING_KEY];
    if (CONDITION_KEY in saved) {
      var raw = saved[CONDITION_KEY];
      condition = (typeof raw === 'string' && CONDITIONS[raw]) ? raw : CONDITION_DEFAULT;
    }
    if (HIDDEN_KEY in saved) subtitleHidden = saved[HIDDEN_KEY] === true;
    evaluate();
  }
  try {
    var p = chrome.storage.local.get([SETTING_KEY, CONDITION_KEY, HIDDEN_KEY], applySetting);
    if (p && typeof p.then === 'function') p.then(applySetting, function () {});
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      if (!changes[SETTING_KEY] && !changes[CONDITION_KEY] && !changes[HIDDEN_KEY]) return;
      var patch = {};
      if (changes[SETTING_KEY]) patch[SETTING_KEY] = changes[SETTING_KEY].newValue;
      if (changes[CONDITION_KEY]) patch[CONDITION_KEY] = changes[CONDITION_KEY].newValue;
      if (changes[HIDDEN_KEY]) patch[HIDDEN_KEY] = changes[HIDDEN_KEY].newValue;
      applySetting(patch);
    });
  } catch (_) {}

  function mediaKey() {
    var k = '';
    try { if (typeof window.fushiVideoKey === 'function') k = window.fushiVideoKey(); } catch (_) {}
    if (typeof k !== 'string' || !k) {
      k = (location.hostname + location.pathname).replace(/\|/g, '_');
    }
    return 'web:' + k;
  }

  function pageTitle() {
    var t = '';
    try { t = String(document.title || '').trim(); } catch (_) {}
    return t.slice(0, 200);
  }

  // 纯判定：这个 <video> 像不像正片（供测试）。
  function looksLikeMainVideo(v) {
    if (!v) return false;
    var d = Number(v.duration);
    // duration NaN = 元数据未到，先不追（下一次 play/timeupdate 再判）；Infinity = 直播，算。
    if (!(d >= MIN_DURATION_S)) return false;
    var r = null;
    try { r = v.getBoundingClientRect(); } catch (_) { r = null; }
    if (!r || r.width < MIN_W || r.height < MIN_H) return false;
    return true;
  }

  function sampleOf(v, ended) {
    var d = Number(v.duration);
    var pos = Number(v.currentTime);
    var rate = Number(v.playbackRate);
    return {
      mediaKind: 'video',
      mediaKey: trackedKey,
      title: pageTitle(),
      positionMs: isFinite(pos) && pos >= 0 ? Math.round(pos * 1000) : 0,
      durationMs: isFinite(d) && d >= 0 ? Math.round(d * 1000) : null,
      playing: !ended && !v.paused && !v.ended,
      speed: isFinite(rate) && rate > 0 ? rate : 1,
      ended: ended === true,
    };
  }

  function send(sample) {
    lastSentAt = Date.now();
    try {
      chrome.runtime.sendMessage({ type: 'studySample', sample: sample }, function () {
        try { void chrome.runtime.lastError; } catch (_) {}
      });
    } catch (_) {}
  }

  // ── 字幕门 ──
  // 唯一信息源是面板的 fushiSubtitleStudyState（subtitle-panel.js）。拿不到它（面板脚本
  // 没装 / 单测只装了本文件）一律当「没有字幕」：宁可少计，也不把刷视频算成沉浸。
  // 不直接数 window.fushiEpisodeCues：Netflix 整集拦截会把几十种语言都拿进 store、
  // textTracks 收割还会把 disabled 轨提权成 hidden，那个集合非空几乎恒真。
  function subtitleState() {
    try {
      if (typeof window.fushiSubtitleStudyState === 'function') {
        return window.fushiSubtitleStudyState() || null;
      }
    } catch (_) {}
    return null;
  }

  function gateOpen() {
    if (condition === 'always') return true;
    var s = subtitleState();
    if (!s) return false;
    if (condition === 'anySubtitle') return s.any === true || s.showing === true;
    return s.showing === true && !subtitleHidden;
  }

  function startTimer() { if (!timer) timer = setInterval(tick, SAMPLE_MS); }
  function stopTimer() { if (timer) { clearInterval(timer); timer = 0; } }

  // 追不追的唯一决策点：设置、正片判定、字幕门任一不成立就停表（发 ended），
  // 全成立就开表。每秒 + 每次设置/隐藏状态变化各跑一次 → 字幕晚到几秒、中途拖外挂字幕、
  // 中途关掉字幕都能在一秒内跟上，不用等下一次 play 事件（整集都可能不再来）。
  function evaluate() {
    var v = candidate || tracked;
    if (!v) { stopTimer(); return; }
    if (!v.isConnected) { release(true); candidate = null; stopTimer(); return; }
    // 总开关关掉：停表连定时器一起停（重开是 storage 事件，applySetting 会再跑一次
    // evaluate，candidate 还在就直接续上）。门关着则**保留**定时器——门重开不发任何
    // 事件，只能靠每秒 evaluate 发现。
    if (!enabled) { release(true); stopTimer(); return; }
    if (!looksLikeMainVideo(v) || !gateOpen()) { release(true); return; }
    adopt(v);
  }

  function tick() {
    var v = candidate || tracked;
    if (!v) { stopTimer(); return; }
    // 视频被站点换掉 / 摘出 DOM（SPA 换集常见）：结束这条，等下一次 play 重新认。
    if (!v.isConnected) { release(true); candidate = null; stopTimer(); return; }
    // 同一页 URL 变了（YouTube 换视频不换 <video> 元素）：key 变 = 换视频，先结束旧的。
    if (tracked && mediaKey() !== trackedKey) { release(true); evaluate(); return; }
    // 门刚开的那一拍：adopt 已经发过一条起始样本，这拍不再补心跳。
    var before = tracked;
    evaluate();
    if (!tracked || tracked !== before) return;
    if (tracked.paused || tracked.ended) return; // 暂停态不刷心跳：pause 事件已经发过一次 playing=false
    send(sampleOf(tracked, false));
  }

  function adopt(v) {
    if (tracked === v) return;
    if (tracked) release(true);
    tracked = v;
    trackedKey = mediaKey();
    v.addEventListener('pause', onPause);
    v.addEventListener('ended', onEnded);
    v.addEventListener('seeked', onSeeked);
    v.addEventListener('ratechange', onSeeked);
    v.addEventListener('emptied', onEmptied);
    startTimer();
    send(sampleOf(v, false));
  }

  // ended=true 时给 app 一个「停表」信号（换视频 / 页面卸载 / 关掉设置 / 字幕门关上）。
  // 候选与定时器留着：门可能下一秒就又开（用户把字幕又打开了），那时直接续上即可。
  function release(ended) {
    var v = tracked;
    if (!v) return;
    v.removeEventListener('pause', onPause);
    v.removeEventListener('ended', onEnded);
    v.removeEventListener('seeked', onSeeked);
    v.removeEventListener('ratechange', onSeeked);
    v.removeEventListener('emptied', onEmptied);
    tracked = null;
    if (ended) send(sampleOf(v, true));
    trackedKey = '';
  }

  function onPause() { if (tracked) send(sampleOf(tracked, false)); }
  function onSeeked() { if (tracked && !tracked.paused) send(sampleOf(tracked, false)); }
  function onEnded() { if (tracked) send(sampleOf(tracked, false)); }
  function onEmptied() { release(true); candidate = null; stopTimer(); }

  // 记下「这页正在放的那部正片」。真开不开表交给 evaluate（字幕门可能还没开）。
  function notice(v) {
    if (!v || v.tagName !== 'VIDEO') return;
    if (!looksLikeMainVideo(v)) return;
    candidate = v;
    startTimer();
    evaluate();
  }

  // 媒体事件不冒泡，capture 阶段在 document 上能收到所有 <video>（含后来插入的）。
  document.addEventListener('play', function (e) {
    notice(e.target);
  }, true);
  // 元数据晚于 play 到达（duration 从 NaN 变成真值）时补认。
  document.addEventListener('durationchange', function (e) {
    var v = e.target;
    if (!v || v.tagName !== 'VIDEO' || tracked || v.paused) return;
    notice(v);
  }, true);
  document.addEventListener('pagehide', function () {
    release(true);
    candidate = null;
    stopTimer();
  });

  // 注入时已经在播的视频（扩展刚装 / 页面刷新后自动续播）。
  try {
    var vids = document.querySelectorAll('video');
    for (var i = 0; i < vids.length; i++) {
      if (!vids[i].paused && !vids[i].ended) { notice(vids[i]); break; }
    }
  } catch (_) {}

  window.fushiStudyTracker = {
    looksLikeMainVideo: looksLikeMainVideo,
    gateOpen: gateOpen,
    get condition() { return condition; },
    get tracked() { return tracked; },
    get lastSentAt() { return lastSentAt; },
  };
})();
