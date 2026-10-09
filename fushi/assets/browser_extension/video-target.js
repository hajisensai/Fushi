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
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) {
    root.FUSHI_VIDEO_TARGET = api;
    root.fushiMainVideo = api.mainVideo;
    root.fushiFixedOrigin = api.fixedOrigin;
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

  // parent 里 position:fixed 子元素的坐标系。<html> / 无 parent 走恒等（html 自身从不被
  // transform，且它的 fixed 包含块就是视口）。
  function fixedOrigin(parent) {
    if (!parent || typeof document === 'undefined' || parent === document.documentElement) return IDENTITY;
    var probe = parent.__fushiFixedProbe;
    try {
      if (!probe) {
        probe = document.createElement('div');
        probe.className = PROBE_CLASS;
        probe.setAttribute('aria-hidden', 'true');
        probe.style.cssText = 'position:fixed;left:0;top:0;width:' + PROBE_SIZE + 'px;height:' + PROBE_SIZE +
          'px;margin:0;padding:0;border:0;visibility:hidden;pointer-events:none;contain:strict;';
        parent.__fushiFixedProbe = probe;
      }
      // 插在最前：浮层自己要留在 parent 的最后（同 z-index 时 DOM 靠后者在上）。
      if (probe.parentNode !== parent) parent.insertBefore(probe, parent.firstChild || null);
      return originFromProbeRect(probe.getBoundingClientRect());
    } catch (_) {
      return IDENTITY;
    }
  }

  // 视口坐标 → parent 内 fixed 坐标。
  function toFixed(origin, x, y) {
    var o = origin || IDENTITY;
    return { left: (x - o.x) / o.sx, top: (y - o.y) / o.sy };
  }

  return {
    pickMainVideo: pickMainVideo,
    mainVideo: mainVideo,
    fixedOrigin: fixedOrigin,
    originFromProbeRect: originFromProbeRect,
    toFixed: toFixed,
    PROBE_CLASS: PROBE_CLASS,
  };
});
