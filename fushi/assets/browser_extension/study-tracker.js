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
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  var SETTING_KEY = 'studyTrackVideo';
  var SAMPLE_MS = 1000;
  var MIN_DURATION_S = 30;
  var MIN_W = 200, MIN_H = 120;

  var enabled = true;
  var tracked = null;      // 当前追踪的 <video>
  var trackedKey = '';     // 追踪开始时的 mediaKey（换视频 = key 变）
  var timer = 0;
  var lastSentAt = 0;

  function applySetting(saved) {
    saved = saved || {};
    if (typeof saved[SETTING_KEY] === 'boolean') enabled = saved[SETTING_KEY];
    if (!enabled) release(true);
  }
  try {
    var p = chrome.storage.local.get(SETTING_KEY, applySetting);
    if (p && typeof p.then === 'function') p.then(applySetting, function () {});
  } catch (_) {}
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes || !changes[SETTING_KEY]) return;
      var patch = {};
      patch[SETTING_KEY] = changes[SETTING_KEY].newValue;
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

  function tick() {
    var v = tracked;
    if (!v) return;
    // 视频被站点换掉 / 摘出 DOM（SPA 换集常见）：结束这条，等下一次 play 重新认。
    if (!v.isConnected) { release(true); return; }
    // 同一页 URL 变了（YouTube 换视频不换 <video> 元素）：key 变 = 换视频，先结束旧的。
    if (mediaKey() !== trackedKey) { release(true); adopt(v); return; }
    if (v.paused || v.ended) return; // 暂停态不刷心跳：pause 事件已经发过一次 playing=false
    send(sampleOf(v, false));
  }

  function adopt(v) {
    if (!enabled || !looksLikeMainVideo(v)) return;
    if (tracked === v) return;
    if (tracked) release(true);
    tracked = v;
    trackedKey = mediaKey();
    v.addEventListener('pause', onPause);
    v.addEventListener('ended', onEnded);
    v.addEventListener('seeked', onSeeked);
    v.addEventListener('ratechange', onSeeked);
    v.addEventListener('emptied', onEmptied);
    timer = setInterval(tick, SAMPLE_MS);
    send(sampleOf(v, false));
  }

  // ended=true 时给 app 一个「停表」信号（换视频 / 页面卸载 / 关掉设置）。
  function release(ended) {
    var v = tracked;
    if (!v) return;
    clearInterval(timer);
    timer = 0;
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
  function onEmptied() { release(true); }

  // 媒体事件不冒泡，capture 阶段在 document 上能收到所有 <video>（含后来插入的）。
  document.addEventListener('play', function (e) {
    var v = e.target;
    if (!v || v.tagName !== 'VIDEO') return;
    adopt(v);
  }, true);
  // 元数据晚于 play 到达（duration 从 NaN 变成真值）时补认。
  document.addEventListener('durationchange', function (e) {
    var v = e.target;
    if (!v || v.tagName !== 'VIDEO' || tracked || v.paused) return;
    adopt(v);
  }, true);
  document.addEventListener('pagehide', function () { release(true); });

  // 注入时已经在播的视频（扩展刚装 / 页面刷新后自动续播）。
  try {
    var vids = document.querySelectorAll('video');
    for (var i = 0; i < vids.length; i++) {
      if (!vids[i].paused && !vids[i].ended) { adopt(vids[i]); break; }
    }
  } catch (_) {}

  window.fushiStudyTracker = {
    looksLikeMainVideo: looksLikeMainVideo,
    get tracked() { return tracked; },
    get lastSentAt() { return lastSentAt; },
  };
})();
