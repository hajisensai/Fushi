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

  // ── 广告（YouTube 片头 / 中插）：能跳就点「跳过」，不能跳就静音 16 倍速放完，结束后还原
  // 静音与倍速。广告期间快照带 ad: true，Dart 侧盖黑屏、不把广告的时间轴当正片。──
  function adShowing() {
    if (location.hostname.indexOf('youtube.com') < 0) return false;
    var p = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
    return !!(p && p.classList && p.classList.contains('ad-showing'));
  }
  var adRestore = null;
  function handleAds() {
    var ad = adShowing();
    if (!ad && !adRestore) return; // 绝大多数调用（class 变化）在这里就结束
    var v = video();
    if (ad && v) {
      if (!adRestore) adRestore = { muted: !!v.muted, rate: v.playbackRate || 1 };
      try {
        var skip = document.querySelector(
          '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
        if (skip) skip.click();
      } catch (_) {}
      try { v.muted = true; } catch (_) {}
      // 真跳过：广告片段直接拖到结尾（不可跳过的广告也一样），YouTube 随即进下一条广告 / 正片。
      // 时长还没就绪（元数据未到）时先 16 倍速顶着，下一轮再拖。
      try {
        if (isFinite(v.duration) && v.duration > 0 && v.currentTime < v.duration - 0.1) {
          v.currentTime = v.duration;
        } else if (v.playbackRate < 16) {
          v.playbackRate = 16;
        }
      } catch (_) {}
    } else if (!ad && adRestore) {
      try { if (v) { v.muted = adRestore.muted; v.playbackRate = adRestore.rate; } } catch (_) {}
      adRestore = null;
      healVideoOnly();
    }
  }
  try { setInterval(handleAds, 250); } catch (_) {}
  // 广告一挂上就处理，不等下一轮轮询（player 的 class 变化 + 广告片段元数据到达）。
  try {
    new MutationObserver(handleAds).observe(document.documentElement, {
      subtree: true, attributes: true, attributeFilter: ['class'],
    });
    document.addEventListener('loadedmetadata', handleAds, true);
  } catch (_) {}

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
      // 音量 / 静音 / 缓冲：原生播放器控件（media_kit player.state）的真相源是页面。
      vol: v ? v.volume : 1,
      muted: v ? !!v.muted : false,
      buf: v ? (!!v.seeking || (!v.paused && v.readyState < 3)) : false,
      fs: !!document.fullscreenElement,
      title: document.title,
      ad: adShowing(),
      vtitle: v ? videoTitle() : '',
      vimg: v ? pageImage() : '',
      nftt: v ? netflixTextTracks() : '',
    };
  }
  // ── Netflix 字幕轨（Netflix 的字幕采集是被动的：只截播放器自己下载的那一条轨。播放器档里用户
  // 够不到 Netflix 自己的字幕菜单，所以轨清单从播放器 API 读出来交给 Dart 列在原生面板里，选哪条
  // 就让播放器切到哪条——它随即下载那条字幕文件，netflix-bridge 照常截下整轨）。
  // 形状：每轨一行 `trackId\tbcp47\t显示名`，末行 `#当前轨 trackId`（字幕关着为空）。用字符串
  // 而不是数组，快照才能按值比较、不每轮重发。图片字幕截不到文字，不列。
  function nfPlayer() {
    try {
      var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
      var ids = vp.getAllPlayerSessionIds();
      return ids && ids.length ? vp.getVideoPlayerBySessionId(ids[ids.length - 1]) : null;
    } catch (_) { return null; }
  }
  function netflixTextTracks() {
    if (location.hostname.indexOf('netflix.com') < 0) return '';
    var p = nfPlayer();
    if (!p) return '';
    try {
      var list = p.getTimedTextTrackList() || [];
      var rows = [];
      for (var i = 0; i < list.length; i++) {
        var t = list[i];
        if (!t || t.isNoneTrack || t.isForcedNarrative || t.isImageBased) continue;
        rows.push([t.trackId, t.bcp47 || t.language || 'und', t.displayName || ''].join('\t'));
      }
      var cur = p.getTimedTextTrack();
      rows.push('#' + (cur && !cur.isNoneTrack ? cur.trackId : ''));
      return rows.join('\n');
    } catch (_) { return ''; }
  }
  function selectNetflixTrack(trackId) {
    var p = nfPlayer();
    if (!p) return false;
    try {
      var list = p.getTimedTextTrackList() || [];
      for (var i = 0; i < list.length; i++) {
        if (list[i] && list[i].trackId === trackId) { p.setTimedTextTrack(list[i]); return true; }
      }
    } catch (_) {}
    return false;
  }
  // 正在播的这一集的真名（落库的书名）：站点播放器自己的数据优先，document.title 在 SPA
  // 换集后常常还停在站名上。
  function videoTitle() {
    try {
      var host = location.hostname;
      if (host.indexOf('youtube.com') >= 0) {
        var p = document.getElementById('movie_player');
        var d = p && p.getVideoData ? p.getVideoData() : null;
        if (d && d.title) return String(d.title);
        var h = document.querySelector('h1.ytd-watch-metadata yt-formatted-string, h1.title');
        if (h && h.textContent.trim()) return h.textContent.trim();
      }
      if (host.indexOf('netflix.com') >= 0) {
        var t = document.querySelector('[data-uia="video-title"]');
        if (t) {
          var parts = [];
          for (var i = 0; i < t.children.length; i++) {
            var s = (t.children[i].textContent || '').trim();
            if (s) parts.push(s);
          }
          var joined = parts.length ? parts.join(' · ') : (t.textContent || '').trim();
          if (joined) return joined;
        }
      }
      var og = document.querySelector('meta[property="og:title"]');
      if (og && og.content) return String(og.content).trim();
    } catch (_) {}
    return '';
  }
  function pageImage() {
    try {
      var og = document.querySelector('meta[property="og:image"]');
      if (og && og.content) return new URL(og.content, location.href).href;
    } catch (_) {}
    return '';
  }
  function same(a, b) {
    if (!a || !b) return false;
    for (var k in b) { if (b[k] !== a[k]) return false; }
    return true;
  }
  function sample() {
    healVideoOnly();
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

  // ── Netflix 年龄分级/内容提示 overlay（左上角 "RATED 13+ / 暴力, 自杀"）：常驻隐藏 ──
  // BUG-2260：2026-09-08 用登录态 WebView2 探针实测，当前 DOM 是
  //   div.watch-video--advisories-container > div.advisory-container > div.advisory >
  //   [data-uia="advisory-content"] > h4.advisory-header
  // 旧的 .watch-video--evidence-overlay-container / *maturity* 选择器一个都不再命中（静默失效）。
  // Netflix 在开播和 seek 后都会重弹，制卡逐句 seek 时每张卡都可能撞上，所以不只在录制期藏，
  // 而是 document-start 就常驻藏（本文件每份文档都重新注入，整页换集也不会丢）。
  // 旧选择器保留作兜底，Netflix 回滚类名时仍生效。
  var NETFLIX_ADVISORY_SELECTORS =
    '.watch-video--advisories-container,[class*="watch-video--advisories"],' +
    '.watch-video--evidence-overlay-container';
  var HIDE_ADVISORY_ID = 'fushi-web-video-hide-advisory';
  if (site() === 'netflix' && !document.getElementById(HIDE_ADVISORY_ID)) {
    var advisoryStyle = document.createElement('style');
    advisoryStyle.id = HIDE_ADVISORY_ID;
    advisoryStyle.textContent = NETFLIX_ADVISORY_SELECTORS + '{display:none !important}';
    (document.head || document.documentElement).appendChild(advisoryStyle);
  }

  // 制卡重放期间隐藏站点播放器 chrome（进度条 / 按钮 / 顶栏）：Dart 驱动的 seek/pause 会让
  // 控件浮出来，cue 中点截的封面就带一条控制栏。只藏 chrome 不藏 <video>；字幕层另有开关。
  // 注意：这段 <style> 属于当前文档，整页导航（换集 loadUrl）后就没了——Dart 侧 onLoadStop
  // 必须按 _mineRunning 重挂（BUG-2260 第二根因），与 setNativeSubtitlesHidden 同款。
  var HIDE_CHROME_ID = 'fushi-web-video-hide-chrome';
  var HIDE_CHROME_CSS =
    '.watch-video--bottom-controls-container,.watch-video--back-container,' +
    '.watch-video--flag-container,' + NETFLIX_ADVISORY_SELECTORS + ',' +
    '[data-uia="player-controls"],[data-uia="controls-standard"],' +
    '.ytp-chrome-bottom,.ytp-chrome-top,.ytp-gradient-bottom,.ytp-gradient-top,' +
    '.bpx-player-control-wrap,.bpx-player-sending-bar,.vjs-control-bar,.shaka-controls-container' +
    '{visibility:hidden !important}';
  function setPlayerChromeHidden(hidden) {
    var el = document.getElementById(HIDE_CHROME_ID);
    if (hidden && !el) {
      el = document.createElement('style');
      el.id = HIDE_CHROME_ID;
      el.textContent = HIDE_CHROME_CSS;
      (document.head || document.documentElement).appendChild(el);
    } else if (!hidden && el) {
      el.remove();
    }
    return !!hidden;
  }

  // 底层合成（Flutter 画在 WebView 上面，界面全归 Fushi）：页面只留画面——最大的 <video>
  // 固定铺满视口、按比例黑边，其余元素一律 visibility:hidden（不动布局，站点脚本照常跑）。
  var VIDEO_ONLY_ID = 'fushi-video-only-style';
  var VIDEO_ONLY_ATTR = 'data-fushi-video-only';
  // 视频的祖先链（不含 html/body）也铺满视口：站点播放器按容器尺寸选码率（YouTube 自动画质、
  // 网飞阶梯），容器还是原来那块小框就只给 720p。
  var VIDEO_CHAIN_ATTR = 'data-fushi-video-chain';
  var VIDEO_ONLY_CSS =
    '[' + VIDEO_CHAIN_ATTR + '] { position: fixed !important; inset: 0 !important; left: 0 !important;' +
    ' top: 0 !important; width: 100vw !important; height: 100vh !important; max-width: none !important;' +
    ' max-height: none !important; min-width: 0 !important; min-height: 0 !important;' +
    ' transform: none !important; margin: 0 !important; padding: 0 !important; }' +
    'html, body { background: #000 !important; overflow: hidden !important; }' +
    'body * { visibility: hidden !important; }' +
    'video[' + VIDEO_ONLY_ATTR + '] { visibility: visible !important; position: fixed !important;' +
    ' inset: 0 !important; left: 0 !important; top: 0 !important; width: 100vw !important;' +
    ' height: 100vh !important; max-width: none !important; max-height: none !important;' +
    ' object-fit: contain !important; transform: none !important; margin: 0 !important;' +
    ' z-index: 2147483647 !important; background: #000 !important; }';
  // 主画面：正在播的优先（广告结束后 YouTube 可能换 / 重建 <video>，旧元素还留着最后一帧的
  // 尺寸），其次有画面尺寸的，再按面积。
  function mainVideo() {
    var vs = document.querySelectorAll('video');
    var best = null, bestScore = -1;
    for (var i = 0; i < vs.length; i++) {
      var v = vs[i];
      var area = v.videoWidth * v.videoHeight;
      var score = (!v.paused && !v.ended ? 4 : 0) + (v.readyState > 0 ? 2 : 0) + (area > 0 ? 1 : 0);
      if (score > bestScore || (score === bestScore && area > best.videoWidth * best.videoHeight)) {
        best = v; bestScore = score;
      }
    }
    return best;
  }
  var videoOnlyOn = false;
  // 标记 v 及其祖先链；返回是否真改了标记。
  function markVideoOnly(v) {
    var changed = false;
    var marked = document.querySelectorAll('video[' + VIDEO_ONLY_ATTR + ']');
    for (var i = 0; i < marked.length; i++) {
      if (marked[i] !== v) { marked[i].removeAttribute(VIDEO_ONLY_ATTR); changed = true; }
    }
    if (v && !v.hasAttribute(VIDEO_ONLY_ATTR)) { v.setAttribute(VIDEO_ONLY_ATTR, ''); changed = true; }
    var want = [];
    for (var p = v && v.parentElement; p && p !== document.body && p !== document.documentElement; p = p.parentElement) {
      want.push(p);
    }
    var chain = document.querySelectorAll('[' + VIDEO_CHAIN_ATTR + ']');
    for (var c = 0; c < chain.length; c++) {
      if (want.indexOf(chain[c]) < 0) { chain[c].removeAttribute(VIDEO_CHAIN_ATTR); changed = true; }
    }
    for (var w = 0; w < want.length; w++) {
      if (!want[w].hasAttribute(VIDEO_CHAIN_ATTR)) { want[w].setAttribute(VIDEO_CHAIN_ATTR, ''); changed = true; }
    }
    return changed;
  }
  function setVideoOnly(on) {
    videoOnlyOn = !!on;
    var v = on ? mainVideo() : null;
    markVideoOnly(v);
    var el = document.getElementById(VIDEO_ONLY_ID);
    if (on && !el) {
      el = document.createElement('style');
      el.id = VIDEO_ONLY_ID;
      el.textContent = VIDEO_ONLY_CSS;
      (document.head || document.documentElement).appendChild(el);
    } else if (!on && el) {
      el.remove();
    }
    // 播放器按 resize 重新量容器、重新选码率。
    try { window.dispatchEvent(new Event('resize')); } catch (_) {}
    if (on) preferHighestQuality();
    setAutoAdvanceGuard(on);
    return !!v;
  }
  // 只留画面期间标记自愈：站点换了 / 重建了 <video>（YouTube 广告结束换回正片、SPA 换集）或
  // 抹掉了属性 / 样式，新画面会落在「body * 一律隐藏」里 = 黑屏。每轮核对、不对就重标。
  function healVideoOnly() {
    if (!videoOnlyOn) return;
    var v = mainVideo();
    if (!v) return;
    var styleGone = !document.getElementById(VIDEO_ONLY_ID);
    if (markVideoOnly(v) || styleGone) setVideoOnly(true);
  }
  // 站点自己的「自动连播」（YouTube autonav、网飞片尾倒计时进下一集）在 Fushi 里不该发生：
  // 下一集由 Fushi 决定。藏起来的控件 click() 照样生效。
  var autoAdvanceTimer = null;
  function setAutoAdvanceGuard(on) {
    if (autoAdvanceTimer) { clearInterval(autoAdvanceTimer); autoAdvanceTimer = null; }
    if (!on) return;
    autoAdvanceTimer = setInterval(function () {
      try {
        var yt = document.querySelector('.ytp-autonav-toggle-button[aria-checked="true"]');
        if (yt) yt.click();
        var nf = document.querySelector('[data-uia="watch-credits-seamless-button"]');
        if (nf) nf.click();
      } catch (_) {}
    }, 1000);
  }
  // YouTube 自动画质还会看带宽历史等，铺满之后再经播放器 API 锁到可用的最高档（级别列表要等
  // 清单加载完才有，前 30 s 每 2 s 试一次）。其它站点不提供这类 API，靠容器铺满。
  var qualityTimer = null;
  function preferHighestQuality() {
    if (location.hostname.indexOf('youtube.com') < 0) return;
    var tries = 0;
    if (qualityTimer) clearInterval(qualityTimer);
    qualityTimer = setInterval(function () {
      tries++;
      var p = document.getElementById('movie_player');
      try {
        var levels = p && p.getAvailableQualityLevels ? p.getAvailableQualityLevels() : [];
        if (levels && levels.length) {
          if (p.getPlaybackQuality() !== levels[0]) p.setPlaybackQualityRange(levels[0], levels[0]);
          else { clearInterval(qualityTimer); qualityTimer = null; return; }
        }
      } catch (_) {}
      if (tries >= 15) { clearInterval(qualityTimer); qualityTimer = null; }
    }, 2000);
  }

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
    setPlayerChromeHidden: setPlayerChromeHidden,
    setVideoOnly: setVideoOnly,
    selectNetflixTrack: selectNetflixTrack,
    // 原生播放器的音量控件（站点自己的音量键被藏起来了）：音量 0–1 + 静音一次设定。
    setVolume: function (volume, muted) {
      var v = video();
      if (!v) return 'no-video';
      v.volume = Math.max(0, Math.min(1, Number(volume) || 0));
      v.muted = !!muted;
      return 'ok';
    },
    state: function () { var s = snapshot(); last = s; return JSON.stringify(s); },
  };
})();
