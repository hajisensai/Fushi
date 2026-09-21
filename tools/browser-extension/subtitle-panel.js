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
    // videoId 初始值是 '' 而非 null：与 videoKey() 的非空字符串契约同型，
    // 首次 tick 仍会因 '' !== <真实 key> 而触发一次 refreshHeadless（语义不变）。
    activeLang: null, videoId: '', cues: [], currentIndex: -1,
    tickTimer: null, enabled: false,
    overlayEnabled: true, dragDropEnabled: true, autoScroll: true,
    overlayEl: null, overlayCue: null, dropHint: null,
    // 覆盖层的两个子节点：文字层（fushiRenderCueText 只往这里写）与拖柄；overlayRenderedCue
    // 记文字层当前画的是哪条 cue——tick 每 200ms 重摆位置，但只有 cue 换了才重建文本节点，
    // 否则用户刚拖出来的原生选区每 200ms 就被新文本节点冲掉一次（用户报「字幕选不了、复制不了」）。
    // overlayResizeEl：右下角缩放把手（与查词弹窗的 #fushi-popup-resize-grip 同一套交互：
    // 按住拖 = 改底板宽高、松手落盘；双击 = 恢复「随内容」）。
    overlayTextEl: null, overlayGripEl: null, overlayResizeEl: null, overlayRenderedCue: null,
    // 覆盖层底色（默认有半透明底板；关掉只剩描边文字，像站点原生字幕那样不挡画面）。
    overlayBackground: true,
    // 覆盖层外观（字体 / 大小 / 字重 / 间距 / 行高 / 对齐 / 颜色 / 描边 / 底板色与透明度…），
    // 设置对象原样存，落地经 subtitle-style.js toCssVars → 覆盖层根的 --fushi-sub-* 变量。
    overlayStyle: null,
    // asb 移植：任意轨（检测轨/外挂轨）的读取侧时轴偏移。store 永远存原始 cue，偏移只在
    // Side Panel/覆盖层/快捷键**读取时**套用——provider（textTracks 收割 / live 采样 / 整集拦截）
    // 增量刷新 store 不会与偏移打架。key = `${videoKey}|${lang}`，会话内记忆。
    trackOffsets: Object.create(null),
    // 覆盖层防剧透模糊 / 全轨覆盖层 / 悬浮字幕自动查词。
    overlayAutoLookup: false,
    overlayBlur: false, overlayAllTracks: false,
    overlayHovered: false, autoLookupLastX: -1, autoLookupLastY: -1,
    // 「用 Fushi 字幕替代站点原生字幕」：用预取的整集轨自绘一整句，并藏掉站点原生字幕。
    // 针对 YouTube 自动生成字幕——它是**逐词滚动**渲染的（DOM 里每帧多一个词），
    // 拿它划词/制卡永远只能拿到半句；而 youtube-bridge.js 早就把整集 srv3 轨按 <p> 段
    // 预取进 store 了，只是渲染侧默认不用（站点自带轨不叠加，避免双份字幕）。
    // replaceNativeActive = 本轮判定「替代确实生效中」，推给 content.js 决定藏不藏原生。
    replaceNative: false, replaceNativeActive: false,
    // 覆盖层位置：用户拖过后存 {x, y}，都是**视频矩形的分数**（x = 水平中心、y = 底边锚点），
    // 不存像素——全屏/退全屏/窗口缩放/换清晰度时视频盒会变，分数坐标让字幕在画面里的相对
    // 位置不变。null = 没拖过，走默认（居中、底锚 88%）。
    overlayPos: null,
    // 进行中的拖拽会话（null = 没在拖）；overlayDragMoved 记「刚才那次按下确实拖动了」，
    // 用来吞掉松手后浏览器合成的那一次 click——否则每次拖完都会顺手查一次词。
    overlayDrag: null, overlayDragMoved: false,
    // 进行中的缩放会话（null = 没在缩放）。拖拽期间的尺寸 / 位置只活在这里，松手才落盘——
    // 与挪位同构（见 overlayDrag），中途 pointercancel 一律丢弃回原样。
    overlayResize: null,
  };
  var EXT_PREFIX = '外挂:';
  // 界面文案统一走 i18n.js（fushiT）；测试壳没装 i18n 时退回键名。
  function tr(key, params) {
    return (typeof window.fushiT === 'function') ? window.fushiT(key, params) : key;
  }
  var OVERLAY_POS_KEY = 'subtitleOverlayPosition';
  var OVERLAY_STYLE_KEY = 'subtitleStyle';
  var OVERLAY_POS_DEFAULT = { x: 0.5, y: 0.88 };
  // 按下后位移小于这个值仍算点击（查词），超过才进入拖动；与 content.js Shift 悬停的
  // 4px 限流同量级，略放宽以免手指/鼠标微抖把查词变成挪字幕。
  var OVERLAY_DRAG_THRESHOLD = 6;

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
    endOverlayDrag(false);
    endOverlayResize(false);
    hideSubtitleOverlay();
    hideDropHint();
    // 面板整体被关掉时替代模式也随之失效（replaceNativeEffective 已含 st.enabled），
    // 必须把站点原生字幕放回来——否则用户关掉字幕列表后既没有自绘覆盖层也没有原生字幕。
    syncNativeSubtitleReplacement();
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
      if (typeof window.fushiVideoKey === 'function') {
        // 契约：videoKey() 永远返回非空字符串。返回值会直接拼进轨 key
        // （`${videoKey}|${lang}`），漏出 undefined/'' 就会生成 "undefined|ja" 这种脏 key；
        // 而身份比较（videoKey() !== st.videoId）会因两侧类型不同而永远判「换了视频」。
        // 上游给不出有效值时落回下面的通用回落，不把脏值传出去。
        var k = window.fushiVideoKey();
        if (typeof k === 'string' && k) return k;
      }
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
  // 明暗统一走 theme.js（扩展设置 extensionTheme）；缺席时退回系统偏好。
  function resolveTheme() {
    if (window.fushiTheme && typeof window.fushiTheme.resolve === 'function') return window.fushiTheme.resolve();
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
      // BUG-2194：按需加载的占位轨（清单已到、cue 未取）也列出来，让用户能选中触发加载。
      else if (window.fushiLazyTracks && window.fushiLazyTracks[key]) {
        out.push({ lang: key.slice(sep + 1), key: key, cues: [], pending: true });
      }
    }
    out.sort(function (a, b) {
      // 已加载整集轨在前，占位轨其次，实时采集轨垫底。
      var al = a.lang === LIVE_LANG ? 2 : (a.pending ? 1 : 0);
      var bl = b.lang === LIVE_LANG ? 2 : (b.pending ? 1 : 0);
      if (al !== bl) return al - bl;
      return a.lang < b.lang ? -1 : (a.lang > b.lang ? 1 : 0);
    });
    return out;
  }
  // 占位轨被选为活动轨 → 请桥真取（同一 key 5 秒内不重复请求；取失败用户重选即可再试）。
  function requestLazyIfPending(track) {
    if (!track || !track.pending || typeof window.fushiRequestLazyTrack !== 'function') return;
    var now = Date.now();
    st.lazyRequestedAt = st.lazyRequestedAt || {};
    if (now - (st.lazyRequestedAt[track.key] || 0) < 5000) return;
    st.lazyRequestedAt[track.key] = now;
    try { window.fushiRequestLazyTrack(track.key); } catch (_) {}
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

  // 与 subtitle-adapters.js 的 findCueIndexAt 是同一判据（含「落在字幕间隙返回 -1」）。
  // 这里**有意**保留独立实现而不去调它：本文件被多套测试 harness 单独装进 vm 沙箱，
  // 依赖同世界的其它 content script 会让面板从自包含变成跨文件依赖，harness 漏装一个
  // 就假红。两份都只有 8 行、语义封闭，改其一必须同步另一处。
  function cueIndexAt(cues, t) {
    var lo = 0, hi = cues.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= t) { ans = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    if (ans < 0) return -1;
    return t < cues[ans].endMs ? ans : -1;
  }

  // 兜底父级用 <html> 而不是 <body>：浮层写的是视口坐标的 position:fixed，而安卓播放器
  // 进/退全屏常给 body 挂 transform 或 scroll-lock（position:fixed;top:-Npx）——fixed 的
  // 包含块会跟着变成那个带 transform 的祖先，视口坐标落进歪掉的坐标系，每 200ms 重测
  // 一百次也还是歪的（用户报「退出全屏字幕错位」修不尽的根因）。html 自己从不被 transform。
  function parentForOverlay() { return document.fullscreenElement || document.documentElement; }

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
    st.overlayBackground = c.subtitleOverlayBackground !== false;
    st.replaceNative = c.subtitleReplaceNative === true;
    st.overlayPos = normalizeOverlayPos(c[OVERLAY_POS_KEY]);
    st.overlayStyle = (c[OVERLAY_STYLE_KEY] && typeof c[OVERLAY_STYLE_KEY] === 'object') ? c[OVERLAY_STYLE_KEY] : null;
    // 外观变了（字号/行高/底板尺寸/自适应开关…）：下一次重摆必须重算自适应倍率，否则
    // 用户在设置页调完大小，覆盖层还按上一句算出来的倍率缩着。
    overlayFitKey = null;
    // 外观变了就允许重新拉一次字体清单（用户可能刚在设置页下载了新字体）；清单没变不会重写 <style>。
    overlayFontFacesRequested = false;
    if (st.overlayEl) { applyOverlayBackground(st.overlayEl); applyOverlayStyle(st.overlayEl); }
    if (!st.overlayEnabled) hideSubtitleOverlay();
    // 位置变了（另一标签页拖过 / options 页重置）立刻重摆，不等下一个 200ms tick。
    else if (st.overlayCue) updateSubtitleOverlay(st.overlayCue);
    syncNativeSubtitleReplacement();
  }

  // 存储里的位置只认「两个有限数、都落在 [0,1]」的形状；坏值（旧版本写错、手改 storage）
  // 一律当没拖过——绝不能把 NaN 写进 style.left 让字幕直接消失。
  function normalizeOverlayPos(v) {
    if (!v || typeof v !== 'object') return null;
    var x = Number(v.x), y = Number(v.y);
    if (!isFinite(x) || !isFinite(y)) return null;
    return { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
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
      subtitleOverlayBackground: st.overlayBackground,
      subtitleReplaceNative: st.replaceNative,
      subtitleOverlayPosition: st.overlayPos,
      subtitleStyle: st.overlayStyle,
    };
  }

  // 覆盖层消费的全部偏好键（首读与 storage.onChanged 共用一份，漏一处就是「设置页改了不生效」）。
  var SUBTITLE_PREF_KEYS = [
    'subtitleOverlayEnabled', 'subtitleDragDropEnabled', 'subtitleAutoScroll',
    'subtitleOverlayAutoLookup',
    'subtitleOverlayBlur', 'subtitleOverlayAllTracks', 'subtitleOverlayBackground',
    'subtitleReplaceNative',
    OVERLAY_POS_KEY, OVERLAY_STYLE_KEY,
  ];

  function readSubtitlePreferences() {
    var keys = SUBTITLE_PREF_KEYS;
    try {
      var p = chrome.storage.local.get(keys);
      if (p && typeof p.then === 'function') p.then(applySubtitlePreferences, function () {});
      else chrome.storage.local.get(keys, applySubtitlePreferences);
    } catch (_) {}
  }

  // 替代模式是否**真的**生效。四个条件缺一不可，任何一个不成立都必须放回原生字幕——
  // 「藏了原生、自绘又没内容」= 用户一句字幕都看不到，比不做还糟：
  //   ① 用户开了这个设置；② 覆盖层没被关掉（它就是替代品本身）；
  //   ③ 当前活动轨不是 live 轨（live 轨就是从原生 DOM 逐词采来的，拿它替代原生毫无意义）；
  //   ④ 这条轨真有 cue（整轨还没到 / 抓取失败时保持原生字幕可见）。
  function replaceNativeEffective() {
    return st.enabled && st.replaceNative && st.overlayEnabled &&
      !!st.activeLang && st.activeLang !== LIVE_LANG && st.cues.length > 0;
  }

  // 把判定结果推给 content.js（遮蔽原因 'replace' 的唯一写入点）。幂等：状态没变不发。
  function syncNativeSubtitleReplacement() {
    var active = replaceNativeEffective();
    if (active === st.replaceNativeActive) return;
    st.replaceNativeActive = active;
    try {
      if (typeof window.fushiSetNativeSubtitleReplaced === 'function') {
        window.fushiSetNativeSubtitleReplaced(active);
      }
    } catch (_) {}
  }

  function tick() {
    // 面板被关掉时 tick 直接停手。下面的身份检测会调 refreshHeadless，那是 sync() /
    // fushiSubtitlePanelOnCues 的 enabled 门之外的第三条入口——不挡住的话，关掉的面板仍会
    // 每 200ms 遍历整个 cue store 并拷一份 shiftedCues（整集轨可达数千条 × 多轨）。
    // 注：这是**性能与语义一致性**门，不是正确性门——替代模式的撤销由 replaceNativeEffective
    // 里的 st.enabled 保证，覆盖层的摘除由 teardownAll 保证，故变异掉这一行不会让测试变红。
    if (!st.enabled) return;
    // SPA 换视频先于一切：YouTube 只换 `?v=`，pathname 不变，下面那条 500ms 的 pathname
    // 轮询根本看不见——不在这里认出身份变化，st.cues 会一直留着上一个视频的整轨，
    // 替代模式就会拿旧字幕盖住新视频（且原生字幕已被藏）。refreshHeadless 内部会重跑 tick。
    if (videoKey() !== st.videoId) {
      st.activeLang = null;
      refreshHeadless();
      return;
    }
    // 先同步替代状态再走空轨短路：切视频/换轨导致 cues 清空时，原生字幕必须立刻放回来。
    syncNativeSubtitleReplacement();
    if (!st.cues.length) { hideSubtitleOverlay(); return; }
    var nowMs = videoTimeMs();
    var idx = cueIndexAt(st.cues, nowMs);
    updateSubtitleOverlay(idx >= 0 ? st.cues[idx] : null);
    st.currentIndex = idx;
  }

  // 用户是否刚在覆盖层里用鼠标拖出了一段原生选区（准备复制）。这时紧随其后的 click
  // 不能当查词——fushiLookupAtPoint 会 removeAllRanges 把选区清掉，Ctrl+C 就没东西可复制。
  function overlayHasNativeSelection() {
    try {
      var sel = window.getSelection && window.getSelection();
      if (!sel || sel.isCollapsed || !(sel.rangeCount > 0)) return false;
      var node = sel.anchorNode;
      return !!(node && st.overlayEl && st.overlayEl.contains(node));
    } catch (_) { return false; }
  }

  function isOverlayHandleOf(el, target, cls) {
    if (!el || !target) return false;
    if (target === el) return true;
    try { return typeof target.closest === 'function' && target.closest('.' + cls) === el; }
    catch (_) { return false; }
  }
  function isOverlayGrip(target) {
    return isOverlayHandleOf(st.overlayGripEl, target, 'fushi-subtitle-overlay-grip');
  }
  function isOverlayResize(target) {
    return isOverlayHandleOf(st.overlayResizeEl, target, 'fushi-subtitle-overlay-resize');
  }

  function ensureSubtitleOverlay() {
    if (!st.overlayEl) {
      var el = document.createElement('div');
      el.id = 'fushi-subtitle-overlay';
      el.setAttribute('data-theme', resolveTheme());
      // 文字层与拖柄分开：fushiRenderCueText 会先清空目标节点再写，若直接写在根节点上，
      // 拖柄每次换句都被抹掉。拖柄用 CSS ::before 画图形，不带文本节点——content.js 的
      // fushiSubtitleCaretAtPoint 会遍历覆盖层下的所有文本节点取词，拖柄不能混进正文。
      var text = document.createElement('span');
      text.className = 'fushi-subtitle-overlay-text';
      var grip = document.createElement('span');
      grip.className = 'fushi-subtitle-overlay-grip';
      grip.setAttribute('title', tr('overlay_grip_title'));
      grip.setAttribute('aria-hidden', 'true');
      // 右下角缩放把手：与拖柄同构（::before 画图形、不带文本节点，取词遍历不会碰到它）。
      var resize = document.createElement('span');
      resize.className = 'fushi-subtitle-overlay-resize';
      resize.setAttribute('title', tr('overlay_resize_title'));
      resize.setAttribute('aria-hidden', 'true');
      el.appendChild(text);
      el.appendChild(grip);
      el.appendChild(resize);
      st.overlayTextEl = text;
      st.overlayGripEl = grip;
      st.overlayResizeEl = resize;
      resize.addEventListener('pointerdown', overlayResizePointerDown);
      // 双击把手 = 恢复「随内容」（拖歪了的唯一就地出路，不必特地开设置页）。
      resize.addEventListener('dblclick', function (e) {
        e.stopPropagation();
        e.preventDefault();
        resetOverlayBox();
      });
      el.addEventListener('pointerdown', overlayPointerDown);
      // 鼠标在字幕文字上按下 = 开始原生拖选（复制用），这一击不交给站点：Netflix/YouTube 把
      // 播放器上的 mousedown 当「点画面」处理，有的还 preventDefault 把选区扼杀在起点。
      el.addEventListener('mousedown', function (e) { e.stopPropagation(); });
      el.addEventListener('click', function (e) {
        e.stopPropagation();
        // 刚拖完字幕松手：这次 click 是拖动的尾巴，不是查词。
        if (st.overlayDragMoved) { st.overlayDragMoved = false; return; }
        // 点在拖柄 / 缩放把手上、刚用鼠标拖出一段选区：都不是查词。
        if (isOverlayGrip(e.target) || isOverlayResize(e.target) || overlayHasNativeSelection()) return;
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
        // 拖动中指针在字幕上划过的每个词都不该被自动查——那是在挪字幕，不是在读。
        if (st.overlayDrag && st.overlayDrag.moved) return;
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

  // 底色开关落成 data-bare 属性，样式在 content-css-overlay.css（去底板、去投影，只留描边字）。
  function applyOverlayBackground(el) {
    if (!el) return;
    try {
      if (st.overlayBackground) el.removeAttribute('data-bare');
      else el.setAttribute('data-bare', '');
    } catch (_) {}
  }

  // 外观设置 → 覆盖层根的 --fushi-sub-* 变量（默认项 removeProperty 交还 CSS）。subtitle-style.js
  // 缺席（旧测试壳）时不动样式，CSS 默认值就是旧观感。
  // 每 200ms 的 tick 也会路过这里：同一份设置不重复写 style（避免每 tick 都让浏览器重算样式）。
  var overlayStyleApplied = null;
  function applyOverlayStyle(el) {
    if (!el || !window.fushiSubtitleStyle) return;
    var sig;
    try { sig = JSON.stringify(st.overlayStyle || null); } catch (_) { sig = null; }
    if (sig === overlayStyleApplied && el === overlayStyleAppliedEl) return;
    overlayStyleApplied = sig;
    overlayStyleAppliedEl = el;
    window.fushiSubtitleStyle.applyTo(el, st.overlayStyle);
    ensureOverlayFontFaces();
  }
  var overlayStyleAppliedEl = null;

  // Fushi 字体库：外观里选了字体（fontFamily 非空）时，向 background 要一次 app 的字体清单，
  // 把每条以 @font-face 挂进页面（subtitle-style.js fontFaceCss；浏览器只为真命中的 family 取字节）。
  // app 没开 / 旧 app 没这个端点 → 什么都不挂，覆盖层按本机字体回落。一页只请求一次；失败允许
  // 下次外观变化时重试。
  var overlayFontFacesRequested = false;
  var overlayFontFacesCss = null;
  var OVERLAY_FONT_FACES_ID = 'fushi-subtitle-fontfaces';
  function ensureOverlayFontFaces() {
    var style = st.overlayStyle;
    var fam = (style && typeof style.fontFamily === 'string') ? style.fontFamily.trim() : '';
    if (!fam || overlayFontFacesRequested) return;
    if (typeof chrome === 'undefined' || !chrome.runtime || typeof chrome.runtime.sendMessage !== 'function') return;
    overlayFontFacesRequested = true;
    try {
      chrome.runtime.sendMessage({ type: 'subtitleFonts' }, function (resp) {
        if (chrome.runtime.lastError || !resp || !resp.ok) { overlayFontFacesRequested = false; return; }
        injectOverlayFontFaces(resp.fonts);
      });
    } catch (_) { overlayFontFacesRequested = false; }
  }
  function injectOverlayFontFaces(fonts) {
    if (!window.fushiSubtitleStyle || typeof window.fushiSubtitleStyle.fontFaceCss !== 'function') return;
    var css = window.fushiSubtitleStyle.fontFaceCss(fonts);
    if (!css || css === overlayFontFacesCss) return;
    overlayFontFacesCss = css;
    var el = document.getElementById(OVERLAY_FONT_FACES_ID);
    if (!el) {
      el = document.createElement('style');
      el.id = OVERLAY_FONT_FACES_ID;
      (document.head || document.documentElement).appendChild(el);
    }
    el.textContent = css;
  }

  // 只在 cue 换了才重建文本节点（见 st.overlayRenderedCue）。同一条 cue 的重复调用是 no-op，
  // 用户在字幕上拖出的原生选区才能活过每 200ms 的 tick。
  function renderOverlayCue(cue) {
    var target = st.overlayTextEl || st.overlayEl;
    if (!target) return;
    var prev = st.overlayRenderedCue;
    if (prev === cue || (prev && cue && prev.text === cue.text && prev.ruby === cue.ruby)) return;
    st.overlayRenderedCue = cue;
    if (typeof window.fushiRenderCueText === 'function') window.fushiRenderCueText(target, cue);
    else target.textContent = cue.text;
  }

  function hideSubtitleOverlay() {
    st.overlayCue = null;
    st.overlayRenderedCue = null;
    if (st.overlayEl && st.overlayEl.parentNode) st.overlayEl.parentNode.removeChild(st.overlayEl);
  }

  function updateSubtitleOverlay(cue) {
    // 外挂轨恒显示；检测轨（站点自带字幕）默认不重复叠字，除非用户开了「全轨覆盖层」
    // （overlayAllTracks，配合防剧透模糊/悬浮字幕自动查词使用）或「替代原生字幕」——
    // 后者本来就是「原生藏掉、这里补上整句」，此时不叠字反而是空屏。
    if (!st.overlayEnabled || !cue ||
        (!isExternalLang(st.activeLang) && !st.overlayAllTracks && !replaceNativeEffective())) {
      hideSubtitleOverlay();
      return;
    }
    var video = videoEl();
    // 先重挂父级再走测量：退出全屏那一刻若 rect 恰好坏掉（播放器挪树/隐藏的瞬间），
    // 浮层节点绝不能滞留在旧 fullscreenElement 里——那正是下一次显示时的错位源。
    if (st.overlayEl) {
      var reparent = parentForOverlay();
      if (st.overlayEl.parentNode !== reparent) reparent.appendChild(st.overlayEl);
    }
    if (!video || typeof video.getBoundingClientRect !== 'function') return;
    var rect = video.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) return;
    var el = ensureSubtitleOverlay();
    st.overlayCue = cue;
    el.setAttribute('data-theme', resolveTheme());
    applyOverlayBackground(el);
    applyOverlayStyle(el);
    renderOverlayCue(cue);
    placeOverlay(el, rect, currentOverlayPos());
    applyOverlayBlur(el);
  }

  // 本刻应生效的位置：拖动中用会话里的实时值（tick 每 200ms 重摆也不会把字幕拽回原位），
  // 否则用持久化的用户位置，没拖过走默认。
  function currentOverlayPos() {
    if (st.overlayDrag && st.overlayDrag.pos) return st.overlayDrag.pos;
    if (st.overlayResize && st.overlayResize.pos) return st.overlayResize.pos;
    return st.overlayPos || OVERLAY_POS_DEFAULT;
  }

  // 本刻应生效的外观：缩放拖拽中用会话里的实时尺寸（tick 每 200ms 重摆也不会把盒子弹回原大小），
  // 否则用持久化的设置。
  function currentOverlayStyle() {
    if (st.overlayResize && st.overlayResize.style) return st.overlayResize.style;
    return st.overlayStyle;
  }

  // 把分数坐标落成像素。x 是水平中心、y 是底边锚点（CSS transform 是 translate(-50%,-100%)）。
  function placeOverlay(el, rect, pos) {
    // 中心贴视频（抽屉拖动跟随的关键；上一版把中心夹到视口中央，就是「字幕不跟拖拉」的病根）；行宽从
    // 中心向两侧屏缘撑开、被较近一侧屏缘夹住：非全屏小播放器左右空 → 撑到近满屏不折行；全屏开
    // 抽屉 → 近侧即屏缘，行宽约等视频盒，永不探进抽屉盖画面（60% 上限保证最窄视频区也 ≥40% 屏）。
    // 用户把字幕拖向屏缘时同一条规则让行宽收窄折行，永远不出视口。
    var vv = window.innerWidth || (rect.left + rect.right);
    var cx = rect.left + rect.width * pos.x;
    var halfToEdge = Math.max(0, Math.min(cx, vv - cx));
    var maxW = Math.max(200, Math.min(vv * 0.94, (halfToEdge - 6) * 2));
    el.style.left = cx + 'px';
    // 底边锚定：文本块从这条线**往上**长。旧版中心锚 84% 时，非全屏矮视频（~200px 高）会垂出
    // 视频底缘压住进度条——底锚后任何视频高度都出不了界。
    el.style.top = (rect.top + rect.height * pos.y) + 'px';
    el.style.maxWidth = Math.round(maxW) + 'px';
    // 底板宽 / 高（外观设置 boxWidth / boxHeight，视频盒的百分比；0 = 随内容）。是视频盒的比例
    // 而非视口的，所以不能交给 CSS 百分比，随每次重摆按当前 rect 折 px；宽仍被上面的 max-width
    // 夹住，永远不出视口。subtitle-style.js 缺席（旧测试壳）时不写，观感同旧版。
    if (window.fushiSubtitleStyle && typeof window.fushiSubtitleStyle.applyBox === 'function') {
      var style = currentOverlayStyle();
      window.fushiSubtitleStyle.applyBox(el, style, rect);
      fitOverlayText(el, style, rect);
    }
  }

  // 自适应缩放：把整句缩放到「底板里刚好放下」（实现在 subtitle-style.js fitTextInto，与
  // options 预览共用）。每 200ms 的 tick 都会路过 placeOverlay，所以按「句子 + 底板像素」记忆：
  // 没变就一轮都不跑——每轮都要读 scrollHeight，那是一次强制同步重排。
  var overlayFitKey = null;
  // 节点上当前是否实际写着一个非 1 的倍率。记忆键管「要不要重算」，它管「要不要清」——
  // 两者不能合并：关掉开关走的是 applySubtitlePreferences，那里刚把记忆键置空，再拿记忆键
  // 当「没写过」就会把上一句算出的倍率永久留在节点上；反过来每个 tick 都无条件清一次，又违反了
  // 「同一份设置不重复写 style」。
  var overlayFitApplied = false;
  function fitOverlayText(el, style, frame) {
    var SUB = window.fushiSubtitleStyle;
    var text = st.overlayTextEl;
    if (!el || !text || !SUB || typeof SUB.fitTextInto !== 'function') return;
    if (!SUB.fitEnabled(style)) {
      // 关掉自适应 / 底板改回随内容：把倍率交还 CSS，字号回到用户设的「大小」。
      overlayFitKey = null;
      if (overlayFitApplied) { SUB.applyFit(el, 1); overlayFitApplied = false; }
      return;
    }
    var box = SUB.boxPx(style, frame);
    if (!(box.minHeight > 0)) return;
    var cue = st.overlayRenderedCue;
    var key = (cue ? (cue.text || '') + '|' + (cue.ruby || '') : '') +
      '|' + box.width + 'x' + box.minHeight;
    if (key === overlayFitKey) return;
    overlayFitKey = key;
    overlayFitApplied = SUB.fitTextInto(el, text, style, frame) !== 1;
  }

  // 把拖到的像素点夹回视频盒内再换算成分数：中心至少离视频左右缘 8px；底边锚不低于视频底缘、
  // 不高于「文本块整个还在视频里」的那条线（块高未知/为 0 时退化为不高于视频顶缘）。
  function overlayPosFromPoint(el, rect, cx, by) {
    var pad = Math.min(8, rect.width / 2);
    cx = Math.min(rect.right - pad, Math.max(rect.left + pad, cx));
    var h = el && typeof el.offsetHeight === 'number' ? el.offsetHeight : 0;
    var minBy = rect.top + Math.min(h, rect.height);
    by = Math.min(rect.bottom, Math.max(minBy, by));
    return { x: (cx - rect.left) / rect.width, y: (by - rect.top) / rect.height };
  }

  // ── 覆盖层拖拽：按住字幕拖动即挪位；松手按视频分数坐标持久化，点击（位移 < 阈值）仍是查词 ──
  // 监听挂 window 而不只靠 setPointerCapture：老内核上 capture 静默失败过（见 mobile-drawer.js），
  // 挂 window 全程收得到 move/up；capture 仍尝试一下，多一层保险。
  function overlayPointerDown(e) {
    if (e.button !== undefined && e.button !== null && e.button !== 0) return;
    // 按在缩放把手上是改尺寸，不是挪位——触屏整块可拖那条路也必须先让开，否则把手在触屏上
    // 永远只会把字幕拖走（用户看到「右下角拉不动，一碰就整条跑了」）。
    if (isOverlayResize(e.target)) return;
    // 鼠标：只有按在拖柄上才是挪字幕，按在文字上是原生拖选（复制）——两者都要，不能让挪位
    // 独占整块。触屏/触控笔没有拖选，整块仍可拖（长按选词由系统菜单管）。
    var touchLike = !!e.pointerType && e.pointerType !== 'mouse';
    if (!touchLike && !isOverlayGrip(e.target)) return;
    if (st.overlayDrag) endOverlayDrag(false);
    st.overlayDragMoved = false;
    var from = st.overlayPos || OVERLAY_POS_DEFAULT;
    st.overlayDrag = {
      id: e.pointerId, x0: e.clientX, y0: e.clientY,
      from: from, pos: null, moved: false,
    };
    window.addEventListener('pointermove', overlayPointerMove);
    window.addEventListener('pointerup', overlayPointerUp);
    window.addEventListener('pointercancel', overlayPointerCancel);
    try { if (st.overlayEl) st.overlayEl.setPointerCapture(e.pointerId); } catch (_) {}
    // 不 preventDefault：让点击/取词的默认链路照常；过阈值进入拖动后才接管。
  }
  function overlayPointerMove(e) {
    var d = st.overlayDrag;
    if (!d || e.pointerId !== d.id) return;
    var dx = e.clientX - d.x0, dy = e.clientY - d.y0;
    if (!d.moved) {
      if (dx * dx + dy * dy < OVERLAY_DRAG_THRESHOLD * OVERLAY_DRAG_THRESHOLD) return;
      d.moved = true;
      if (st.overlayEl) st.overlayEl.setAttribute('data-dragging', '');
      // 过阈值前浏览器可能已经拉出一小段文字选区（覆盖层 user-select:text），拖动一开始就清掉。
      try { window.getSelection().removeAllRanges(); } catch (_) {}
    }
    var video = videoEl();
    if (!video || typeof video.getBoundingClientRect !== 'function') return;
    var rect = video.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) return;
    d.pos = overlayPosFromPoint(st.overlayEl, rect,
      rect.left + rect.width * d.from.x + dx, rect.top + rect.height * d.from.y + dy);
    if (st.overlayEl && st.overlayCue) placeOverlay(st.overlayEl, rect, d.pos);
    try { e.preventDefault(); } catch (_) {}
  }
  function overlayPointerUp(e) {
    var d = st.overlayDrag;
    if (!d || e.pointerId !== d.id) return;
    endOverlayDrag(true);
  }
  function overlayPointerCancel(e) {
    var d = st.overlayDrag;
    if (!d || e.pointerId !== d.id) return;
    endOverlayDrag(false);
  }
  // commit=true：把会话位置写成用户位置并持久化；false（取消/面板关闭）：丢弃、回到原位。
  function endOverlayDrag(commit) {
    var d = st.overlayDrag;
    if (!d) return;
    st.overlayDrag = null;
    window.removeEventListener('pointermove', overlayPointerMove);
    window.removeEventListener('pointerup', overlayPointerUp);
    window.removeEventListener('pointercancel', overlayPointerCancel);
    if (st.overlayEl) {
      try { st.overlayEl.removeAttribute('data-dragging'); } catch (_) {}
    }
    if (!d.moved) return;
    // 真拖过：紧随其后的那次合成 click 要吞掉（不查词）。下一次 pointerdown 会清这个标记，
    // 所以拖出界没产生 click 也不会误吞后面无关的点击。
    st.overlayDragMoved = true;
    if (commit && d.pos) {
      st.overlayPos = d.pos;
      var patch = {};
      patch[OVERLAY_POS_KEY] = d.pos;
      try { chrome.storage.local.set(patch); } catch (_) {}
    }
    if (st.overlayCue) updateSubtitleOverlay(st.overlayCue);
  }

  // ── 覆盖层缩放：右下角把手拖拽改底板大小（与查词弹窗右下角把手同一手势） ──
  //
  // 锚点约定：覆盖层是「水平中心 + 底边」锚定的（transform: translate(-50%,-100%)），而一个
  // 右下角把手该有的手感是**左上角钉住、右下角跟手**。所以一次拖拽同时改两样东西：尺寸
  // （subtitleStyle.boxWidth/boxHeight，视频盒百分比）和位置（subtitleOverlayPosition，让左上角
  // 停在原处）。两者各自落进自己既有的真相源，不新增第三份尺寸存档。
  //
  // 尺寸的夹取全部走 subtitle-style.js 的 boxFromPx（= options 两根滑杆的同一处 clampBox），
  // 拖拽写不出滑杆写不出的值。
  function overlayResizePointerDown(e) {
    if (e.button !== undefined && e.button !== null && e.button !== 0) return;
    var SUB = window.fushiSubtitleStyle;
    if (!SUB || typeof SUB.boxFromPx !== 'function') return;
    var el = st.overlayEl;
    var video = videoEl();
    if (!el || !video || typeof video.getBoundingClientRect !== 'function') return;
    var rect = video.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) return;
    var box = typeof el.getBoundingClientRect === 'function' ? el.getBoundingClientRect() : null;
    if (!box || !(box.width > 0) || !(box.height > 0)) return;
    if (st.overlayDrag) endOverlayDrag(false);
    if (st.overlayResize) endOverlayResize(false);
    st.overlayDragMoved = false;
    st.overlayResize = {
      id: e.pointerId,
      // 钉住的左上角（视口坐标）；拖拽全程不动，尺寸与位置都由它 + 指针算出来。
      left: box.left, top: box.top,
      // 按下点：与挪位拖柄同一条 [OVERLAY_DRAG_THRESHOLD] 位移门用的参照。
      startX: e.clientX, startY: e.clientY,
      style: null, pos: null, moved: false,
    };
    window.addEventListener('pointermove', overlayResizePointerMove);
    window.addEventListener('pointerup', overlayResizePointerUp);
    window.addEventListener('pointercancel', overlayResizePointerCancel);
    try { st.overlayResizeEl.setPointerCapture(e.pointerId); } catch (_) {}
    // 把手上的按下不该冒泡给宿主播放器（Netflix/YouTube 会当「点画面」暂停），也不该让
    // 浏览器顺手拉选区。
    try { e.stopPropagation(); e.preventDefault(); } catch (_) {}
  }

  function overlayResizePointerMove(e) {
    var d = st.overlayResize;
    if (!d || e.pointerId !== d.id) return;
    var SUB = window.fushiSubtitleStyle;
    var video = videoEl();
    if (!SUB || !video || typeof video.getBoundingClientRect !== 'function') return;
    var rect = video.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) return;
    if (!d.moved) {
      // 位移门（与挪位拖柄同一条 [OVERLAY_DRAG_THRESHOLD]）：缺了它，「点一下把手」
      // 或触屏上双击复位的每一次按下，都会在第一个 pointermove 上无条件 commit——
      // 把 boxWidth/boxHeight 从「随内容」(0) 静默写成当前实测尺寸。之后长句在这个
      // 固定窄盒里折行，fitTextInto 一路压到下限，用户看到的是「碰了下右下角，字幕
      // 突然变成小蚂蚁」。触屏上把手是唯一的改大小入口，抖动概率更高。
      var ddx = e.clientX - d.startX;
      var ddy = e.clientY - d.startY;
      if (ddx * ddx + ddy * ddy < OVERLAY_DRAG_THRESHOLD * OVERLAY_DRAG_THRESHOLD) {
        return;
      }
      d.moved = true;
      if (st.overlayEl) st.overlayEl.setAttribute('data-resizing', '');
      try { window.getSelection().removeAllRanges(); } catch (_) {}
    }
    // 指针先夹进视频盒：拖到画面外不该换来一个探出画面的底板（宽高自己还有上下限，但那是
    // 百分比上限，落在靠边的位置上照样能探出去）。
    var px = Math.min(rect.right, Math.max(rect.left, e.clientX));
    var py = Math.min(rect.bottom, Math.max(rect.top, e.clientY));
    var box = SUB.boxFromPx(px - d.left, py - d.top, rect);
    if (!box) return;
    var base = st.overlayStyle && typeof st.overlayStyle === 'object' ? st.overlayStyle : {};
    var next = SUB.normalize(Object.assign({}, base, box));
    // 夹取后的真实像素（不是指针位置）才是左上角钉住时该有的中心 / 底边——否则一旦撞上下限，
    // 盒子的实际边缘与用户持续移动的指针就会脱节，松手位置也跟着漂。
    var pxBox = SUB.boxPx(next, rect);
    var wpx = pxBox.width > 0 ? pxBox.width : (px - d.left);
    var hpx = pxBox.minHeight > 0 ? pxBox.minHeight : (py - d.top);
    d.style = next;
    d.pos = clampOverlayPos({
      x: (d.left + wpx / 2 - rect.left) / rect.width,
      y: (d.top + hpx - rect.top) / rect.height,
    });
    if (st.overlayEl && st.overlayCue) placeOverlay(st.overlayEl, rect, d.pos);
    try { e.preventDefault(); } catch (_) {}
  }

  function overlayResizePointerUp(e) {
    var d = st.overlayResize;
    if (!d || e.pointerId !== d.id) return;
    endOverlayResize(true);
  }
  function overlayResizePointerCancel(e) {
    var d = st.overlayResize;
    if (!d || e.pointerId !== d.id) return;
    endOverlayResize(false);
  }

  // commit=true：把会话里的尺寸 + 位置写成用户设置并落盘；false（取消/面板关闭）：丢弃回原样。
  function endOverlayResize(commit) {
    var d = st.overlayResize;
    if (!d) return;
    st.overlayResize = null;
    window.removeEventListener('pointermove', overlayResizePointerMove);
    window.removeEventListener('pointerup', overlayResizePointerUp);
    window.removeEventListener('pointercancel', overlayResizePointerCancel);
    if (st.overlayEl) {
      try { st.overlayEl.removeAttribute('data-resizing'); } catch (_) {}
    }
    if (!d.moved) return;
    // 真拖过：吞掉紧随其后的合成 click（否则每次缩放完都顺手查一次词）。
    st.overlayDragMoved = true;
    if (commit && d.style) {
      st.overlayStyle = d.style;
      writeOverlayStyle(d.style);
      if (d.pos) {
        st.overlayPos = d.pos;
        var patch = {};
        patch[OVERLAY_POS_KEY] = d.pos;
        try { chrome.storage.local.set(patch); } catch (_) {}
      }
    }
    overlayFitKey = null; // 尺寸变了（或被撤销）：下一次重摆必须重算自适应倍率
    if (st.overlayCue) updateSubtitleOverlay(st.overlayCue);
  }

  // 双击把手：底板宽高回到「随内容」，位置不动。
  function resetOverlayBox() {
    var SUB = window.fushiSubtitleStyle;
    if (!SUB) return;
    var base = st.overlayStyle && typeof st.overlayStyle === 'object' ? st.overlayStyle : {};
    if (!(SUB.normalize(base).boxWidth > 0) && !(SUB.normalize(base).boxHeight > 0)) return;
    var next = SUB.normalize(Object.assign({}, base, { boxWidth: 0, boxHeight: 0 }));
    st.overlayStyle = next;
    writeOverlayStyle(next);
    overlayFitKey = null;
    if (st.overlayEl) { SUB.applyFit(st.overlayEl, 1); overlayFitApplied = false; }
    if (st.overlayCue) updateSubtitleOverlay(st.overlayCue);
  }

  // 落盘外观设置。与 options 页同一约定：整份回到默认就删键（而不是存一份等值副本），
  // 免得以后改默认值时老用户被旧副本钉住。
  function writeOverlayStyle(style) {
    var SUB = window.fushiSubtitleStyle;
    if (!SUB) return;
    try {
      if (SUB.isDefault(style)) chrome.storage.local.remove(OVERLAY_STYLE_KEY);
      else {
        var patch = {};
        patch[OVERLAY_STYLE_KEY] = style;
        chrome.storage.local.set(patch);
      }
    } catch (_) {}
  }

  // 分数位置的公共夹取（拖拽落点走 overlayPosFromPoint，缩放算出来的锚点走这里）。
  function clampOverlayPos(pos) {
    return {
      x: Math.min(1, Math.max(0, pos.x)),
      y: Math.min(1, Math.max(0, pos.y)),
    };
  }

  function firstCueAfter(ms) {
    var lo = 0, hi = st.cues.length - 1, ans = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (st.cues[mid].startMs > ms) { ans = mid; hi = mid - 1; } else { lo = mid + 1; }
    }
    return ans;
  }

  // 侧边栏打不开时给用户的可见出路。chrome.sidePanel.open() 要求瞬态用户激活，而内容脚本
  // 既没有 sidePanel API，用户激活也不随 runtime 消息传到 service worker——页面内的按键/拖放
  // 因此永远开不了原生侧边栏。与其静默什么都不发生，不如直说唯一可用入口。
  var panelHintAt = 0;
  function hintPanelOpen() {
    var now = Date.now();
    if (now - panelHintAt < 3000) return; // 同一次操作只提示一次，避免连点刷屏
    panelHintAt = now;
    toast(tr('panel_open_hint'));
  }

  // notify=true：这是用户显式的「打开侧边栏」动作，失败必须给可见提示。
  // notify 省略：只是顺带刷新（加载外挂字幕、拖放落地），失败不抢占它们自己的 toast。
  // 返回值 = 是否已经把这次交互「办成了」。桌面内容脚本这一侧永远办不成（原因见上）恒 false，
  // video-shortcuts.js 据此不 preventDefault 放行站点；触屏抽屉真开了才返回 true（吞键合理）。
  function showPanel(notify) {
    refreshHeadless();
    // 触屏设备没有 chrome.sidePanel（桌面独有 API）：页内抽屉契约存在（mobile-drawer.js）
    // 就改拉抽屉，并如实返回 true——抽屉确实开了，Shift+S 该吞键。桌面契约恒缺失，原样走。
    try {
      if (typeof window.fushiMobileDrawerOpen === 'function' && window.fushiMobileDrawerOpen()) {
        if (notify) toast(tr('panel_opened'));
        return true;
      }
    } catch (_) {}
    try {
      chrome.runtime.sendMessage({ type: 'openSubtitleSidePanel' }, function (resp) {
        var failed = true;
        try { failed = !!chrome.runtime.lastError || !resp || resp.ok !== true; } catch (_) {}
        if (failed && notify) hintPanelOpen();
      });
    } catch (_) { if (notify) hintPanelOpen(); }
    return false;
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
    requestLazyIfPending(active);
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
      toast(tr('subtitle_file_too_large'));
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
              if (chrome.runtime.lastError) { toast(tr('subtitle_load_failed_offline')); return; }
              applyExternalSubtitle(file.name, resp);
            } catch (_) {}
          });
      } catch (_) { toast(tr('subtitle_load_failed')); }
    };
    reader.onerror = function () { toast(tr('subtitle_read_failed')); };
    try { reader.readAsText(file); } catch (_) { toast(tr('subtitle_read_failed')); }
  }
  function applyExternalSubtitle(filename, resp) {
    if (!resp || !resp.ok || !resp.data) { toast(connectionFailureText(resp, tr('subtitle_parse_failed'))); return; }
    if (resp.data.error === 'unsupported') { toast(tr('subtitle_unsupported_format')); return; }
    var raw = Array.isArray(resp.data.cues) ? resp.data.cues : [];
    var base = [];
    for (var i = 0; i < raw.length; i++) {
      var c = raw[i];
      if (!c || typeof c.startMs !== 'number' || typeof c.endMs !== 'number') continue;
      var text = String(c.text || '');
      if (!text) continue;
      base.push({ startMs: c.startMs, endMs: c.endMs, text: text });
    }
    if (!base.length) { toast(tr('subtitle_empty')); return; }
    var label = EXT_PREFIX + String(filename).replace(/\|/g, '_');
    var key = videoKey() + '|' + label;
    // 外挂轨与检测轨同构：store 存原始 cue，偏移走统一的读取侧 trackOffsets（重新加载即归零）。
    var store = window.fushiEpisodeCues || (window.fushiEpisodeCues = Object.create(null));
    store[key] = base;
    delete st.trackOffsets[key];
    st.activeLang = label;
    showPanel();
    toast(tr('subtitle_external_loaded', { n: base.length }));
  }

  function connectionFailureText(resp, fallback) {
    var c = resp && resp.connection;
    if (!c) return fallback;
    if (c.state === 'yomitan-conflict') return tr('conn_yomitan_conflict', { port: c.port || 19633 });
    if (c.state === 'unauthorized') return tr('conn_unauthorized');
    if (c.state === 'offline') return tr('conn_api_off');
    return fallback;
  }

  function isSubtitleFile(file) {
    return !!(file && /\.(srt|ass|ssa|vtt)$/i.test(String(file.name || '')));
  }

  // 拖放导入的生效判据：这一页确实在放视频。没有 <video> 的普通网页（网盘上传、邮箱附件、
  // 图床）一律不介入——连 dragover 的 preventDefault 都不做，宿主页的拖放行为零改动。
  function dragDropActive() { return st.dragDropEnabled && !!videoEl(); }

  function showDropHint() {
    if (!st.dropHint) {
      st.dropHint = document.createElement('div');
      st.dropHint.id = 'fushi-subtitle-drop-hint';
      st.dropHint.textContent = tr('subtitle_drop_hint');
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
    if (!dragDropActive() || !e.dataTransfer) return;
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
    if (!dragDropActive()) return;
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
    toast(tr('subtitle_offset_toast', { offset: fmtOffset(trackOffset(key)) }));
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
    toast(tr('subtitle_copied', { text: text.length > 30 ? text.slice(0, 30) + '…' : text }));
    return true;
  }
  function shortcutTogglePanel() {
    if (!st.enabled) {
      try { chrome.storage.local.set({ netflixSubtitlePanel: true }); } catch (_) {}
      applyEnabled(true);
    }
    // 原实现无条件 return true → video-shortcuts.js 据此 preventDefault：用户按下 Shift+S 后
    // 按键被吃、站点原生快捷键也没了、屏幕上什么都没发生。showPanel(true) 恒返回 false 并在
    // 打开失败时 toast 明确出路，这里如实透传：不吞按键 + 有可见反馈。
    return showPanel(true);
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

  // 制卡链路（content.js fushiFullTrackWindowAt）按播放时间到整轨取精确窗时要跟面板看到的
  // 是同一份：已应用用户设的时轴偏移，语言也是用户正在读的那条。live 伪轨不对外——它是
  // 降级来源，content.js 自己有 DOM 采样兜底，不需要绕经这里。
  window.fushiActiveFullTrack = function () {
    if (!st.activeLang || st.activeLang === LIVE_LANG) return null;
    if (!st.cues || !st.cues.length) return null;
    return { lang: st.activeLang, cues: st.cues };
  };

  // 学习统计的字幕门（study-tracker.js）唯一的状态来源。网页视频的观看时长默认只在
  // 「Fushi 真的在给用户出字幕」时才计：用户开着站点原生字幕、或者根本没有字幕的视频，
  // 沉浸时间对学习没有意义，混进统计只会把日语沉浸曲线稀释成刷视频曲线。
  //   showing = 当前活动轨是整集轨（Fushi 抓到的站点轨）或外挂字幕轨，且真有 cue。
  //             面板/侧边栏/覆盖层任一在用都会把 activeLang 设上（refreshHeadless），
  //             没打开过 Fushi 字幕的页面这里恒 false —— 这正是默认档要的语义。
  //   any     = 这个视频存在任何一条 Fushi 认得出的轨（含 DOM 采样 live 轨与按需加载的
  //             占位轨），不要求用户已经在读 —— 放宽档用。
  window.fushiSubtitleStudyState = function () {
    var tracks = [];
    try { tracks = tracksForVideo(); } catch (_) { tracks = []; }
    // st.enabled 必须进判据：applyEnabled(false) → sync() → teardownAll() 会撤掉
    // 覆盖层、放回站点原生字幕，但**不清** activeLang / cues（tick 在 !enabled 时
    // 直接 return，留着是为了重开时不用重抓）。不看它，用户看片中途关掉字幕面板后
    // 门仍报 showing=true，沉浸统计会一直计到换视频或刷新。
    var lang = st.enabled ? st.activeLang : null;
    var showing = !!(lang && lang !== LIVE_LANG && st.cues && st.cues.length);
    var any = showing;
    for (var i = 0; !any && i < tracks.length; i++) {
      if ((tracks[i].cues && tracks[i].cues.length) || tracks[i].pending) any = true;
    }
    return {
      showing: showing,
      any: any,
      lang: showing ? lang : null,
      external: showing && isExternalLang(lang),
    };
  };

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
          label: track.lang === LIVE_LANG ? tr('track_live_label') : track.lang,
          length: track.cues.length,
          pending: !!track.pending,
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
      if (msg.type === 'fushiSubtitleSidePanelShowLookup') {
        // 「跨出面板」：侧栏取好词后交给宿主页渲染页面弹窗（content.js 里的
        // fushiShowLookupFromSidePanel 说明了为什么面板内画不出去）。ok:false 时侧栏
        // 会退回面板内自己渲染——宿主页没有 content.js（chrome:// 等）不能变成查不了词。
        var showCue = msg.cue && typeof msg.cue === 'object' ? msg.cue : null;
        var shown = typeof window.fushiShowLookupFromSidePanel === 'function' &&
          window.fushiShowLookupFromSidePanel(
            String(msg.term || ''), showCue, msg.anchorRatio) === true;
        sendResponse({ ok: shown });
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelLookupClosed') {
        // Side Panel 查词面板关闭 → 恢复由查词暂停的视频（content.js 只恢复「确实是查词
        // 暂停的」，用户自己暂停的不动）。
        var closed = typeof window.fushiLookupClosedFromSidePanel === 'function' &&
          window.fushiLookupClosedFromSidePanel() === true;
        sendResponse({ ok: closed });
        return false;
      }
      if (msg.type === 'fushiSubtitleSidePanelCloseLookup') {
        // 侧栏按 Esc：关掉宿主页上那份侧栏交出去的弹窗（面板内那份侧栏自己关）。
        var closedPage = typeof window.fushiCloseLookupFromSidePanel === 'function' &&
          window.fushiCloseLookupFromSidePanel() === true;
        sendResponse({ ok: closedPage });
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
    // 全屏切换后播放器整体挪位（body transform/滚动锁很常见）：立刻重测重摆一次，
    // 不等下一个 200ms tick——重挂父级（fsEl↔html）也在这一步完成。
    if (st.overlayCue) updateSubtitleOverlay(st.overlayCue);
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
      var keys = SUBTITLE_PREF_KEYS;
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
