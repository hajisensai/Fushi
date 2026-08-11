// 通用字幕控制器（content script 隔离世界，manifest bundle 里排在 content.js 之后加载）。
// 它消费 window.fushiEpisodeCues 里按
// `${videoKey}|${lang}` 存档的字幕轨——Netflix 走整集拦截、原生 TextTrack 站点走 textTracks 收割、
// YouTube 优先走 MAIN-world captionTracks 整轨，拿不到时才走 DOM 采样 live 轨
//（provider 全在 content.js/youtube-bridge.js，控制器零站点特例）。
// 字幕列表本身由 manifest 的 side_panel 扩展页面渲染，本文件只提供轨数据与视频控制消息；
// 不再把列表挂到宿主网页 DOM，也不再改播放器宽度。行为：
//   · 时间戳点击 → Netflix（DRM）复用 P1 的 nfSeek（postMessage {__fushiNf:'seek',ms}，走
//     Netflix 官方 player.seek，不触发 M7375，不碰 DRM）；其余站点直接 video.currentTime。
//   · 文本点击 → side-panel.js 在扩展页面内取词，再用消息调用
//     查词请求与词典 UI 均在原生 Side Panel 内；这里只准备精确 cue 窗并承接制卡入队。
//   · 制卡入口 = 上述查词弹窗自带的「制卡」按钮（bridge-shim mineEntry → window.fushiEnqueue，
//     携带真实词 fields + 句子），面板不再另造合成 fields 的行级按钮。行的精确 [startMs,endMs]
//     窗留给 P3（截图剪裁 + 精确窗覆盖 DOM 采样）。
//   · 当前句高亮 + 自动滚动：side-panel.js 轮询标签页时间，对当前轨 cues 二分命中当前句
//     （精确窗，胜过 DOM 文本匹配），高亮对应行并（开启时）滚入视图。
// 控制器只依赖 window.fushiEpisodeCues / Side Panel cue bridge / postMessage，
// Netflix DOM 抖动时列表仍由浏览器侧边栏稳定承载。
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;

  // enabled 由扩展 options 的 netflixSubtitlePanel 开关驱动（默认 false）。
  var st = {
    activeLang: null, videoId: null, cues: [], currentIndex: -1,
    tickTimer: null, enabled: false,
    overlayEnabled: true, dragDropEnabled: true, autoScroll: true,
    overlayEl: null, overlayCue: null, dropHint: null,
    // asb 移植：任意轨（检测轨/外挂轨）的读取侧时轴偏移。store 永远存原始 cue，偏移只在
    // Side Panel/覆盖层/快捷键**读取时**套用——provider（textTracks 收割 / live 采样 / 整集拦截）
    // 增量刷新 store 不会与偏移打架。key = `${videoKey}|${lang}`，会话内记忆。
    trackOffsets: Object.create(null),
    // 覆盖层防剧透模糊 / 全轨覆盖层 / 悬浮字幕自动查词。
    overlayAutoLookup: false,
    overlayBlur: false, overlayAllTracks: false,
    overlayHovered: false, autoLookupLastX: -1, autoLookupLastY: -1,
  };
  var EXT_PREFIX = '外挂:';

  // 键名保留旧名以兼容既有用户设置，语义已是启用原生 Side Panel 字幕能力。
  var SETTING_KEY = 'netflixSubtitlePanel';
  function readEnabled(cb) {
    try {
      var p = chrome.storage.local.get(SETTING_KEY);
      if (p && typeof p.then === 'function') {
        p.then(function (c) { cb(!!(c && c[SETTING_KEY] === true)); }, function () { cb(false); });
      } else {
        chrome.storage.local.get(SETTING_KEY, function (c) { cb(!!(c && c[SETTING_KEY] === true)); });
      }
    } catch (_) { cb(false); }
  }
  function teardownAll() {
    hideSubtitleOverlay();
    hideDropHint();
  }
  function applyEnabled(on) {
    st.enabled = !!on;
    sync();
  }

  function sync() {
    if (!st.enabled) { teardownAll(); return; }
    refreshHeadless();
  }

  // 当前视频身份 key：与 content.js 各 provider 写 store 用的同一把 key（window.fushiVideoKey
  // 契约）。契约缺失（加载顺序异常/单测隔离）时本地回落同构实现。
  function videoKey() {
    try {
      if (typeof window.fushiVideoKey === 'function') return window.fushiVideoKey();
    } catch (_) {}
    var m = (location.pathname || '').match(/\/watch\/(\d+)/);
    if (/(^|\.)netflix\.com$/.test(location.hostname) && m) return m[1];
    return (location.hostname + location.pathname).replace(/\|/g, '_');
  }
  function videoEl() { return document.querySelector('video'); }
  function videoTimeMs() {
    var v = videoEl();
    return v && typeof v.currentTime === 'number' ? Math.round(v.currentTime * 1000) : 0;
  }
  function resolveTheme() {
    return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  }

  // DOM 采样 live 轨的伪语言码（content.js FUSHI_LIVE_LANG）：排序垫底 + 显示中文标签。
  var LIVE_LANG = 'live';
  function tracksForVideo() {
    var store = window.fushiEpisodeCues || null;
    var vid = videoKey();
    var out = [];
    if (!store || !vid) return out;
    for (var key in store) {
      var sep = key.indexOf('|');
      if (sep < 0) continue;
      if (key.slice(0, sep) !== String(vid)) continue;
      var cues = store[key];
      if (cues && cues.length) out.push({ lang: key.slice(sep + 1), key: key, cues: cues });
    }
    out.sort(function (a, b) {
      var al = a.lang === LIVE_LANG ? 1 : 0;
      var bl = b.lang === LIVE_LANG ? 1 : 0;
      if (al !== bl) return al - bl; // 整集轨（任何语言）在前，实时采集轨垫底
      return a.lang < b.lang ? -1 : (a.lang > b.lang ? 1 : 0);
    });
    return out;
  }

  // ── asb 移植：读取侧时轴偏移（任意轨，subtitle-controller.ts offset() 的无破坏版） ──
  function activeTrackKey() {
    return st.activeLang ? (videoKey() + '|' + st.activeLang) : null;
  }
  function trackOffset(key) {
    return (key && st.trackOffsets[key]) || 0;
  }
  function shiftedCues(base, off) {
    if (!off) return base;
    var out = [];
    for (var i = 0; i < base.length; i++) {
      var c = base[i];
      out.push({
        startMs: Math.max(0, c.startMs + off),
        endMs: Math.max(0, c.endMs + off),
        text: c.text,
      });
    }
    return out;
  }
  function fmtOffset(ms) {
    return (ms >= 0 ? '+' : '') + (ms / 1000).toFixed(1) + 's';
  }

  function cueIndexAt(cues, t) {
    var lo = 0, hi = cues.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (ans < 0) return -1;
    return t < cues[ans].endMs ? ans : -1;
  }

  function parentForOverlay() { return document.fullscreenElement || document.body; }

  function seekTo(ms) {
    ms = Math.max(0, Math.round(ms));
    if (/(^|\.)netflix\.com$/.test(location.hostname)) {
      // Netflix（DRM 平台边界）：走主世界 bridge 的官方 player.seek（直接改 currentTime 会触发 M7375）。
      // BUG-769：自投用 targetOrigin '/'，file:// opaque origin 下 location.origin('file://')≠recipient('null') 会抛错。
      try { window.postMessage({ __fushiNf: 'seek', ms: ms }, '/'); } catch (_) {}
      return;
    }
    var v = videoEl();
    if (v) { try { v.currentTime = ms / 1000; } catch (_) {} }
  }

  function applySubtitlePreferences(c) {
    c = c || {};
    st.overlayEnabled = c.subtitleOverlayEnabled !== false;
    st.dragDropEnabled = c.subtitleDragDropEnabled !== false;
    st.autoScroll = c.subtitleAutoScroll !== false;
    st.overlayAutoLookup = c.subtitleOverlayAutoLookup === true;
    st.overlayBlur = c.subtitleOverlayBlur === true;
    st.overlayAllTracks = c.subtitleOverlayAllTracks === true;
    if (!st.overlayEnabled) hideSubtitleOverlay();
  }

  // 当前偏好快照（快捷键 toggle 用：改一个键、其余保持现值，绝不把用户已关的项刷回默认）。
  function prefsSnapshot() {
    return {
      subtitleOverlayEnabled: st.overlayEnabled,
      subtitleDragDropEnabled: st.dragDropEnabled,
      subtitleAutoScroll: st.autoScroll,
      subtitleOverlayAutoLookup: st.overlayAutoLookup,
      subtitleOverlayBlur: st.overlayBlur,
      subtitleOverlayAllTracks: st.overlayAllTracks,
    };
  }

  function readSubtitlePreferences() {
    var keys = [
      'subtitleOverlayEnabled', 'subtitleDragDropEnabled', 'subtitleAutoScroll',
      'subtitleOverlayAutoLookup',
      'subtitleOverlayBlur', 'subtitleOverlayAllTracks',
    ];
    try {
      var p = chrome.storage.local.get(keys);
      if (p && typeof p.then === 'function') p.then(applySubtitlePreferences, function () {});
      else chrome.storage.local.get(keys, applySubtitlePreferences);
    } catch (_) {}
  }

  function tick() {
    if (!st.cues.length) { hideSubtitleOverlay(); return; }
    var nowMs = videoTimeMs();
    var idx = cueIndexAt(st.cues, nowMs);
    updateSubtitleOverlay(idx >= 0 ? st.cues[idx] : null);
    st.currentIndex = idx;
  }

  function ensureSubtitleOverlay() {
    if (!st.overlayEl) {
      var el = document.createElement('div');
      el.id = 'fushi-subtitle-overlay';
      el.setAttribute('data-theme', resolveTheme());
      el.addEventListener('click', function (e) {
        e.stopPropagation();
        var cue = st.overlayCue;
        if (cue && typeof window.fushiLookupAtPoint === 'function') {
          window.fushiLookupAtPoint(e.clientX, e.clientY, {
            startMs: cue.startMs, endMs: cue.endMs, text: cue.text,
          });
        }
      });
      el.addEventListener('mouseenter', function () {
        st.overlayHovered = true;
        applyOverlayBlur(el);
      });
      // 悬浮字幕自动查词：只在覆盖层内启用，按与 content.js Shift 悬停同样的 4px 位移阈值
      // 限流；取词、同词去重、在途闸和精确 cue 窗全部复用 fushiLookupAtPoint。
      el.addEventListener('mousemove', function (e) {
        if (!st.overlayAutoLookup || !st.overlayCue ||
            typeof window.fushiLookupAtPoint !== 'function') return;
        if (Math.abs(e.clientX - st.autoLookupLastX) < 4 &&
            Math.abs(e.clientY - st.autoLookupLastY) < 4) return;
        st.autoLookupLastX = e.clientX;
        st.autoLookupLastY = e.clientY;
        var cue = st.overlayCue;
        window.fushiLookupAtPoint(
          e.clientX,
          e.clientY,
          { startMs: cue.startMs, endMs: cue.endMs, text: cue.text },
          { auto: true },
        );
      });
      el.addEventListener('mouseleave', function () {
        st.overlayHovered = false;
        applyOverlayBlur(el);
        st.autoLookupLastX = -1;
        st.autoLookupLastY = -1;
        if (typeof window.fushiResetAutoLookupDedupe === 'function') {
          window.fushiResetAutoLookupDedupe();
        }
      });
      st.overlayEl = el;
    }
    var parent = parentForOverlay();
    if (st.overlayEl.parentNode !== parent) parent.appendChild(st.overlayEl);
    return st.overlayEl;
  }

  // 防剧透模糊——覆盖层默认糊住，悬停即清晰。
  function applyOverlayBlur(el) {
    if (!el || !el.style) return;
    var blurred = st.overlayBlur && !st.overlayHovered;
    try { el.style.filter = blurred ? 'blur(6px)' : ''; } catch (_) {}
  }

  function hideSubtitleOverlay() {
    st.overlayCue = null;
    if (st.overlayEl && st.overlayEl.parentNode) st.overlayEl.parentNode.removeChild(st.overlayEl);
  }

  function updateSubtitleOverlay(cue) {
    // 外挂轨恒显示；检测轨（站点自带字幕）默认不重复叠字，除非用户开了「全轨覆盖层」
    // （overlayAllTracks，配合防剧透模糊/悬浮字幕自动查词使用）。
    if (!st.overlayEnabled || !cue ||
        (!isExternalLang(st.activeLang) && !st.overlayAllTracks)) {
      hideSubtitleOverlay();
      return;
    }
    var video = videoEl();
    if (!video || typeof video.getBoundingClientRect !== 'function') return;
    var rect = video.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) return;
    var el = ensureSubtitleOverlay();
    st.overlayCue = cue;
    el.setAttribute('data-theme', resolveTheme());
    el.textContent = cue.text;
    el.style.left = (rect.left + rect.width / 2) + 'px';
    el.style.top = (rect.top + rect.height * 0.84) + 'px';
    el.style.maxWidth = Math.max(240, rect.width * 0.9) + 'px';
    applyOverlayBlur(el);
  }

  function firstCueAfter(ms) {
    var lo = 0, hi = st.cues.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (st.cues[mid].startMs > ms) { ans = mid; hi = mid - 1; } else { lo = mid + 1; }
    }
    return ans;
  }

  function showPanel() {
    refreshHeadless();
    try { chrome.runtime.sendMessage({ type: 'openSubtitleSidePanel' }); } catch (_) {}
  }

  // Side Panel 读取的无 DOM 状态刷新。这里保留 live→整集轨自动升级、任意轨偏移和
  // 覆盖字幕逻辑，但不创建列表节点、不修改宿主页面布局。
  function refreshHeadless() {
    st.videoId = videoKey();
    var tracks = tracksForVideo();
    var active = null;
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i].lang === st.activeLang) active = tracks[i];
    }
    var fullTrackArrived = st.activeLang === LIVE_LANG &&
      tracks.length && tracks[0].lang !== LIVE_LANG;
    if (!active || fullTrackArrived) {
      active = tracks.length ? tracks[0] : null;
      st.activeLang = active ? active.lang : null;
    }
    var off = trackOffset(active ? active.key : null);
    st.cues = active ? shiftedCues(active.cues, off) : [];
    st.currentIndex = -1;
    tick();
    return tracks;
  }

  // ── B（asb 招牌）：加载用户外挂字幕文件 + 时轴偏移微调 ──
  function toast(msg) {
    try { if (typeof window.fushiToast === 'function') window.fushiToast(msg); } catch (_) {}
  }
  function isExternalLang(lang) {
    return typeof lang === 'string' && lang.indexOf(EXT_PREFIX) === 0;
  }
  function loadSubtitleFile(file) {
    if (file && typeof file.size === 'number' && file.size > 8 * 1024 * 1024) {
      toast('字幕文件过大（上限 8 MB）');
      return;
    }
    var reader = new FileReader();
    reader.onload = function () {
      var content = String(reader.result || '');
      try {
        chrome.runtime.sendMessage(
          { type: 'parseSubtitle', filename: file.name, content: content },
          function (resp) {
            try {
              if (chrome.runtime.lastError) { toast('字幕加载失败：未连上 Fushi'); return; }
              applyExternalSubtitle(file.name, resp);
            } catch (_) {}
          });
      } catch (_) { toast('字幕加载失败'); }
    };
    reader.onerror = function () { toast('读取文件失败'); };
    try { reader.readAsText(file); } catch (_) { toast('读取文件失败'); }
  }
  function applyExternalSubtitle(filename, resp) {
    if (!resp || !resp.ok || !resp.data) { toast(connectionFailureText(resp, '字幕解析失败')); return; }
    if (resp.data.error === 'unsupported') { toast('不支持的格式（用 srt/ass/vtt）'); return; }
    var raw = Array.isArray(resp.data.cues) ? resp.data.cues : [];
    var base = [];
    for (var i = 0; i < raw.length; i++) {
      var c = raw[i];
      if (!c || typeof c.startMs !== 'number' || typeof c.endMs !== 'number') continue;
      var text = String(c.text || '');
      if (!text) continue;
      base.push({ startMs: c.startMs, endMs: c.endMs, text: text });
    }
    if (!base.length) { toast('字幕为空'); return; }
    var label = EXT_PREFIX + String(filename).replace(/\|/g, '_');
    var key = videoKey() + '|' + label;
    // 外挂轨与检测轨同构：store 存原始 cue，偏移走统一的读取侧 trackOffsets（重新加载即归零）。
    var store = window.fushiEpisodeCues || (window.fushiEpisodeCues = Object.create(null));
    store[key] = base;
    delete st.trackOffsets[key];
    st.activeLang = label;
    showPanel();
    toast('已加载外挂字幕：' + base.length + ' 句');
  }

  function connectionFailureText(resp, fallback) {
    var c = resp && resp.connection;
    if (!c) return fallback;
    if (c.state === 'yomitan-conflict') {
      return '端口 ' + (c.port || 19633) + ' 被 Yomitan API 占用：请先在 Yomitan 高级设置关闭 Enable Yomitan API，再开启 Fushi 的 Yomitan API 服务器';
    }
    if (c.state === 'unauthorized') return 'Fushi API 密钥不匹配：请在扩展设置中恢复自动配置';
    if (c.state === 'offline') return 'Fushi API 未开启：请在 Fushi 设置 → 查词中开启 Yomitan API 服务器';
    return fallback;
  }

  function isSubtitleFile(file) {
    return !!(file && /\.(srt|ass|ssa|vtt)$/i.test(String(file.name || '')));
  }

  function showDropHint() {
    if (!st.dropHint) {
      st.dropHint = document.createElement('div');
      st.dropHint.id = 'fushi-subtitle-drop-hint';
      st.dropHint.textContent = '松开以加载字幕';
    }
    var parent = parentForOverlay();
    if (st.dropHint.parentNode !== parent) parent.appendChild(st.dropHint);
  }

  function hideDropHint() {
    if (st.dropHint && st.dropHint.parentNode) st.dropHint.parentNode.removeChild(st.dropHint);
  }

  function filesFromTransfer(dt) {
    var out = [];
    var files = dt && dt.files ? dt.files : [];
    for (var i = 0; i < files.length; i++) if (isSubtitleFile(files[i])) out.push(files[i]);
    return out;
  }

  document.addEventListener('dragover', function (e) {
    if (!st.dragDropEnabled || !e.dataTransfer) return;
    var hasFiles = e.dataTransfer.types && Array.prototype.indexOf.call(e.dataTransfer.types, 'Files') >= 0;
    if (!hasFiles) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = 'copy';
    showDropHint();
  }, true);
  document.addEventListener('dragleave', function (e) {
    if (!e.relatedTarget) hideDropHint();
  }, true);
  document.addEventListener('drop', function (e) {
    if (!st.dragDropEnabled) return;
    var files = filesFromTransfer(e.dataTransfer);
    hideDropHint();
    if (!files.length) return;
    e.preventDefault();
    if (!st.enabled) {
      try { chrome.storage.local.set({ netflixSubtitlePanel: true }); } catch (_) {}
      applyEnabled(true);
    } else {
      showPanel();
    }
    for (var i = 0; i < files.length; i++) loadSubtitleFile(files[i]);
  }, true);
  // ── asb 移植：快捷键执行端 ──
  // video-shortcuts.js（同隔离世界、本文件之后加载）判定按键 → 调这里执行。控制器持有轨/偏移/
  // 模式状态，所以动作收敛在本文件；侧边栏未打开（甚至未启用）时快捷键也要能用——此时隐式选
  // 当前视频的第一条轨。返回 true = 已接管（调用方 preventDefault），false = 放行给站点。
  function lastCueStartBefore(ms) {
    var lo = 0, hi = st.cues.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (st.cues[mid].startMs < ms) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    return ans;
  }
  // 侧边栏没开时 st.cues 可能为空/过期：从 store 重取当前轨（含读取侧偏移）。
  function recomputeShortcutCues() {
    var tracks = tracksForVideo();
    var active = null;
    for (var i = 0; i < tracks.length; i++) if (tracks[i].lang === st.activeLang) active = tracks[i];
    if (!active && tracks.length) { st.activeLang = tracks[0].lang; active = tracks[0]; }
    st.cues = active ? shiftedCues(active.cues, trackOffset(active.key)) : [];
  }
  function shortcutSeekPrev() {
    if (!st.cues.length) return false;
    // 上一句：开播 >600ms 时先回本句句首（与播放器「上一曲」惯例一致），再按一次才到上一句。
    var i = lastCueStartBefore(videoTimeMs() - 600);
    if (i < 0) return false;
    seekTo(st.cues[i].startMs);
    return true;
  }
  function shortcutSeekNext() {
    if (!st.cues.length) return false;
    var i = firstCueAfter(videoTimeMs());
    if (i < 0) return false;
    seekTo(st.cues[i].startMs);
    return true;
  }
  function shortcutReplay() {
    if (!st.cues.length) return false;
    var now = videoTimeMs();
    var idx = cueIndexAt(st.cues, now);
    if (idx < 0) idx = lastCueStartBefore(now);
    if (idx < 0) return false;
    seekTo(st.cues[idx].startMs);
    return true;
  }
  function shortcutOffset(deltaMs) {
    var key = activeTrackKey();
    if (!key || !st.cues.length) return false;
    if (deltaMs === 0) delete st.trackOffsets[key];
    else st.trackOffsets[key] = (st.trackOffsets[key] || 0) + deltaMs;
    recomputeShortcutCues();
    toast('字幕偏移 ' + fmtOffset(trackOffset(key)));
    return true;
  }
  function shortcutCopyCue() {
    if (!st.cues.length) return false;
    var now = videoTimeMs();
    var idx = cueIndexAt(st.cues, now);
    if (idx < 0) idx = lastCueStartBefore(now);
    if (idx < 0) return false;
    var text = st.cues[idx].text;
    if (typeof navigator === 'undefined' || !navigator.clipboard ||
        typeof navigator.clipboard.writeText !== 'function') return false;
    Promise.resolve(navigator.clipboard.writeText(text)).catch(function () {});
    toast('已复制字幕：' + (text.length > 30 ? text.slice(0, 30) + '…' : text));
    return true;
  }
  function shortcutTogglePanel() {
    if (!st.enabled) {
      try { chrome.storage.local.set({ netflixSubtitlePanel: true }); } catch (_) {}
      applyEnabled(true);
    }
    showPanel();
    return true;
  }
  window.fushiSubtitleShortcut = function (action) {
    if (!videoEl()) return false;
    if (!st.cues.length) recomputeShortcutCues();
    switch (action) {
      case 'prev-cue': return shortcutSeekPrev();
      case 'next-cue': return shortcutSeekNext();
      case 'replay-cue': return shortcutReplay();
      case 'offset-minus': return shortcutOffset(-100);
      case 'offset-plus': return shortcutOffset(100);
      case 'offset-reset': return shortcutOffset(0);
      case 'copy-cue': return shortcutCopyCue();
      case 'toggle-panel': return shortcutTogglePanel();
      // 隐藏字幕：状态与 style 注入由 content.js 独占（见那里的「所有权」注释）——侧边栏能力
      // 受 netflixSubtitlePanel 门控且默认关，状态放这里会导致「没开侧边栏就不能隐藏字幕」。
      // 这里只做转发，content.js 未就绪时返回 false（不吞按键，站点行为原样）。
      case 'toggle-subtitle-hide':
        return typeof window.fushiToggleSubtitleHiding === 'function'
          ? window.fushiToggleSubtitleHiding() === true
          : false;
    }
    return false;
  };

  // 兼容旧 content.js 的批量录制钩子。原生 Side Panel 不属于标签页画面，不再需要改网页宽度。
  window.fushiSubtitlePanelSuspendPush = function () {};
  window.fushiSubtitlePanelResumePush = function () {};

  window.fushiSubtitlePanelOnCues = function (_key) {
    if (!st.enabled) return;
    refreshHeadless();
  };

  function trackSignature(track) {
    var cues = track && track.cues || [];
    if (!cues.length) return '0';
    var first = cues[0];
    var last = cues[cues.length - 1];
    return [
      cues.length,
      first.startMs, first.endMs, first.text,
      last.startMs, last.endMs, last.text,
    ].join(':');
  }

  function sidePanelState(includeCues) {
    var tracks = refreshHeadless();
    var activeKey = activeTrackKey();
    return {
      ok: true,
      videoKey: videoKey(),
      hasVideo: !!videoEl(),
      activeLang: st.activeLang,
      currentTimeMs: videoTimeMs(),
      offsetMs: trackOffset(activeKey),
      tracks: tracks.map(function (track) {
        return {
          lang: track.lang,
          label: track.lang === LIVE_LANG ? '实时采集' : track.lang,
          length: track.cues.length,
          signature: trackSignature(track),
        };
      }),
      cues: includeCues ? st.cues : null,
    };
  }

  // 浏览器 Side Panel 与当前标签之间的唯一契约。列表 DOM 完全位于扩展页面；这里仅做
  // 序列化、seek、偏移、外挂轨安装和查词命令，不向宿主网页挂字幕列表节点。
  try {
    chrome.runtime.onMessage.addListener(function (msg, _sender, sendResponse) {
      if (!msg || typeof msg.type !== 'string') return false;
      if (msg.type === 'fushiSubtitleSidePanelState') {
        sendResponse(sidePanelState(msg.includeCues === true));
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelSeek') {
        seekTo(Number(msg.ms) || 0);
        sendResponse({ ok: true, currentTimeMs: videoTimeMs() });
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelSelectTrack') {
        var wanted = String(msg.lang || '');
        var available = tracksForVideo();
        var found = false;
        for (var i = 0; i < available.length; i++) {
          if (available[i].lang === wanted) { found = true; break; }
        }
        if (found) st.activeLang = wanted;
        sendResponse(sidePanelState(true));
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelOffset') {
        var key = activeTrackKey();
        if (key) {
          if (msg.reset === true) delete st.trackOffsets[key];
          else st.trackOffsets[key] = (st.trackOffsets[key] || 0) + (Number(msg.deltaMs) || 0);
        }
        sendResponse(sidePanelState(true));
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelInstallTrack') {
        applyExternalSubtitle(String(msg.filename || 'subtitle.srt'), {
          ok: true,
          data: { cues: Array.isArray(msg.cues) ? msg.cues : [] },
        });
        sendResponse(sidePanelState(true));
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelPrepareLookup') {
        var cue = msg.cue && typeof msg.cue === 'object' ? msg.cue : null;
        var handled = typeof window.fushiPrepareLookupFromSidePanel === 'function' &&
          window.fushiPrepareLookupFromSidePanel(cue) === true;
        sendResponse({ ok: handled });
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelMine') {
        var mineCue = msg.cue && typeof msg.cue === 'object' ? msg.cue : null;
        var result = typeof window.fushiMineFromSidePanel === 'function'
          ? window.fushiMineFromSidePanel(msg.fields || {}, mineCue)
          : { ok: false, reason: 'no-queue' };
        sendResponse(result || { ok: false });
        return false;
      }
      return false;
    });
  } catch (_) {}

  document.addEventListener('fullscreenchange', function () {
    if (!st.enabled) return;
    sync();
  });

  var lastPath = location.pathname;
  setInterval(function () {
    if (location.pathname !== lastPath) {
      lastPath = location.pathname;
      st.activeLang = null;
      sync();
    }
  }, 500);

  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes) return;
      if (changes[SETTING_KEY]) applyEnabled(changes[SETTING_KEY].newValue === true);
      // 以当前值快照为底、只覆盖真正变化的键——单键变更绝不把其它偏好刷回默认。
      var prefs = prefsSnapshot();
      var changed = false;
      var keys = [
        'subtitleOverlayEnabled', 'subtitleDragDropEnabled', 'subtitleAutoScroll',
        'subtitleOverlayAutoLookup',
        'subtitleOverlayBlur', 'subtitleOverlayAllTracks',
      ];
      for (var i = 0; i < keys.length; i++) {
        if (changes[keys[i]]) { prefs[keys[i]] = changes[keys[i]].newValue; changed = true; }
      }
      if (changed) applySubtitlePreferences(prefs);
    });
  } catch (_) {}

  st.tickTimer = setInterval(tick, 200);

  // 默认关：读取开关；打开动作只由用户手势或快捷键触发，浏览器原生侧边栏不会自动弹出。
  readSubtitlePreferences();
  readEnabled(applyEnabled);
})();
