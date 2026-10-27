// Fushi 内置网页播放器（WebView2，Windows）主世界胶水。
//
// 注入顺序（全部 document-start、主世界、同一全局作用域）：站点 bridge（netflix-bridge /
// stream-bridge / youtube-bridge，全部注入、各自按当前文档 host 自判）→ subtitle-adapters.js →
// subtitle-providers.js →（宿主开关）→ 本文件。前三样与浏览器扩展**逐字节同一份**（assets/browser_extension/ 镜像），本文件只做扩展里
// content.js/subtitle-panel.js 承担的「消费 store」那一半，并把它改成投给 Dart：
//   · window.fushiSubtitlePanelOnCues(key)  → 节流后整轨 {type:'track'} 投 Dart；
//   · 250ms 轮询 <video> 播放态                → 变化才 {type:'state'} 投 Dart；
//   · window.__fushiWebVideo.*                → Dart 经 evaluateJavascript 调的命令（seek/play/pause…）。
// 站点控制语义：Netflix 的 seek / 播放 / 暂停 / 倍速 / 音量 / 选轨一律走正片播放器 API（直接改
// currentTime 会 M7375；<video> 的状态在 seek 后滞后 1–2 s），会话选择只认 netflix-bridge 的
// fushiNetflixPlayer（`watch` 前缀）；其它站直接操作 <video>。
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
  // store key = `videoKey|语言段`；语言段带站点轨 id 时是 `lang~trackId`（subtitle-providers 的
  // fushiFullTrackLangSegment，Netflix 同语言普通 / CC 两条轨靠它区分）。
  function splitTrackKey(key) {
    var sep = key.indexOf('|');
    var seg = sep >= 0 ? key.slice(sep + 1) : 'und';
    var tilde = seg.indexOf('~');
    return {
      videoKey: sep >= 0 ? key.slice(0, sep) : key,
      lang: tilde >= 0 ? seg.slice(0, tilde) : seg,
      trackId: tilde >= 0 ? seg.slice(tilde + 1) : '',
    };
  }
  function flushTracks() {
    flushTimer = null;
    var store = window.fushiEpisodeCues || {};
    var keys = Object.keys(pendingKeys);
    pendingKeys = Object.create(null);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i];
      var parts = splitTrackKey(key);
      var cues = store[key] || [];
      // 按需加载的占位轨（providers 的 fushiLazyTracks，空 cue）只给浏览器扩展的菜单列轨用；
      // app 有自己的站点轨清单与加载态，投个空轨过去会被当成「已加载、0 句」。
      if (!cues.length && window.fushiLazyTracks && window.fushiLazyTracks[key]) continue;
      post({
        type: 'track',
        key: key,
        videoKey: parts.videoKey,
        lang: parts.lang,
        trackId: parts.trackId,
        cues: cues.map(function (c) { return { s: c.startMs, e: c.endMs, t: c.text }; }),
      });
    }
  }
  window.fushiSubtitlePanelOnCues = function (key) {
    if (!key) return;
    pendingKeys[String(key)] = true;
    if (!flushTimer) flushTimer = setTimeout(flushTracks, 250);
  };
  // 站点整轨抓取失败（netflix-bridge 的 cuesFailed）：确定的失败回执，Dart 把「加载中」落成失败。
  window.fushiSubtitlePanelOnTrackFailed = function (key, err) {
    if (!key) return;
    var parts = splitTrackKey(String(key));
    post({
      type: 'trackFailed',
      key: String(key),
      videoKey: parts.videoKey,
      lang: parts.lang,
      trackId: parts.trackId,
      err: String(err || ''),
    });
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
  // Netflix 的播放位置 / 暂停态以它自己的播放器 API 为准：<video>.currentTime 在 seek 后要 1–2 s
  // 才跟上（MSE 重新缓冲），按它上报会把刚跳过去的进度条拽回旧位置；暂停同理。拿不到正片播放器
  // （不是播放页 / API 改了）才退回 <video>。
  function playbackClock(v) {
    var p = nfPlayer();
    if (p) {
      try {
        var t = Number(p.getCurrentTime());
        var paused = !!p.isPaused();
        var d = Number(p.getDuration());
        if (isFinite(t)) {
          return {
            t: Math.round(t),
            paused: paused,
            dur: isFinite(d) && d > 0 ? Math.round(d) : null,
          };
        }
      } catch (_) {}
    }
    return {
      t: v ? Math.round(v.currentTime * 1000) : null,
      paused: v ? !!v.paused : true,
      dur: v && isFinite(v.duration) ? Math.round(v.duration * 1000) : null,
    };
  }
  function snapshot() {
    var v = video();
    var clock = playbackClock(v);
    var dur = clock.dur;
    return {
      type: 'state',
      href: location.href,
      videoKey: videoKey(),
      hasVideo: !!v,
      t: clock.t,
      paused: clock.paused,
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
      nfat: v ? netflixAudioTracks() : '',
      blk: v ? playbackBlocker(v) : '',
    };
  }
  // ── 播放被站点打断（P0-3）：「还在看吗？」/ 播放错误页（M7375 之类）/ <video> 自己报错。播放器档
  // 把页面除画面外全部藏起来、WebView 也不收输入，这些站点弹层用户既看不到也点不到——画面停住像
  // 黑屏。上报给 Dart，由它切回网页档让用户处理；弹层消失后自动回到播放器档。
  // 形状：'' = 正常；'interrupt' = 等用户确认继续；'error' / 'error:<码>' = 播放错误。
  var NETFLIX_INTERRUPT_SELECTORS =
    '[data-uia="interrupt-autoplay-continue"],[data-uia="interrupter"],.watch-video--interrupter,' +
    '.interrupter-container';
  var NETFLIX_ERROR_SELECTORS =
    '[data-uia="player-error"],[data-uia="error-page"],.nfp-fatal-error-view,.watch-video--error,' +
    '.player-error-view';
  function errorCodeIn(text) {
    var m = /\b([A-Z]{1,2}\d{3,5}(?:-\d+)?)\b/.exec(String(text || ''));
    return m ? m[1] : '';
  }
  function playbackBlocker(v) {
    try {
      // 只认 Netflix：YouTube 广告前后会换 / 重建 <video>，旧元素可能挂着 error 而正片照常播。
      if (location.hostname.indexOf('netflix.com') < 0) return '';
      if (v && v.error) return 'error:MEDIA_ERR_' + v.error.code;
      if (document.querySelector(NETFLIX_INTERRUPT_SELECTORS)) return 'interrupt';
      var err = document.querySelector(NETFLIX_ERROR_SELECTORS);
      if (err) {
        var code = errorCodeIn(err.textContent);
        return code ? 'error:' + code : 'error';
      }
    } catch (_) {}
    return '';
  }
  // ── Netflix 字幕轨（Netflix 的字幕采集是被动的：只截播放器自己下载的那一条轨。播放器档里用户
  // 够不到 Netflix 自己的字幕菜单，所以轨清单从播放器 API 读出来交给 Dart 列在原生面板里，选哪条
  // 就让播放器切到哪条——它随即下载那条字幕文件，netflix-bridge 照常截下整轨）。
  // 形状：每轨一行 `trackId\tbcp47\t显示名\t轨类型\t图片轨(1/0)`，末行 `#当前轨 trackId`（字幕关着
  // 为空）。用字符串而不是数组，快照才能按值比较、不每轮重发。图片字幕截不到文字，照样列出（标 1），
  // Dart 侧标「不可查词」、选它时让站点自己的字幕显示出来。
  // 正片播放器会话的选择判据只在 netflix-bridge.js 写一次（`watch` 前缀，没有就是没有）。
  function nfPlayer() {
    try {
      if (typeof window.fushiNetflixPlayer === 'function') return window.fushiNetflixPlayer();
    } catch (_) {}
    return null;
  }
  function trackRows(list, cur, skip) {
    var rows = [];
    for (var i = 0; i < list.length; i++) {
      var t = list[i];
      if (!t || skip(t)) continue;
      rows.push([
        t.trackId,
        t.bcp47 || t.language || 'und',
        String(t.displayName || '').replace(/[\t\n]/g, ' '),
        String(t.trackType || t.rawTrackType || ''),
        t.isImageBased ? '1' : '0',
      ].join('\t'));
    }
    rows.push('#' + (cur && !cur.isNoneTrack ? cur.trackId : ''));
    return rows.join('\n');
  }
  function netflixTextTracks() {
    if (location.hostname.indexOf('netflix.com') < 0) return '';
    var p = nfPlayer();
    if (!p) return '';
    try {
      return trackRows(p.getTimedTextTrackList() || [], p.getTimedTextTrack(), function (t) {
        return t.isNoneTrack || t.isForcedNarrative;
      });
    } catch (_) { return ''; }
  }
  // 音轨（同一形状，末行当前音轨）：站点播放器的音轨菜单被藏起来了，切换交给 Fushi 的音轨菜单。
  function netflixAudioTracks() {
    if (location.hostname.indexOf('netflix.com') < 0) return '';
    var p = nfPlayer();
    if (!p || typeof p.getAudioTrackList !== 'function') return '';
    try {
      return trackRows(p.getAudioTrackList() || [], p.getAudioTrack(), function (t) {
        return t.isNoneTrack;
      });
    } catch (_) { return ''; }
  }
  function selectTrackIn(list, trackId, apply) {
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].trackId === trackId) { apply(list[i]); return true; }
    }
    return false;
  }
  // 空串 = 关掉站点字幕（选 none 轨）：制卡重放期间截帧不能带字幕，结束后原样还回去。
  function selectNetflixTrack(trackId) {
    var p = nfPlayer();
    if (!p) return false;
    try {
      var list = p.getTimedTextTrackList() || [];
      if (trackId === '') {
        for (var i = 0; i < list.length; i++) {
          if (list[i] && list[i].isNoneTrack) { p.setTimedTextTrack(list[i]); return true; }
        }
        return false;
      }
      return selectTrackIn(list, trackId, function (t) { p.setTimedTextTrack(t); });
    } catch (_) {}
    return false;
  }
  function selectNetflixAudioTrack(trackId) {
    var p = nfPlayer();
    if (!p || typeof p.getAudioTrackList !== 'function') return false;
    try {
      return selectTrackIn(p.getAudioTrackList() || [], trackId, function (t) { p.setAudioTrack(t); });
    } catch (_) {}
    return false;
  }
  // 剧集 / 片头片尾标记（P2-2）：Netflix 网站自己用的 shakti metadata 接口，页面同源、带登录 cookie。
  // build id 取自页面的 reactContext。原文整份交给 Dart 解析（解析逻辑在 Dart 侧有单测）。
  function netflixBuildId() {
    try {
      var d = window.netflix.reactContext.models.serverDefs.data;
      return String(d.BUILD_IDENTIFIER || '');
    } catch (_) { return ''; }
  }
  // 候选接口按序试：Netflix 网站现在走 `memberapi/release`；旧的按 build id 拼的路径对现网返回
  // 502（2026-10-27 用户日志 `netflix metadata … failed: HTTP 502`，BUG-3801），留作退路。
  function netflixMetadataUrls(id) {
    var urls = ['/nq/website/memberapi/release/metadata?movieid=' + id];
    var build = netflixBuildId();
    if (build) {
      urls.push('/nq/website/memberapi/' + encodeURIComponent(build) + '/metadata?movieid=' + id);
    }
    return urls;
  }
  function fetchNetflixMetadata(movieId) {
    var id = String(movieId || '').replace(/\D/g, '');
    if (!id) {
      post({ type: 'nfMeta', movieId: id, ok: false, err: 'no movie id' });
      return false;
    }
    var urls = netflixMetadataUrls(id);
    var errors = [];
    function attempt(i) {
      if (i >= urls.length) {
        post({ type: 'nfMeta', movieId: id, ok: false, err: errors.join('; ') });
        return;
      }
      var url = urls[i];
      fetch(url, { credentials: 'include' })
        .then(function (r) {
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.text();
        })
        .then(function (text) { post({ type: 'nfMeta', movieId: id, ok: true, text: text }); })
        .catch(function (e) {
          errors.push(url.split('?')[0] + ' ' + String(e?.message || e));
          attempt(i + 1);
        });
    }
    try {
      attempt(0);
    } catch (e) {
      post({ type: 'nfMeta', movieId: id, ok: false, err: String(e) });
      return false;
    }
    return true;
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
    healNativeSubtitlesHidden();
    var s = snapshot();
    if (same(last, s)) return;
    last = s;
    post(s);
  }
  try { setInterval(sample, 250); } catch (_) {}
  try { document.addEventListener('fullscreenchange', sample); } catch (_) {}

  // seek 完成回执 → Dart（[WebVideoPlatformPlayer] 据此结束「跳转在途」）。Netflix 由 netflix-bridge
  // 轮询播放器时间收敛后回（超时回 ok:false）；其它站点由 <video> 的 seeked 事件回。id 原样回显。
  function postSeekDone(ok, err, id) {
    post({ type: 'seekDone', ok: !!ok, err: String(err || ''), id: id == null ? null : Number(id) });
  }
  window.addEventListener('message', function (e) {
    if (e.source !== window || !e.data || e.data.__fushiNf !== 'seekDone') return;
    postSeekDone(e.data.ok, e.data.err, e.data.id);
  });

  // document-start 时 <head> / <html> 可能都还没有：等根元素出现再挂（一次性观察）。
  function appendStyleEarly(el) {
    var root = document.head || document.documentElement;
    if (root) { root.appendChild(el); return; }
    try {
      var mo = new MutationObserver(function () {
        var r = document.head || document.documentElement;
        if (!r) return;
        mo.disconnect();
        if (!el.isConnected) r.appendChild(el);
      });
      mo.observe(document, { childList: true, subtree: true });
    } catch (_) {}
  }

  // ── 站点原生字幕隐藏：visibility 而非 display——DOM 采样 live 轨要继续读到文本 ──
  // Netflix 的图片字幕（日文竖排 / 注音轨常是图片）画在 .image-based-timed-text 里，与文字轨不同层。
  var HIDE_NATIVE_ID = 'fushi-hide-native-subtitles';
  var HIDE_NATIVE_CSS =
    '.player-timedtext,.player-timedtext-text-container,.image-based-timed-text,' +
    '.ytp-caption-window-container,' +
    '.captions-text,.bpx-player-subtitle-wrap,.vjs-text-track-display,.shaka-text-container' +
    '{visibility:hidden !important}';
  // 宿主要的状态（不是 DOM 现状）：站点重建 <head> / 整块替换播放器时 <style> 可能被抹掉，每轮
  // 采样按它自愈。
  var nativeSubtitlesHidden = false;
  function setNativeSubtitlesHidden(hidden) {
    nativeSubtitlesHidden = !!hidden;
    var el = document.getElementById(HIDE_NATIVE_ID);
    if (hidden && !el) {
      el = document.createElement('style');
      el.id = HIDE_NATIVE_ID;
      el.textContent = HIDE_NATIVE_CSS;
      appendStyleEarly(el);
    } else if (!hidden && el) {
      el.remove();
    }
    return !!hidden;
  }
  function healNativeSubtitlesHidden() {
    if (nativeSubtitlesHidden && !document.getElementById(HIDE_NATIVE_ID)) setNativeSubtitlesHidden(true);
  }
  // 宿主在本脚本之前注入的开关（[loadWebVideoUserScripts] 的 hideNativeSubtitles）：在页面第一帧
  // 之前就藏，不等 onLoadStop（那时站点字幕早已显示过、SPA 换集也不再触发 onLoadStop）。
  if (window.__fushiHideNativeSubtitlesAtStart === true) setNativeSubtitlesHidden(true);
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
    appendStyleEarly(advisoryStyle);
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
  // [targetHeight]：YouTube 画质目标（见 applyQualityTarget），省略 = 沿用当前目标（自愈重入）。
  function setVideoOnly(on, targetHeight) {
    if (targetHeight !== undefined) qualityTargetHeight = normalizeQualityTarget(targetHeight);
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
    if (on) applyQualityTarget();
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
  // YouTube 画质目标：Fushi 设置「YouTube 画质」（与 mpv 路径同一个偏好）。0 = 自动 = 可用的
  // 最高档；非 0 = 不超过该高度的最高档（全都高于目标时取最低档）。
  var qualityTargetHeight = 0;
  var YT_QUALITY_HEIGHT = {
    highres: 4320, hd2880: 2880, hd2160: 2160, hd1440: 1440, hd1080: 1080,
    hd720: 720, large: 480, medium: 360, small: 240, tiny: 144
  };
  function normalizeQualityTarget(h) {
    var n = Math.round(Number(h) || 0);
    return n > 0 ? n : 0;
  }
  function pickYoutubeQuality(levels, target) {
    var known = [];
    for (var i = 0; i < (levels || []).length; i++) {
      if (YT_QUALITY_HEIGHT[levels[i]]) known.push(levels[i]);
    }
    if (!known.length) return null;
    known.sort(function (a, b) { return YT_QUALITY_HEIGHT[b] - YT_QUALITY_HEIGHT[a]; });
    if (!(target > 0)) return known[0];
    for (var k = 0; k < known.length; k++) {
      if (YT_QUALITY_HEIGHT[known[k]] <= target) return known[k];
    }
    return known[known.length - 1];
  }
  // YouTube 自动画质还会看带宽历史等，铺满之后再经播放器 API 锁到目标档（级别列表要等清单加载
  // 完才有，前 30 s 每 2 s 试一次）。其它站点不提供这类 API，靠容器铺满。
  var qualityTimer = null;
  function applyQualityTarget() {
    if (location.hostname.indexOf('youtube.com') < 0) return;
    var tries = 0;
    if (qualityTimer) clearInterval(qualityTimer);
    qualityTimer = setInterval(function () {
      tries++;
      var p = document.getElementById('movie_player');
      try {
        var levels = p && p.getAvailableQualityLevels ? p.getAvailableQualityLevels() : [];
        var want = pickYoutubeQuality(levels, qualityTargetHeight);
        if (want) {
          if (p.getPlaybackQuality() !== want) p.setPlaybackQualityRange(want, want);
          else { clearInterval(qualityTimer); qualityTimer = null; return; }
        }
      } catch (_) {}
      if (tries >= 15) { clearInterval(qualityTimer); qualityTimer = null; }
    }, 2000);
  }

  // ── Dart → 页面命令 ──
  window.__fushiWebVideo = {
    // 返回值是确定的结果码：'bridge' / 'direct' = 已发出、回执随后由 seekDone 送达；其它（'no-video'
    // / 'no-player'）= 没发出去，调用方立即结束「跳转在途」。
    seek: function (ms, id) {
      ms = Math.max(0, Math.round(Number(ms) || 0));
      if (site() === 'netflix') {
        // Netflix 必须走播放器 API（直接写 currentTime 会 M7375）；没有正片会话就不发。
        if (!nfPlayer()) return 'no-player';
        try { window.postMessage({ __fushiNf: 'seek', ms: ms, id: id }, '/'); } catch (_) {}
        return 'bridge';
      }
      var v = video();
      if (!v) return 'no-video';
      var onSeeked = function () {
        v.removeEventListener('seeked', onSeeked);
        postSeekDone(true, '', id);
      };
      v.addEventListener('seeked', onSeeked);
      v.currentTime = ms / 1000;
      return 'direct';
    },
    // 播放 / 暂停 / 倍速 / 音量：Netflix 走正片播放器 API（与 seek 同一通道，状态与它自己的控件一致），
    // 其它站点直接操作 <video>。返回 'ok' / 'no-video'；play 的异步拒绝（自动播放策略）补发 cmdFailed。
    play: function () {
      var p = nfPlayer();
      if (p) { try { p.play(); return 'ok'; } catch (e) { return 'error:' + e; } }
      var v = video();
      if (!v) return 'no-video';
      try {
        var r = v.play();
        if (r && r.catch) r.catch(function (e) { post({ type: 'cmdFailed', cmd: 'play', err: String(e && e.name || e) }); });
      } catch (e) { return 'error:' + e; }
      return 'ok';
    },
    pause: function () {
      var p = nfPlayer();
      if (p) { try { p.pause(); return 'ok'; } catch (e) { return 'error:' + e; } }
      var v = video();
      if (!v) return 'no-video';
      try { v.pause(); } catch (e) { return 'error:' + e; }
      return 'ok';
    },
    toggle: function () {
      var clock = playbackClock(video());
      return clock.paused ? this.play() : this.pause();
    },
    setRate: function (r) {
      r = Math.min(4, Math.max(0.25, Number(r) || 1));
      var p = nfPlayer();
      if (p && typeof p.setPlaybackRate === 'function') { try { p.setPlaybackRate(r); return r; } catch (_) {} }
      var v = video();
      if (!v) return 1;
      v.playbackRate = r;
      return v.playbackRate;
    },
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
    // 播放中改「YouTube 画质」：记下目标，播放器档里当场重选。
    setQualityTarget: function (h) {
      qualityTargetHeight = normalizeQualityTarget(h);
      if (videoOnlyOn) applyQualityTarget();
      return 'ok';
    },
    selectNetflixTrack: selectNetflixTrack,
    selectNetflixAudioTrack: selectNetflixAudioTrack,
    fetchNetflixMetadata: fetchNetflixMetadata,
    // 原生播放器的音量控件（站点自己的音量键被藏起来了）：音量 0–1 + 静音一次设定。
    setVolume: function (volume, muted) {
      var vol = Math.max(0, Math.min(1, Number(volume) || 0));
      var p = nfPlayer();
      if (p && typeof p.setVolume === 'function' && typeof p.setMuted === 'function') {
        try { p.setVolume(vol); p.setMuted(!!muted); return 'ok'; } catch (_) {}
      }
      var v = video();
      if (!v) return 'no-video';
      v.volume = vol;
      v.muted = !!muted;
      return 'ok';
    },
    state: function () { var s = snapshot(); last = s; return JSON.stringify(s); },
  };
})();
