// Fushi 内置网页播放器（WebView2，Windows）主世界胶水。
//
// 注入顺序（全部 document-start、主世界、同一全局作用域）：站点 bridge（netflix-bridge /
// stream-bridge / youtube-bridge，按 host 选）→ subtitle-adapters.js → subtitle-providers.js →
// 本文件。前三样与浏览器扩展**逐字节同一份**（assets/browser_extension/ 镜像），本文件只做扩展里
// content.js/subtitle-panel.js 承担的「消费 store」那一半，并把它改成投给 Dart：
//   · window.fushiSubtitlePanelOnCues(key)  → 节流后整轨 {type:'track'} 投 Dart；
//   · 250ms 轮询 <video> 播放态                → 变化才 {type:'state'} 投 Dart；
//   · window.__fushiWebVideo.*                → Dart 经 evaluateJavascript 调的命令（seek/play/pause…）。
// 站点 seek 语义沿用扩展：Netflix 走 netflix-bridge 的官方播放器 API（直接改 currentTime 会 M7375），
// 其它站直接写 video.currentTime。
(function () {
  if (window.__fushiWebVideoGlue) return;
  window.__fushiWebVideoGlue = true;

  var HANDLER = 'fushiWebVideo';
  var queued = [];

  function bridge() {
    try {
      var b = window.flutter_inappwebview;
      return b && typeof b.callHandler === 'function' ? b : null;
    } catch (_) { return null; }
  }
  // 桥未就绪时先排队（Dart 侧 handler 在 onWebViewCreated 注册，早于任何导航；这里只是防御）。
  function post(msg) {
    var b = bridge();
    if (!b) { queued.push(msg); if (queued.length > 200) queued.shift(); return; }
    while (queued.length) { try { b.callHandler(HANDLER, queued.shift()); } catch (_) {} }
    try { b.callHandler(HANDLER, msg); } catch (_) {}
  }

  function site() {
    try { if (typeof fushiSite === 'function') return fushiSite(); } catch (_) {}
    var h = location.hostname;
    return h.endsWith('netflix.com') ? 'netflix' : 'other';
  }
  function video() { return document.querySelector('video'); }
  function videoKey() {
    try { if (typeof window.fushiVideoKey === 'function') return String(window.fushiVideoKey() || ''); } catch (_) {}
    return (location.hostname + location.pathname).replace(/\|/g, '_');
  }

  // ── store → Dart：同一轨 250ms 内多次变化（DOM 采样逐字扩长 / textTracks 归并）合并成一次整轨投递 ──
  var pendingKeys = Object.create(null);
  var flushTimer = null;
  function flushTracks() {
    flushTimer = null;
    var store = window.fushiEpisodeCues || {};
    var keys = Object.keys(pendingKeys);
    pendingKeys = Object.create(null);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      var sep = key.indexOf('|');
      var cues = store[key] || [];
      post({
        type: 'track',
        key: key,
        videoKey: sep >= 0 ? key.slice(0, sep) : key,
        lang: sep >= 0 ? key.slice(sep + 1) : 'und',
        cues: cues.map(function (c) { return { s: c.startMs, e: c.endMs, t: c.text }; }),
      });
    }
  }
  window.fushiSubtitlePanelOnCues = function (key) {
    if (!key) return;
    pendingKeys[String(key)] = true;
    if (!flushTimer) flushTimer = setTimeout(flushTracks, 250);
  };

  // ── 播放态轮询（与扩展面板同为轮询，站点播放器不保证派发 timeupdate）──
  var last = null;
  function snapshot() {
    var v = video();
    var dur = v && isFinite(v.duration) ? Math.round(v.duration * 1000) : null;
    return {
      type: 'state',
      href: location.href,
      videoKey: videoKey(),
      hasVideo: !!v,
      t: v ? Math.round(v.currentTime * 1000) : null,
      paused: v ? !!v.paused : true,
      dur: dur,
      vw: v ? v.videoWidth : 0,
      vh: v ? v.videoHeight : 0,
      rate: v ? v.playbackRate : 1,
      fs: !!document.fullscreenElement,
      title: document.title,
    };
  }
  function same(a, b) {
    if (!a || !b) return false;
    for (var k in b) { if (b[k] !== a[k]) return false; }
    return true;
  }
  function sample() {
    var s = snapshot();
    if (same(last, s)) return;
    last = s;
    post(s);
  }
  try { setInterval(sample, 250); } catch (_) {}
  try { document.addEventListener('fullscreenchange', sample); } catch (_) {}

  // Netflix seek 完成回执（netflix-bridge 轮询播放器时间收敛后才回）→ 透传给 Dart。
  window.addEventListener('message', function (e) {
    if (e.source !== window || !e.data || e.data.__fushiNf !== 'seekDone') return;
    post({ type: 'seekDone', ok: !!e.data.ok, err: String(e.data.err || '') });
  });

  // ── 站点原生字幕隐藏：visibility 而非 display——DOM 采样 live 轨要继续读到文本 ──
  var HIDE_NATIVE_ID = 'fushi-hide-native-subtitles';
  var HIDE_NATIVE_CSS =
    '.player-timedtext,.player-timedtext-text-container,.ytp-caption-window-container,' +
    '.captions-text,.bpx-player-subtitle-wrap,.vjs-text-track-display,.shaka-text-container' +
    '{visibility:hidden !important}';
  function setNativeSubtitlesHidden(hidden) {
    var el = document.getElementById(HIDE_NATIVE_ID);
    if (hidden && !el) {
      el = document.createElement('style');
      el.id = HIDE_NATIVE_ID;
      el.textContent = HIDE_NATIVE_CSS;
      (document.head || document.documentElement).appendChild(el);
    } else if (!hidden && el) {
      el.remove();
    }
    return !!hidden;
  }
  // 全屏元素换了父节点时 <style> 仍在 head 里全局生效，无需迁移。

  // ── Dart → 页面命令 ──
  window.__fushiWebVideo = {
    seek: function (ms) {
      ms = Math.max(0, Math.round(Number(ms) || 0));
      if (site() === 'netflix') {
        try { window.postMessage({ __fushiNf: 'seek', ms: ms }, '/'); } catch (_) {}
        return 'bridge';
      }
      var v = video();
      if (!v) return 'no-video';
      v.currentTime = ms / 1000;
      return 'direct';
    },
    play: function () { var v = video(); if (!v) return false; try { var p = v.play(); if (p && p.catch) p.catch(function () {}); } catch (_) {} return true; },
    pause: function () { var v = video(); if (!v) return false; try { v.pause(); } catch (_) {} return true; },
    toggle: function () { var v = video(); if (!v) return false; return v.paused ? this.play() : this.pause(); },
    setRate: function (r) { var v = video(); if (!v) return 1; r = Math.min(4, Math.max(0.25, Number(r) || 1)); v.playbackRate = r; return v.playbackRate; },
    setVolume: function (vol) { var v = video(); if (!v) return 0; v.volume = Math.min(1, Math.max(0, Number(vol))); return v.volume; },
    toggleMute: function () { var v = video(); if (!v) return false; v.muted = !v.muted; return v.muted; },
    replayCues: function () {
      try { window.postMessage({ __fushiNf: 'replayCues' }, '/'); } catch (_) {}
      try { window.postMessage({ __fushiStream: 'replayCues' }, '/'); } catch (_) {}
      // 把 store 里已有的轨全部重投（Dart 侧页面重建 / 换集后重新拿全量）。
      var store = window.fushiEpisodeCues || {};
      for (var k in store) window.fushiSubtitlePanelOnCues(k);
      return Object.keys(store).length;
    },
    setNativeSubtitlesHidden: setNativeSubtitlesHidden,
    state: function () { var s = snapshot(); last = s; return JSON.stringify(s); },
  };
})();
