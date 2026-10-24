// Fushi 应用内浏览器 · YouTube 页面内可点字幕（取词走浏览页现有查词链路）。
//
// 注入顺序（同一个 document-start 脚本块里，按 YouTube 主机守卫，见
// lib/src/web_browser/features/youtube_subtitles/youtube_subtitles_scripts.dart）：
//   youtube-bridge.js → subtitle-adapters.js → subtitle-providers.js → 本文件。
// 前三样与浏览器扩展 / 内置网页播放器**逐字节同一份**（assets/browser_extension/ 镜像，由
// browser_extension_mirror_full_guard_test 守住），负责把 YouTube 整轨字幕抓进
// window.fushiEpisodeCues。本文件只做「消费 store」那一半：选一条轨，按 <video> 当前时间
// 把当前句画在播放器里，点字时调浏览页已装好的阅读器选区脚本（window.fushiSelection）取词，
// 由它照常投 callHandler('onTextSelected')。本脚本不查词、不改站点 DOM 的其它部分。
//
// 选轨与扩展同一份共享纯函数（subtitle-adapters.js，见下「选轨」）；cueAt 挂在
// __fushiYtSubs._pure 供 node 测试。
(function () {
  'use strict';
  if (window.__fushiYtSubs) return;

  var EL_ID = 'fushi-yt-subtitle';
  var HIDE_NATIVE_ID = 'fushi-yt-hide-native-subtitles';
  // visibility 而非 display：providers 的 DOM 采样（live 轨）要继续读得到站点字幕文本。
  var HIDE_NATIVE_CSS =
    '.ytp-caption-window-container,.captions-text,.caption-window' +
    '{visibility:hidden !important}';
  var LIVE_LANG = 'live';
  var TAP_SLOP_PX = 12;

  var st = {
    // activeLang：活动轨的语言段（store key 的 `|` 之后，与扩展 subtitle-panel 的 st.activeLang 同义）。
    enabled: false, videoKey: '', activeLang: null, cues: [], cue: undefined, lazyRequestedAt: {},
    el: null, line: null, timer: null, downX: 0, downY: 0, down: false,
  };

  // ── 选轨：与浏览器扩展同一份规则 ──────────────────────────────────────
  // 列表次序与活动轨判据是扩展 subtitle-adapters.js 的共享纯函数 fushiListSubtitleTracks /
  // fushiResolveActiveSubtitleTrack（同一脚本块里先于本文件装入，字节一致镜像），扩展面板 /
  // Side Panel / 播放器内嵌菜单也调它们，这里不另写排序：
  //   已加载整轨在前 → 占位轨 → live；同档按语言段字典序；活动轨保持上次选中，没有就取第一条，
  //   live 遇整轨到达自动升级。先取哪条由 youtube-bridge 决定（当前音轨默认字幕轨 → 音轨同语言
  //   → 人工轨），它只急取头一条。没有语言偏好设置（扩展也没有）；想看别的轨，用户在「⋯ › 字幕轨」
  //   里换（= 扩展播放器菜单的轨页，trackList / selectTrack 与 fushiSubtitleTrackList /
  //   fushiSubtitleSelectTrack 同形）。换视频清掉选择（扩展 tick 换视频时 activeLang = null）。
  var LAZY_RETRY_MS = 5000; // 同一占位轨 5 秒内不重复请求（与扩展 requestLazyIfPending 同值）

  function listTracks() {
    if (typeof fushiListSubtitleTracks !== 'function') return [];
    return fushiListSubtitleTracks(window.fushiEpisodeCues || null, st.videoKey,
      window.fushiLazyTracks || null, LIVE_LANG);
  }

  function requestLazyIfPending(track) {
    if (!track || !track.pending || typeof window.fushiRequestLazyTrack !== 'function') return;
    var now = Date.now();
    if (now - (st.lazyRequestedAt[track.key] || 0) < LAZY_RETRY_MS) return;
    st.lazyRequestedAt[track.key] = now;
    try { window.fushiRequestLazyTrack(track.key); } catch (_) {}
  }

  // cues 按 startMs 升序（providers 保证）；取覆盖 ms 的那条。
  function cueAt(cues, ms) {
    if (!cues || !cues.length) return null;
    var lo = 0, hi = cues.length - 1, idx = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= ms) { idx = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (idx < 0) return null;
    var c = cues[idx];
    return c.endMs > ms ? c : null;
  }

  // ── DOM ─────────────────────────────────────────────────────────────────

  function videoEl() {
    return document.querySelector('video.html5-main-video') || document.querySelector('video');
  }

  function playerOf(video) {
    if (!video) return null;
    return (video.closest && video.closest('.html5-video-player')) ||
      document.getElementById('movie_player') || video.parentElement;
  }

  function currentVideoKey() {
    try {
      if (typeof window.fushiVideoKey === 'function') return String(window.fushiVideoKey() || '');
    } catch (_) {}
    return '';
  }

  function setNativeHidden(hidden) {
    var el = document.getElementById(HIDE_NATIVE_ID);
    if (hidden && !el) {
      el = document.createElement('style');
      el.id = HIDE_NATIVE_ID;
      el.textContent = HIDE_NATIVE_CSS;
      (document.head || document.documentElement).appendChild(el);
    } else if (!hidden && el) {
      el.remove();
    }
  }

  // 点按取词：浏览页的取词门控（window.__fushiSrsLookup，由 Dart 下发）关着、或查词弹窗开着时
  // 不取（弹窗开着时点按交给 Flutter 的 dismiss barrier）。
  function lookupAt(x, y) {
    var gate = window.__fushiSrsLookup || {};
    if (!gate.tap || gate.open) return;
    var sel = window.fushiSelection;
    if (sel && typeof sel.selectText === 'function') sel.selectText(x, y, 400, false);
  }

  // 字幕条上的指针事件不冒泡给播放器（否则点字同时暂停 / 唤出控件）；取词在这里直接做。
  function stop(e) { e.stopPropagation(); }
  function onPointerDown(e) {
    stop(e);
    if (e.pointerType === 'touch' || e.button !== 0) return;
    st.down = true; st.downX = e.clientX; st.downY = e.clientY;
  }
  function onPointerUp(e) {
    stop(e);
    if (e.pointerType === 'touch' || e.button !== 0 || !st.down) return;
    st.down = false;
    if (Math.abs(e.clientX - st.downX) > TAP_SLOP_PX ||
        Math.abs(e.clientY - st.downY) > TAP_SLOP_PX) return;
    var s = window.getSelection ? window.getSelection() : null;
    if (s && !s.isCollapsed && String(s).length > 0) return; // 拖选文字时不取词
    lookupAt(e.clientX, e.clientY);
  }
  function onTouchStart(e) {
    stop(e);
    var t = e.touches && e.touches[0];
    if (!t || e.touches.length !== 1) { st.down = false; return; }
    st.down = true; st.downX = t.clientX; st.downY = t.clientY;
  }
  function onTouchEnd(e) {
    stop(e);
    var t = e.changedTouches && e.changedTouches[0];
    if (!t || !st.down) return;
    st.down = false;
    if (Math.abs(t.clientX - st.downX) > TAP_SLOP_PX ||
        Math.abs(t.clientY - st.downY) > TAP_SLOP_PX) return;
    if (e.cancelable) e.preventDefault(); // 不再合成 click / mouse 事件
    lookupAt(t.clientX, t.clientY);
  }

  // 外观与几何对齐扩展的在页字幕覆盖层（content-css-overlay.css #fushi-subtitle-overlay 默认值 +
  // subtitle-panel.js placeOverlay）：字号 clamp(18px, 2.2vw, 32px) 随视口宽（手机竖屏全屏时播放器
  // 又窄又高，旧版按播放器高算字号，一句被撑成两大行盖住画面）；行宽从视频中心向两侧屏缘撑开、被
  // 近侧屏缘夹住，上限 94% 视口、下限 200px；底边锚在**视频矩形**高的 88%（不是播放器——竖屏
  // 全屏时播放器上下是黑边）。字幕层挂在播放器里，所以锚点折成相对播放器底边的 px。
  var FONT_SIZE_CSS = 'clamp(18px, 2.2vw, 32px)';
  var BOTTOM_ANCHOR = 0.88;

  function rectOf(node) {
    try {
      var r = node && node.getBoundingClientRect ? node.getBoundingClientRect() : null;
      return r && r.width > 0 && r.height > 0 ? r : null;
    } catch (_) { return null; }
  }

  // 纯几何：播放器矩形 pr、视频矩形 vr（缺省 = 播放器）、视口宽 vv → 行宽上限与底边距（px）。
  function overlayLayout(pr, vr, vv) {
    var box = vr || pr;
    if (!box) return null;
    if (!(vv > 0)) vv = box.left + box.right;
    var cx = box.left + box.width / 2;
    var halfToEdge = Math.max(0, Math.min(cx, vv - cx));
    var maxWidth = Math.max(200, Math.min(vv * 0.94, (halfToEdge - 6) * 2));
    var bottom = pr ? (pr.top + pr.height) - (box.top + box.height * BOTTOM_ANCHOR) : -1;
    return {
      maxWidth: Math.round(maxWidth),
      bottom: bottom >= 0 && pr && bottom <= pr.height ? Math.round(bottom) : -1,
    };
  }

  function ensureEl(player, video) {
    if (!st.el) {
      var el = document.createElement('div');
      el.id = EL_ID;
      var es = el.style;
      es.position = 'absolute'; es.left = '0'; es.right = '0';
      es.bottom = Math.round((1 - BOTTOM_ANCHOR) * 100) + '%';
      es.textAlign = 'center'; es.zIndex = '60'; es.pointerEvents = 'none';
      var line = document.createElement('span');
      var ls = line.style;
      ls.display = 'inline-block'; ls.pointerEvents = 'auto'; ls.cursor = 'text';
      ls.userSelect = 'text'; ls.webkitUserSelect = 'text'; ls.boxSizing = 'border-box';
      ls.color = '#f7f8f2'; ls.background = 'rgba(12,15,13,.72)'; ls.padding = '6px 12px 7px';
      ls.borderRadius = '8px'; ls.boxShadow = '0 2px 12px rgba(0,0,0,.42)';
      ls.textShadow = '0 1px 3px #000, 1px 0 2px #000, -1px 0 2px #000';
      ls.fontFamily = '"Hiragino Sans", "Yu Gothic UI", sans-serif';
      ls.fontSize = FONT_SIZE_CSS; ls.fontWeight = '600'; ls.fontStyle = 'normal';
      ls.lineHeight = '1.45'; ls.letterSpacing = '0.01em'; ls.whiteSpace = 'pre-wrap';
      line.addEventListener('pointerdown', onPointerDown);
      line.addEventListener('pointerup', onPointerUp);
      line.addEventListener('mousedown', stop);
      line.addEventListener('mouseup', stop);
      line.addEventListener('click', stop);
      line.addEventListener('dblclick', stop);
      line.addEventListener('touchstart', onTouchStart, { passive: true });
      line.addEventListener('touchend', onTouchEnd, { passive: false });
      el.appendChild(line);
      st.el = el; st.line = line;
    }
    if (player && st.el.parentNode !== player) player.appendChild(st.el);
    if (player) {
      var layout = overlayLayout(rectOf(player), rectOf(video), window.innerWidth || 0);
      if (layout) {
        st.line.style.maxWidth = layout.maxWidth + 'px';
        st.el.style.bottom = layout.bottom >= 0 ? layout.bottom + 'px'
          : Math.round((1 - BOTTOM_ANCHOR) * 100) + '%';
      }
    }
    return st.el;
  }

  function render(cue, player, video) {
    if (cue === st.cue) {
      if (cue && player) ensureEl(player, video); // 播放器换了节点 / 尺寸变了（进出全屏）
      return;
    }
    st.cue = cue;
    if (!cue || !player) {
      if (st.el && st.el.parentNode) st.el.parentNode.removeChild(st.el);
      return;
    }
    ensureEl(player, video);
    // 整句一个文本节点：阅读器选区脚本按文本节点取句子与词。
    st.line.textContent = String(cue.text || '');
  }

  function reselect() {
    var tracks = listTracks();
    var active = typeof fushiResolveActiveSubtitleTrack === 'function'
      ? fushiResolveActiveSubtitleTrack(tracks, st.activeLang, LIVE_LANG) : null;
    st.activeLang = active ? active.lang : null;
    requestLazyIfPending(active);
    st.cues = active ? active.cues : [];
    st.cue = undefined; // 强制重绘
    setNativeHidden(st.enabled && st.cues.length > 0);
    return tracks;
  }

  function tick() {
    if (!st.enabled) return;
    var key = currentVideoKey();
    if (key !== st.videoKey) { st.videoKey = key; st.activeLang = null; reselect(); }
    var video = videoEl();
    if (!video || !st.cues.length) { render(null, null); return; }
    render(cueAt(st.cues, Math.round(video.currentTime * 1000)), playerOf(video), video);
  }

  function setEnabled(on) {
    st.enabled = !!on;
    if (st.enabled) {
      var key = currentVideoKey();
      if (key !== st.videoKey) { st.videoKey = key; st.activeLang = null; }
      reselect();
      if (!st.timer) st.timer = setInterval(tick, 120);
      tick();
    } else {
      if (st.timer) { clearInterval(st.timer); st.timer = null; }
      render(null, null);
      setNativeHidden(false);
    }
    return st.enabled;
  }

  // 「⋯ › 字幕轨」的数据（与扩展 fushiSubtitleTrackList 同形；label 取站点显示名
  // window.fushiTrackLabels，live 轨的显示名由 Dart 本地化，这里给 null）。
  function trackList() {
    if (!st.videoKey) st.videoKey = currentVideoKey();
    var tracks = reselect();
    return {
      active: st.activeLang,
      tracks: tracks.map(function (t) {
        var labels = window.fushiTrackLabels || {};
        return {
          lang: t.lang,
          label: t.lang === LIVE_LANG ? null : (labels[t.key] || t.lang),
          live: t.lang === LIVE_LANG,
          length: t.cues.length,
          pending: !!t.pending,
        };
      }),
    };
  }

  // 用户选轨（与扩展 fushiSubtitleSelectTrack 同义）：轨不在 → false；在 → 设为活动轨，占位轨
  // 顺带请桥按需取。只在本视频内记住，换视频按规则重选。
  function selectTrack(lang) {
    var wanted = String(lang || '');
    if (!st.videoKey) st.videoKey = currentVideoKey();
    var tracks = listTracks();
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].lang === wanted) {
        st.activeLang = wanted;
        reselect();
        if (st.enabled) tick();
        return true;
      }
    }
    return false;
  }

  // providers 每到一条新轨 / 新句就调这个钩子（与扩展字幕面板、网页播放器 glue 同一契约）。
  var previousHook = window.fushiSubtitlePanelOnCues;
  window.fushiSubtitlePanelOnCues = function (key) {
    if (typeof previousHook === 'function') { try { previousHook(key); } catch (_) {} }
    if (st.enabled) reselect();
  };

  window.__fushiYtSubs = {
    setEnabled: setEnabled,
    trackList: trackList,
    selectTrack: selectTrack,
    state: function () {
      return {
        enabled: st.enabled, videoKey: st.videoKey, activeLang: st.activeLang, cues: st.cues.length,
        fontSize: FONT_SIZE_CSS,
        maxWidth: st.line ? st.line.style.maxWidth : '',
      };
    },
    _pure: { cueAt: cueAt, overlayLayout: overlayLayout },
  };
})();
