// 视频页浮层的「跟谁定位」与「坐标系」——不依赖任何站点 DOM（content script 隔离世界）。
//
// 用户群 10-09：悬浮小图标只在 YouTube 上位置正常，别的站（如 anichan.to）会乱飞；全屏字幕
// 也只在 YouTube 上适配过。两处浮层（player-controls.js 的通用悬浮按钮 / 菜单、subtitle-panel.js
// 的字幕覆盖层）此前有两个共同的站点假设：
//   ① 「正片」= `document.querySelector('video')`，即文档里**第一个** <video>。YouTube 的第一个
//      恰好是正片；别的站常把预告片、广告位、进度条缩略图预览、首页悬停预览的 <video> 排在前面，
//      浮层就贴到了那个看不见 / 很小 / 在页面别处的元素上。
//   ② position:fixed 的坐标 = 视口坐标。浮层挂在全屏元素（或 body）里，而站点常给播放器容器
//      / body 加 transform、filter、will-change（全屏切换动画、滚动锁、硬件加速）——那时 fixed 的
//      包含块变成该祖先，视口坐标落进歪掉的坐标系，浮层整体偏移甚至被推出屏幕。
// 本模块只解决这两件事，判据全部来自 DOM 几何本身：
//   · mainVideo()：全屏时取全屏元素本身（它就是 <video>）或其内部可见面积最大的 <video>；不全屏时
//     取视口内可见面积最大的（正在播放的优先）。都没有可见面积时退回第一个 <video>（旧行为）。
//   · fixedOrigin(parent)：在 parent 里放一个零干扰的 fixed 探针，量出 fixed 子元素的包含块原点
//     与缩放，调用方把视口坐标折算成该坐标系再写 left/top。parent 是 <html> 时恒为恒等变换。
//   · 视频锚定（BUG-3450，window.fushiVideoAnchor）：挂载点 / 定位方式（absolute 随文档滚动，
//     视频在 fixed 祖先里才用 fixed）/ 共享 rAF 帧观察，字幕覆盖层与通用悬浮按钮共用，见下文。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) {
    root.FUSHI_VIDEO_TARGET = api;
    root.fushiMainVideo = api.mainVideo;
    root.fushiFixedOrigin = api.fixedOrigin;
    root.fushiVideoAnchor = { host: api.overlayHost, mode: api.anchorMode, placeAt: api.placeAt, watch: api.watch };
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 纯函数：从候选里挑正片。candidates = [{el, rect:{left,top,width,height}, playing}]，
  // viewport = {width, height}。可见面积 = 与视口的交集；在播的权重 ×2（同屏两个大视频时
  // 跟着用户正在看的那个走）。全部不可见返回 null（调用方回落）。
  function pickMainVideo(candidates, viewport) {
    var vw = viewport && viewport.width > 0 ? viewport.width : Infinity;
    var vh = viewport && viewport.height > 0 ? viewport.height : Infinity;
    var best = null;
    var bestScore = 0;
    for (var i = 0; i < (candidates || []).length; i++) {
      var c = candidates[i];
      var r = c && c.rect;
      if (!r || !(r.width > 0) || !(r.height > 0)) continue;
      var w = Math.min(r.left + r.width, vw) - Math.max(r.left, 0);
      var h = Math.min(r.top + r.height, vh) - Math.max(r.top, 0);
      if (w <= 0 || h <= 0) continue;
      var score = w * h * (c.playing ? 2 : 1);
      if (score > bestScore) { best = c.el; bestScore = score; }
    }
    return best;
  }

  function isPlaying(v) {
    try { return !!v && !v.paused && !v.ended && v.readyState > 2; } catch (_) { return false; }
  }

  function mainVideo() {
    if (typeof document === 'undefined') return null;
    var fs = null;
    try { fs = document.fullscreenElement || null; } catch (_) { fs = null; }
    if (fs && String(fs.tagName || '').toUpperCase() === 'VIDEO') return fs;
    var list = [];
    try {
      var all = document.querySelectorAll ? document.querySelectorAll('video') : null;
      if (all) for (var i = 0; i < all.length; i++) list.push(all[i]);
    } catch (_) { list = []; }
    if (fs && list.length) {
      var inside = list.filter(function (v) { try { return fs.contains(v); } catch (_) { return false; } });
      if (inside.length) list = inside;
    }
    var viewport = {
      width: (typeof window !== 'undefined' && window.innerWidth) || 0,
      height: (typeof window !== 'undefined' && window.innerHeight) || 0,
    };
    var candidates = [];
    for (var j = 0; j < list.length; j++) {
      var rect = null;
      try { rect = list[j].getBoundingClientRect(); } catch (_) { rect = null; }
      candidates.push({ el: list[j], rect: rect, playing: isPlaying(list[j]) });
    }
    var picked = pickMainVideo(candidates, viewport);
    if (picked) return picked;
    if (list.length) return list[0];
    try { return document.querySelector('video'); } catch (_) { return null; }
  }

  var IDENTITY = { x: 0, y: 0, sx: 1, sy: 1 };
  var PROBE_SIZE = 100;
  var PROBE_CLASS = 'fushi-fixed-origin-probe';

  // 纯函数：探针在视口里的矩形 → 包含块变换（原点 + 缩放）。
  function originFromProbeRect(r) {
    if (!r) return IDENTITY;
    var sx = r.width > 0 ? r.width / PROBE_SIZE : 1;
    var sy = r.height > 0 ? r.height / PROBE_SIZE : 1;
    return { x: r.left || 0, y: r.top || 0, sx: sx, sy: sy };
  }

  // parent 里 position:<mode> 子元素的坐标系（mode = 'fixed' | 'absolute'）。探针与浮层同一定位
  // 方式、同一父级，量到的就是浮层自己的包含块原点：fixed 时含站点 transform 造成的偏移，absolute
  // 时还含文档滚动（<html> 里 absolute 的原点 = (-scrollX, -scrollY)）。
  // fixed + <html> 走恒等（html 自身从不被 transform，fixed 包含块就是视口），不插探针。
  // 探针几何写 !important：全屏元素 / 播放器常带 `.x>*{height:100%}` 这类通配规则（anichan），
  // 漏到探针上缩放就量错了。
  function probeOrigin(parent, mode) {
    if (typeof document === 'undefined') return IDENTITY;
    if (!parent) parent = document.documentElement;
    mode = mode === 'absolute' ? 'absolute' : 'fixed';
    if (mode === 'fixed' && parent === document.documentElement) return IDENTITY;
    var slot = mode === 'absolute' ? '__fushiAbsProbe' : '__fushiFixedProbe';
    var probe = parent[slot];
    try {
      if (!probe) {
        probe = document.createElement('div');
        probe.className = PROBE_CLASS;
        probe.setAttribute('aria-hidden', 'true');
        probe.style.cssText = 'position:' + mode + '!important;left:0!important;top:0!important;' +
          'right:auto!important;bottom:auto!important;width:' + PROBE_SIZE + 'px!important;height:' + PROBE_SIZE +
          'px!important;margin:0!important;padding:0!important;border:0!important;transform:none!important;' +
          'visibility:hidden!important;pointer-events:none!important;contain:strict;';
        parent[slot] = probe;
      }
      // 插在最前：浮层自己要留在 parent 的最后（同 z-index 时 DOM 靠后者在上）。
      if (probe.parentNode !== parent) parent.insertBefore(probe, parent.firstChild || null);
      return originFromProbeRect(probe.getBoundingClientRect());
    } catch (_) {
      return IDENTITY;
    }
  }
  function fixedOrigin(parent) {
    if (!parent || typeof document === 'undefined' || parent === document.documentElement) return IDENTITY;
    return probeOrigin(parent, 'fixed');
  }

  // 视口坐标 → parent 内坐标（fixed / absolute 同一公式，差别全在 origin 里）。
  function toFixed(origin, x, y) {
    var o = origin || IDENTITY;
    return { left: (x - o.x) / o.sx, top: (y - o.y) / o.sy };
  }

  // ── 视频锚定（BUG-3450，参照 asbplayer element-overlay 的不变式） ──
  //
  // 视频上的浮层（字幕覆盖层、通用悬浮按钮）只认一样东西：正片 <video> 的视口矩形。挂在哪、
  // 用什么定位方式、何时重摆，三件事都在这里统一定，消费者只说「把我放到视口坐标 (x, y)」。
  //
  // ① 挂载点 overlayHost()：全屏时是全屏元素（顶层里只有它的子树看得见），但它本身是 <video>
  //    时退回 <html>（媒体元素的子节点是 fallback 内容，永远不渲染）；非全屏一律 <html>——
  //    body 常被站点 transform / scroll-lock（position:fixed;top:-Npx），html 不会。
  // ② 定位方式 anchorMode(video)：视频在文档流里随页面滚动（绝大多数站点）→ absolute，文档
  //    滚动时浮层由合成器跟着视频一起走，不靠脚本追帧（fixed + 滚动监听在异步滚动下总晚一帧，
  //    看起来就是「字幕 / 按钮在飘」）；视频自己在 fixed 祖先里（全屏、迷你播放器、站点的
  //    「伪全屏」）或 sticky 祖先里（吸顶播放器）→ fixed，那时视频不随滚动动，absolute 反而会被滚走。
  // ③ 重摆时机 watch()：一个共享的 rAF 循环，每帧只读一次正片矩形，变了才回调。尺寸、位置、
  //    全屏切换、站点 SPA 换掉 <video>、剧场模式、侧栏收起……任何让视频挪位的原因都在下一帧
  //    收敛，不再依赖「恰好有 scroll / resize 事件」或 200ms / 1s 轮询。
  function isMediaHost(el) {
    return !!el && String(el.tagName || '').toUpperCase() === 'VIDEO';
  }

  function overlayHost() {
    if (typeof document === 'undefined') return null;
    var fs = null;
    try { fs = document.fullscreenElement || null; } catch (_) { fs = null; }
    if (fs && !isMediaHost(fs)) return fs;
    return document.documentElement;
  }

  // 每次摆放都会问一次；祖先链的 computed style 1 秒内不重算（全屏切换 / 换了视频立即重算）。
  var modeCache = { video: null, fs: null, mode: 'fixed', at: 0 };
  function anchorMode(video) {
    if (!video) return 'fixed';
    var fs = null;
    try { fs = typeof document !== 'undefined' ? document.fullscreenElement || null : null; } catch (_) { fs = null; }
    var now = Date.now();
    if (modeCache.video === video && modeCache.fs === fs && now - modeCache.at < 1000) return modeCache.mode;
    var mode = computeAnchorMode(video);
    modeCache = { video: video, fs: fs, mode: mode, at: now };
    return mode;
  }
  function computeAnchorMode(video) {
    if (typeof window === 'undefined' || typeof window.getComputedStyle !== 'function') return 'fixed';
    var root = typeof document !== 'undefined' ? document.documentElement : null;
    var el = video;
    for (var guard = 0; el && el !== root && guard < 64; guard++) {
      var pos = '';
      try { pos = window.getComputedStyle(el).position; } catch (_) { pos = ''; }
      // sticky 祖先（吸顶 / 吸底播放器）与 fixed 同归一类：吸住期间文档在滚、视频视口矩形不变，
      // absolute 浮层会被合成器随文档滚走，而帧观察只在视频矩形变化时回调——没有任何信号把它
      // 拉回来，只能等 200ms tick / 1s 轮询。fixed 在吸住时不动；未吸住随文档滚时视频矩形每帧
      // 都在变，帧观察下一帧就重摆。
      if (pos === 'fixed' || pos === 'sticky') return 'fixed';
      el = el.parentElement || null;
    }
    return 'absolute';
  }

  function setImportant(el, prop, value) {
    var s = el.style;
    try {
      if (typeof s.setProperty === 'function') {
        var same = typeof s.getPropertyValue === 'function' && s.getPropertyValue(prop) === value &&
          (typeof s.getPropertyPriority !== 'function' || s.getPropertyPriority(prop) === 'important');
        if (!same) s.setProperty(prop, value, 'important');
        return;
      }
    } catch (_) { /* fall through */ }
    s[prop] = value;
  }

  // 把 el 摆到视口坐标 (x, y)（el 的 transform 自己决定这一点是它的哪个角 / 边）。挂载点与定位
  // 方式按当前视频现定；位置与定位方式写内联 !important：站点对全屏元素子节点的通配规则
  // （`.fs>*{position:absolute!important}` 之类）压不过内联 !important。
  // 返回 {origin, mode}：调用方用 origin 折算 max-width 等尺寸（sx / sy 是包含块缩放）。
  function placeAt(el, x, y, video) {
    if (!el || !el.style) return { origin: IDENTITY, mode: 'fixed' };
    var host = overlayHost();
    if (host && el.parentNode !== host) host.appendChild(el);
    var mode = anchorMode(video || mainVideo());
    var origin = probeOrigin(el.parentNode || host, mode);
    var p = toFixed(origin, x, y);
    setImportant(el, 'position', mode);
    setImportant(el, 'left', p.left + 'px');
    setImportant(el, 'top', p.top + 'px');
    return { origin: origin, mode: mode };
  }

  // 共享 rAF 观察：订阅者是「视频矩形变了就重摆」的回调。正片每 30 帧（或全屏切换、旧节点
  // 脱离文档时）重挑一次，平时每帧只读一次 getBoundingClientRect——布局干净时这是几微秒的读；
  // 页面在后台时 rAF 本就停。没有订阅者就停循环。
  var subscribers = [];
  var rafId = 0;
  var watched = null;
  var lastKey = '';
  var framesSincePick = 0;
  var lastFs = null;
  function rectKey(r) {
    if (!r) return '-';
    return Math.round(r.left * 2) + ',' + Math.round(r.top * 2) + ',' + Math.round(r.width * 2) + ',' +
      Math.round(r.height * 2);
  }
  function frame() {
    rafId = 0;
    if (!subscribers.length) return;
    var fs = null;
    try { fs = document.fullscreenElement || null; } catch (_) { fs = null; }
    if (!watched || watched.isConnected === false || fs !== lastFs || ++framesSincePick >= 30) {
      watched = mainVideo();
      framesSincePick = 0;
    }
    lastFs = fs;
    var r = null;
    try { r = watched && watched.getBoundingClientRect ? watched.getBoundingClientRect() : null; } catch (_) { r = null; }
    var key = rectKey(r) + '|' + (fs ? 'fs' : '') + '|' + (typeof window !== 'undefined' ? (window.innerWidth + 'x' + window.innerHeight) : '');
    if (key !== lastKey) {
      lastKey = key;
      var list = subscribers.slice();
      for (var i = 0; i < list.length; i++) {
        try { list[i](watched, r); } catch (_) { /* 一个消费者坏了不拖垮另一个 */ }
      }
    }
    schedule();
  }
  function schedule() {
    if (rafId || !subscribers.length) return;
    if (typeof requestAnimationFrame !== 'function') return;
    rafId = requestAnimationFrame(frame);
  }
  function watch(cb) {
    if (typeof cb !== 'function') return function () {};
    if (subscribers.indexOf(cb) < 0) subscribers.push(cb);
    lastKey = ''; // 新订阅者下一帧必得一次回调
    schedule();
    return function unwatch() {
      var i = subscribers.indexOf(cb);
      if (i >= 0) subscribers.splice(i, 1);
    };
  }

  return {
    pickMainVideo: pickMainVideo,
    mainVideo: mainVideo,
    fixedOrigin: fixedOrigin,
    probeOrigin: probeOrigin,
    overlayHost: overlayHost,
    anchorMode: anchorMode,
    placeAt: placeAt,
    watch: watch,
    originFromProbeRect: originFromProbeRect,
    toFixed: toFixed,
    PROBE_CLASS: PROBE_CLASS,
  };
});
