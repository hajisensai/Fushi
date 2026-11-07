// 字幕遮布（content script 隔离世界，manifest bundle 里排在 subtitle-panel.js 之后）。
//
// 网页视频（YouTube / B 站 / Netflix ……）常有烧进画面的中文硬字幕，学日语时想把它挡住、只看日文
// 字幕或 Fushi 自己的字幕层。本模块在正片 <video> 上铺一块可自定义的矩形遮布：
//
//  · **几何按「视频实际画面内容区」的比例存**（left / top / width / height ∈ 0..1）。内容区由
//    object-fit / object-position 与视频固有尺寸算出——contain 的上下 / 左右黑边（letterbox /
//    pillarbox）不算画面，所以窗口缩放、进全屏、换清晰度（固有尺寸变）之后遮布仍盖在画面同一处。
//  · **层级**：z-index 比字幕覆盖层（#fushi-subtitle-overlay，2147483637）低一级、挂载点同一个
//    （video-target.js 视频锚定：全屏时进 fullscreenElement，否则 <html>），于是 Fushi 字幕永远压在
//    遮布上面，可读可查词；遮布平时 pointer-events:none，不拦点画面 / 查词 / 站点控件。
//  · **外观**：模糊（backdrop-filter，强度可调）或纯色（scrim 色，不透明度可调）。颜色只取 theme.css
//    的 token（--fushi-scrim / --fushi-scrim-strong / --fushi-primary …），不另立色板。
//  · **编辑模式**：整块可拖、四角四边可缩放（Pointer Events，鼠标 + 触屏同一条路径；监听挂 window
//    并尝试 setPointerCapture，与字幕覆盖层拖动 / 缩放同一做法）；带「完成 / 重置」，松手即落盘。
//    编辑期间遮布临时升到字幕覆盖层之上，把手不会被字幕挡住。
//
// 设置：chrome.storage.local.subtitleMask 一个对象（与 subtitleStyle 同一存法：整份等于默认就删键）。
// 入口：设置页「字幕 → 更多选项」、播放器 Fushi 菜单（开关 + 调整遮布）、视频页快捷键。
// 上半段是纯函数（node 可测）；下半段 DOM 装配，扩展自己的页面（options）只借纯函数。
(function (root, factory) {
  var api = factory();
  try { if (typeof module !== 'undefined' && module.exports) module.exports = api; } catch (_) { /* no-op */ }
  if (root) root.FUSHI_SUBTITLE_MASK = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var KEY = 'subtitleMask';
  var APPEARANCES = ['blur', 'solid'];
  // 默认：画面底部居中，盖住大多数硬字幕所在的那一条。
  var DEFAULTS = Object.freeze({
    enabled: false,
    appearance: 'blur',
    blur: 16,
    opacity: 90,
    left: 0.15,
    top: 0.82,
    width: 0.7,
    height: 0.12,
  });
  // 模糊半径 px / 纯色不透明度 %（滑杆上下限，设置页与播放器菜单都读这里）。
  var LIMITS = Object.freeze({ blur: [2, 40], opacity: [20, 100] });
  // 遮布最小尺寸（画面比例）：缩放拖得再小也留得住一块能看见、能再抓起来的矩形。
  var MIN_WIDTH = 0.05;
  var MIN_HEIGHT = 0.03;
  // 视频门：太小的是首页悬停预览 / 卡片预告片（与 player-controls.js / study-tracker.js 同口径）。
  var MIN_VIDEO_W = 200;
  var MIN_VIDEO_H = 120;

  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)); }
  function finite(v) { return typeof v === 'number' && isFinite(v); }
  // 比例存 4 位小数：拖动算出来的浮点尾巴（0.15000000000000002）不进存储。
  function round4(v) { return Math.round(v * 10000) / 10000; }

  // 矩形（画面比例）的公共夹取：宽高先夹到 [最小, 1]，再把左上角夹到「整块仍在画面里」。
  function clampRect(r) {
    var src = r || {};
    var w = finite(Number(src.width)) ? Number(src.width) : DEFAULTS.width;
    var h = finite(Number(src.height)) ? Number(src.height) : DEFAULTS.height;
    w = clamp(w, MIN_WIDTH, 1);
    h = clamp(h, MIN_HEIGHT, 1);
    var left = finite(Number(src.left)) ? Number(src.left) : DEFAULTS.left;
    var top = finite(Number(src.top)) ? Number(src.top) : DEFAULTS.top;
    left = clamp(left, 0, 1 - w);
    top = clamp(top, 0, 1 - h);
    return { left: round4(left), top: round4(top), width: round4(w), height: round4(h) };
  }

  // 存储里的任意值 → 完整设置。坏值（旧版本写错、手改 storage）逐项回落默认，绝不让 NaN 进 style。
  // 矩形四项任一不是有限数就整块回默认：只丢一个分量会把遮布拼成用户从没摆过的形状。
  function normalize(raw) {
    var s = raw && typeof raw === 'object' ? raw : {};
    var rectOk = ['left', 'top', 'width', 'height'].every(function (k) {
      return finite(Number(s[k])) && s[k] !== null && s[k] !== '';
    });
    var rect = clampRect(rectOk ? s : DEFAULTS);
    var blur = Number(s.blur);
    var opacity = Number(s.opacity);
    return {
      enabled: s.enabled === true,
      appearance: APPEARANCES.indexOf(s.appearance) >= 0 ? s.appearance : DEFAULTS.appearance,
      blur: finite(blur) && s.blur !== null && s.blur !== '' ? Math.round(clamp(blur, LIMITS.blur[0], LIMITS.blur[1])) : DEFAULTS.blur,
      opacity: finite(opacity) && s.opacity !== null && s.opacity !== '' ? Math.round(clamp(opacity, LIMITS.opacity[0], LIMITS.opacity[1])) : DEFAULTS.opacity,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
    };
  }

  function isDefault(settings) {
    var n = normalize(settings);
    for (var k in DEFAULTS) {
      if (Object.prototype.hasOwnProperty.call(DEFAULTS, k) && n[k] !== DEFAULTS[k]) return false;
    }
    return true;
  }

  // 一次改动要落盘什么：整份等于默认就删键（与 subtitleStyle 同一纪律——否则「重置」后存储里
  // 仍留着一份等值快照，将来改了默认值老用户不跟随）。
  function writeOf(settings) {
    var n = normalize(settings);
    return isDefault(n) ? { remove: KEY, value: n } : { set: KEY, value: n };
  }

  function rectOf(settings) {
    var n = normalize(settings);
    return { left: n.left, top: n.top, width: n.width, height: n.height };
  }

  // 「重置位置」：只把矩形换回默认，开关与外观不动。
  function resetRect(settings) {
    var n = normalize(settings);
    n.left = DEFAULTS.left;
    n.top = DEFAULTS.top;
    n.width = DEFAULTS.width;
    n.height = DEFAULTS.height;
    return n;
  }

  // object-position 的一个分量 → 0..1。只认关键字与百分比；px 之类绝对值（站点几乎不用在 <video> 上）
  // 回落居中——它们需要盒尺寸才能折算，而误差最多是黑边那一截。
  function positionPart(token, axis) {
    var t = String(token || '').trim().toLowerCase();
    if (t === 'center' || t === '') return 0.5;
    if (axis === 'x' && t === 'left') return 0;
    if (axis === 'x' && t === 'right') return 1;
    if (axis === 'y' && t === 'top') return 0;
    if (axis === 'y' && t === 'bottom') return 1;
    var m = /^(-?\d+(?:\.\d+)?)%$/.exec(t);
    if (m) return Number(m[1]) / 100;
    return 0.5;
  }
  function parseObjectPosition(value) {
    var parts = String(value || '').trim().split(/\s+/).filter(Boolean);
    if (!parts.length) return { x: 0.5, y: 0.5 };
    if (parts.length === 1) parts.push('center');
    var a = parts[0].toLowerCase();
    var b = parts[1].toLowerCase();
    // 「top left」这种先写纵向关键字的顺序：交换成 x y。
    if (a === 'top' || a === 'bottom' || b === 'left' || b === 'right') { var t = a; a = b; b = t; }
    return { x: positionPart(a, 'x'), y: positionPart(b, 'y') };
  }

  // 视频盒（视口坐标，已扣掉 padding / border 的内容盒）+ 固有尺寸 + object-fit / object-position
  // → 画面实际内容区（视口坐标）。<video> 的 object-fit 缺省就是 contain。固有尺寸未知
  // （元数据还没到）时退回整个盒子——等 loadedmetadata / resize 事件再重算。
  function contentRect(box, intrinsic, objectFit, objectPosition) {
    var b = box || {};
    var bl = Number(b.left) || 0;
    var bt = Number(b.top) || 0;
    var bw = Math.max(0, Number(b.width) || 0);
    var bh = Math.max(0, Number(b.height) || 0);
    var iw = intrinsic ? Number(intrinsic.width) : 0;
    var ih = intrinsic ? Number(intrinsic.height) : 0;
    var fit = String(objectFit || 'contain').trim().toLowerCase();
    if (!(iw > 0) || !(ih > 0) || !(bw > 0) || !(bh > 0) || fit === 'fill') {
      return { left: bl, top: bt, width: bw, height: bh };
    }
    var contain = Math.min(bw / iw, bh / ih);
    var scale;
    if (fit === 'cover') scale = Math.max(bw / iw, bh / ih);
    else if (fit === 'none') scale = 1;
    else if (fit === 'scale-down') scale = Math.min(1, contain);
    else scale = contain;
    var cw = iw * scale;
    var ch = ih * scale;
    var pos = parseObjectPosition(objectPosition);
    return { left: bl + (bw - cw) * pos.x, top: bt + (bh - ch) * pos.y, width: cw, height: ch };
  }

  // 画面比例 → 视口像素。
  function toPixels(rect, content) {
    var r = clampRect(rect);
    var c = content || { left: 0, top: 0, width: 0, height: 0 };
    return {
      left: c.left + r.left * c.width,
      top: c.top + r.top * c.height,
      width: r.width * c.width,
      height: r.height * c.height,
    };
  }

  // 视口像素 → 画面比例（夹回 0..1）。内容区无面积时返回 null。
  function fromPixels(px, content) {
    var c = content || {};
    if (!(c.width > 0) || !(c.height > 0) || !px) return null;
    return clampRect({
      left: (px.left - c.left) / c.width,
      top: (px.top - c.top) / c.height,
      width: px.width / c.width,
      height: px.height / c.height,
    });
  }

  // 两矩形求交（object-fit: cover 时内容区比视频盒大，探出盒子的那截画面本就看不见，遮布也不画）。
  function clipTo(rect, bounds) {
    if (!bounds) return rect;
    var left = Math.max(rect.left, bounds.left);
    var top = Math.max(rect.top, bounds.top);
    var right = Math.min(rect.left + rect.width, bounds.left + bounds.width);
    var bottom = Math.min(rect.top + rect.height, bounds.top + bounds.height);
    return { left: left, top: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
  }

  // 编辑手势：起始矩形 + 把手方向 + 指针位移（画面比例）→ 新矩形。
  // dir = 'move' 整块平移（撞边即停，尺寸不变）；否则是 n / s / e / w 的组合（四边 + 四角）：
  // 被拖的边跟手，对边钉住，尺寸不小于最小值、不探出画面。
  function applyDrag(start, dir, dx, dy) {
    var s = clampRect(start);
    var ddx = finite(dx) ? dx : 0;
    var ddy = finite(dy) ? dy : 0;
    if (dir === 'move') {
      return clampRect({
        left: clamp(s.left + ddx, 0, 1 - s.width),
        top: clamp(s.top + ddy, 0, 1 - s.height),
        width: s.width,
        height: s.height,
      });
    }
    var d = String(dir || '');
    var left = s.left;
    var right = s.left + s.width;
    var top = s.top;
    var bottom = s.top + s.height;
    if (d.indexOf('w') >= 0) left = clamp(s.left + ddx, 0, right - MIN_WIDTH);
    if (d.indexOf('e') >= 0) right = clamp(right + ddx, left + MIN_WIDTH, 1);
    if (d.indexOf('n') >= 0) top = clamp(s.top + ddy, 0, bottom - MIN_HEIGHT);
    if (d.indexOf('s') >= 0) bottom = clamp(bottom + ddy, top + MIN_HEIGHT, 1);
    return clampRect({ left: left, top: top, width: right - left, height: bottom - top });
  }

  // 视频盒够不够大到值得铺遮布（挡掉悬停预览 / 小缩略图视频）。
  function videoQualifies(videoRect) {
    var r = videoRect || {};
    return (Number(r.width) || 0) >= MIN_VIDEO_W && (Number(r.height) || 0) >= MIN_VIDEO_H;
  }

  // 编辑工具条放哪：遮布上方放得下就上方，否则下方，两边都不够就贴在遮布里面的顶部。
  function barPlacement(px, viewportHeight, barHeight) {
    var need = (barHeight > 0 ? barHeight : 40) + 12;
    if (px.top >= need) return 'above';
    if ((viewportHeight || 0) - (px.top + px.height) >= need) return 'below';
    return 'inside';
  }

  return {
    KEY: KEY,
    DEFAULTS: DEFAULTS,
    LIMITS: LIMITS,
    APPEARANCES: APPEARANCES,
    MIN_WIDTH: MIN_WIDTH,
    MIN_HEIGHT: MIN_HEIGHT,
    clampRect: clampRect,
    normalize: normalize,
    isDefault: isDefault,
    writeOf: writeOf,
    rectOf: rectOf,
    resetRect: resetRect,
    parseObjectPosition: parseObjectPosition,
    contentRect: contentRect,
    toPixels: toPixels,
    fromPixels: fromPixels,
    clipTo: clipTo,
    applyDrag: applyDrag,
    videoQualifies: videoQualifies,
    barPlacement: barPlacement,
  };
});

// ── 视频页运行时（node 单测里 window/document 缺省 → 整段跳过；扩展自己的页面只借纯函数）──
(function () {
  'use strict';
  if (typeof window === 'undefined' || typeof document === 'undefined') return;
  if (typeof location !== 'undefined' && location && location.protocol === 'chrome-extension:') return;
  var M = (typeof self !== 'undefined' ? self : window).FUSHI_SUBTITLE_MASK;
  if (!M) return;
  var storage = null;
  try { storage = (typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local) ? chrome.storage.local : null; } catch (_) { storage = null; }
  if (!storage) return;

  var MASK_ID = 'fushi-subtitle-mask';
  var HANDLE_DIRS = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];

  function tr(key, params) {
    return (typeof window.fushiT === 'function') ? window.fushiT(key, params) : key;
  }

  var st = {
    settings: M.normalize(null),
    editing: false,
    // 进行中的手势：{id, dir, x0, y0, start, cw, ch, rect}；rect 是拖动中的实时矩形，松手才落盘。
    drag: null,
    el: null,
    barEl: null,
    video: null,
    unwatch: null,
  };

  function videoEl() {
    if (typeof window.fushiMainVideo === 'function') {
      try { var v = window.fushiMainVideo(); if (v) return v; } catch (_) { /* fallthrough */ }
    }
    try { return document.querySelector('video'); } catch (_) { return null; }
  }

  function resolveTheme() {
    if (window.fushiTheme && typeof window.fushiTheme.resolve === 'function') {
      try { return window.fushiTheme.resolve(); } catch (_) { /* fallthrough */ }
    }
    return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  }

  function px(v) { var n = parseFloat(v); return isFinite(n) ? n : 0; }

  // 正片的视口盒 / 内容盒 / 画面内容区。getBoundingClientRect 含 padding 与 border，且已乘上
  // 祖先 transform 的缩放；computed 的 padding / border 是未缩放的 CSS px，按 rect / offset 比折算。
  function measure(video) {
    if (!video || typeof video.getBoundingClientRect !== 'function') return null;
    var rect = null;
    try { rect = video.getBoundingClientRect(); } catch (_) { rect = null; }
    if (!rect || !(rect.width > 0) || !(rect.height > 0)) return null;
    var cs = null;
    try { cs = window.getComputedStyle ? window.getComputedStyle(video) : null; } catch (_) { cs = null; }
    var sx = video.offsetWidth > 0 ? rect.width / video.offsetWidth : 1;
    var sy = video.offsetHeight > 0 ? rect.height / video.offsetHeight : 1;
    var il = cs ? (px(cs.paddingLeft) + px(cs.borderLeftWidth)) * sx : 0;
    var ir = cs ? (px(cs.paddingRight) + px(cs.borderRightWidth)) * sx : 0;
    var it = cs ? (px(cs.paddingTop) + px(cs.borderTopWidth)) * sy : 0;
    var ib = cs ? (px(cs.paddingBottom) + px(cs.borderBottomWidth)) * sy : 0;
    var box = {
      left: rect.left + il,
      top: rect.top + it,
      width: Math.max(0, rect.width - il - ir),
      height: Math.max(0, rect.height - it - ib),
    };
    var content = M.contentRect(box, { width: video.videoWidth, height: video.videoHeight },
      cs ? cs.objectFit : 'contain', cs ? cs.objectPosition : '50% 50%');
    return { rect: rect, box: box, content: content };
  }

  function setImportant(el, prop, value) {
    try {
      if (el.style && typeof el.style.setProperty === 'function') {
        el.style.setProperty(prop, value, 'important');
        return;
      }
    } catch (_) { /* fall through */ }
    el.style[prop] = value;
  }

  function hostParent() {
    var VA = window.fushiVideoAnchor;
    if (VA && typeof VA.host === 'function') {
      try { var h = VA.host(); if (h) return h; } catch (_) { /* fallthrough */ }
    }
    return document.fullscreenElement || document.documentElement;
  }

  // 视口坐标 (x, y) = 遮布左上角。挂载点 / 定位方式 / 包含块原点交给视频锚定（与字幕覆盖层同一套），
  // 返回包含块 origin（sx / sy 用来折算宽高）。契约缺席（单测壳）时按 fixed 视口坐标写。
  function placeAt(el, x, y, video) {
    var VA = window.fushiVideoAnchor;
    if (VA && typeof VA.placeAt === 'function') {
      try { return VA.placeAt(el, x, y, video).origin || { x: 0, y: 0, sx: 1, sy: 1 }; } catch (_) { /* fallthrough */ }
    }
    var host = hostParent();
    if (host && el.parentNode !== host) host.appendChild(el);
    setImportant(el, 'position', 'fixed');
    setImportant(el, 'left', x + 'px');
    setImportant(el, 'top', y + 'px');
    return { x: 0, y: 0, sx: 1, sy: 1 };
  }

  function ensureEl() {
    if (st.el) return st.el;
    var el = document.createElement('div');
    el.id = MASK_ID;
    el.setAttribute('aria-hidden', 'true');
    for (var i = 0; i < HANDLE_DIRS.length; i++) {
      var h = document.createElement('span');
      h.className = 'fushi-subtitle-mask-handle';
      h.setAttribute('data-dir', HANDLE_DIRS[i]);
      el.appendChild(h);
    }
    var bar = document.createElement('div');
    bar.className = 'fushi-subtitle-mask-bar';
    var hint = document.createElement('span');
    hint.className = 'fushi-subtitle-mask-hint';
    hint.textContent = tr('mask_edit_hint');
    var reset = document.createElement('button');
    reset.type = 'button';
    reset.className = 'fushi-subtitle-mask-btn';
    reset.setAttribute('data-action', 'reset');
    reset.textContent = tr('mask_edit_reset');
    var done = document.createElement('button');
    done.type = 'button';
    done.className = 'fushi-subtitle-mask-btn is-primary';
    done.setAttribute('data-action', 'done');
    done.textContent = tr('mask_edit_done');
    bar.appendChild(hint);
    bar.appendChild(reset);
    bar.appendChild(done);
    el.appendChild(bar);
    reset.addEventListener('click', function (e) { swallow(e); resetPosition(); });
    done.addEventListener('click', function (e) { swallow(e); finishEdit(); });
    el.addEventListener('pointerdown', onPointerDown);
    // 编辑中遮布上的按下 / 点击不漏给站点：播放器把「点画面」当播放 / 暂停。平时 pointer-events:none，
    // 事件根本到不了这里。
    var stop = function (e) { if (st.editing) e.stopPropagation(); };
    el.addEventListener('mousedown', stop);
    el.addEventListener('mouseup', stop);
    el.addEventListener('click', stop);
    el.addEventListener('dblclick', stop);
    el.addEventListener('touchstart', stop);
    el.addEventListener('contextmenu', function (e) { if (st.editing) { e.stopPropagation(); e.preventDefault(); } });
    if (window.fushiTheme && typeof window.fushiTheme.stampStyle === 'function') {
      try { window.fushiTheme.stampStyle(el); } catch (_) { /* no-op */ }
    }
    st.el = el;
    st.barEl = bar;
    return el;
  }

  function swallow(e) {
    try { e.stopPropagation(); e.preventDefault(); } catch (_) { /* no-op */ }
  }

  function hide() {
    unwatch();
    if (st.el && st.el.parentNode) st.el.parentNode.removeChild(st.el);
  }

  function watch() {
    if (st.unwatch) return;
    var VA = window.fushiVideoAnchor;
    if (!VA || typeof VA.watch !== 'function') return;
    st.unwatch = VA.watch(function () { render(); });
  }
  function unwatch() {
    if (!st.unwatch) return;
    try { st.unwatch(); } catch (_) { /* no-op */ }
    st.unwatch = null;
  }

  // 固有尺寸变了（换清晰度 / 换片 / 元数据刚到）不改视频盒，帧观察看不见——直接听 <video> 的事件。
  function bindVideo(video) {
    if (st.video === video) return;
    if (st.video) {
      try {
        st.video.removeEventListener('resize', render);
        st.video.removeEventListener('loadedmetadata', render);
      } catch (_) { /* no-op */ }
    }
    st.video = video || null;
    if (video && typeof video.addEventListener === 'function') {
      video.addEventListener('resize', render);
      video.addEventListener('loadedmetadata', render);
    }
  }

  function currentRect() {
    if (st.drag && st.drag.rect) return st.drag.rect;
    return M.rectOf(st.settings);
  }

  function render() {
    var s = st.settings;
    if (!s.enabled && !st.editing) { bindVideo(null); hide(); return; }
    var video = videoEl();
    bindVideo(video);
    var m = video ? measure(video) : null;
    if (!m || !M.videoQualifies(m.rect) || !(m.content.width > 0) || !(m.content.height > 0)) { hide(); return; }
    var el = ensureEl();
    var area = M.clipTo(M.toPixels(currentRect(), m.content), m.rect);
    if (!(area.width > 0) || !(area.height > 0)) { hide(); return; }
    el.setAttribute('data-theme', resolveTheme());
    el.setAttribute('data-appearance', s.appearance);
    if (st.editing) el.setAttribute('data-editing', ''); else el.removeAttribute('data-editing');
    if (st.drag) el.setAttribute('data-dragging', ''); else el.removeAttribute('data-dragging');
    try {
      el.style.setProperty('--fushi-mask-blur', s.blur + 'px');
      el.style.setProperty('--fushi-mask-alpha', String(s.opacity / 100));
    } catch (_) { /* no-op */ }
    var origin = placeAt(el, area.left, area.top, video);
    setImportant(el, 'width', (area.width / (origin.sx || 1)) + 'px');
    setImportant(el, 'height', (area.height / (origin.sy || 1)) + 'px');
    if (st.editing) {
      var vh = window.innerHeight || 0;
      var barH = st.barEl && st.barEl.offsetHeight > 0 ? st.barEl.offsetHeight : 40;
      el.setAttribute('data-bar', M.barPlacement(area, vh, barH));
    }
    watch();
  }

  // 落盘（storage.onChanged 再把同一份值带给其它标签页 / 设置页 / 播放器菜单）。
  function persist(next) {
    st.settings = M.normalize(next);
    var w = M.writeOf(st.settings);
    try {
      if (w.remove) storage.remove(w.remove);
      else { var patch = {}; patch[w.set] = w.value; storage.set(patch); }
    } catch (_) { /* no-op */ }
  }

  function setEnabled(on) {
    var next = Object.assign({}, st.settings, { enabled: on === true });
    if (!next.enabled && st.editing) endEdit();
    persist(next);
    render();
    return st.settings.enabled;
  }

  function toggle() {
    var on = setEnabled(!st.settings.enabled);
    try {
      if (typeof window.fushiToast === 'function') window.fushiToast(tr(on ? 'mask_toast_on' : 'mask_toast_off'));
    } catch (_) { /* no-op */ }
    return true;
  }

  function onKeyDown(e) {
    if (!st.editing || e.key !== 'Escape') return;
    swallow(e);
    finishEdit();
  }

  function startEdit() {
    if (!st.settings.enabled) persist(Object.assign({}, st.settings, { enabled: true }));
    if (!st.editing) {
      st.editing = true;
      window.addEventListener('keydown', onKeyDown, true);
    }
    render();
    return !!(st.el && st.el.parentNode);
  }

  function endEdit() {
    endDrag(true);
    if (!st.editing) return;
    st.editing = false;
    window.removeEventListener('keydown', onKeyDown, true);
  }

  function finishEdit() {
    endEdit();
    render();
  }

  function resetPosition() {
    endDrag(false);
    persist(M.resetRect(st.settings));
    render();
  }

  function handleDirOf(target) {
    var node = target;
    for (var i = 0; node && node !== st.el && i < 4; i++) {
      if (typeof node.getAttribute === 'function') {
        if (node.getAttribute('data-action')) return 'bar';
        var cls = String(node.className || '');
        if (cls.indexOf('fushi-subtitle-mask-bar') >= 0) return 'bar';
        var d = node.getAttribute('data-dir');
        if (d) return d;
      }
      node = node.parentNode;
    }
    return 'move';
  }

  function onPointerDown(e) {
    if (!st.editing) return;
    if (e.button !== undefined && e.button !== null && e.button !== 0) return;
    var dir = handleDirOf(e.target);
    if (dir === 'bar') { e.stopPropagation(); return; } // 工具条按钮走自己的 click
    var video = videoEl();
    var m = video ? measure(video) : null;
    if (!m || !(m.content.width > 0) || !(m.content.height > 0)) return;
    endDrag(false);
    st.drag = {
      id: e.pointerId, dir: dir, x0: e.clientX, y0: e.clientY,
      start: M.rectOf(st.settings), cw: m.content.width, ch: m.content.height, rect: null,
    };
    window.addEventListener('pointermove', onPointerMove);
    window.addEventListener('pointerup', onPointerUp);
    window.addEventListener('pointercancel', onPointerCancel);
    try { if (st.el) st.el.setPointerCapture(e.pointerId); } catch (_) { /* no-op */ }
    swallow(e);
    render();
  }

  function onPointerMove(e) {
    var d = st.drag;
    if (!d || e.pointerId !== d.id) return;
    d.rect = M.applyDrag(d.start, d.dir, (e.clientX - d.x0) / d.cw, (e.clientY - d.y0) / d.ch);
    render();
    try { e.preventDefault(); } catch (_) { /* no-op */ }
  }
  function onPointerUp(e) {
    var d = st.drag;
    if (!d || e.pointerId !== d.id) return;
    endDrag(true);
    render();
  }
  function onPointerCancel(e) {
    var d = st.drag;
    if (!d || e.pointerId !== d.id) return;
    endDrag(false);
    render();
  }

  // commit=true：把会话矩形写成用户设置并落盘；false（取消 / 全屏切换）：丢弃回原样。
  function endDrag(commit) {
    var d = st.drag;
    if (!d) return;
    st.drag = null;
    window.removeEventListener('pointermove', onPointerMove);
    window.removeEventListener('pointerup', onPointerUp);
    window.removeEventListener('pointercancel', onPointerCancel);
    if (commit && d.rect) persist(Object.assign({}, st.settings, d.rect));
  }

  function adopt(raw) {
    var wasEnabled = st.settings.enabled;
    st.settings = M.normalize(raw);
    // 另一处（设置页 / 别的标签页）把遮布关了：编辑模式跟着收起。
    if (wasEnabled && !st.settings.enabled && st.editing) endEdit();
    render();
  }

  try {
    var p = storage.get(M.KEY, function (r) { adopt(r ? r[M.KEY] : null); });
    if (p && typeof p.then === 'function') p.then(function (r) { adopt(r ? r[M.KEY] : null); }, function () {});
  } catch (_) { /* no-op */ }
  try {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area !== 'local' || !changes || !changes[M.KEY]) return;
      // 拖动中别人写进来的值不打断手势；松手时以本会话为准落盘。
      var next = changes[M.KEY].newValue;
      if (st.drag) { st.settings = M.normalize(next); return; }
      adopt(next);
    });
  } catch (_) { /* no-op */ }

  document.addEventListener('fullscreenchange', function () {
    // 全屏切换打断进行中的手势：会话里的起点是旧坐标系的，带进新画面只会甩飞。
    endDrag(false);
    render();
    // 站点常在 fullscreenchange 之后才按新尺寸重排播放器；等两帧（布局落定）再按新几何摆一次。
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(function () { requestAnimationFrame(render); });
    }
  });

  // 兜底：SPA 换片 / 播放器重建 / 视频从无到有时帧观察还没挂上（没显示就不订阅），1 秒一次补摆。
  setInterval(function () {
    if (st.settings.enabled || st.editing) render();
  }, 1000);

  // 执行端契约（player-controls.js 菜单、video-shortcuts.js 快捷键）。
  window.fushiSubtitleMask = {
    state: function () { return { enabled: st.settings.enabled, editing: st.editing }; },
    toggle: toggle,
    setEnabled: setEnabled,
    edit: startEdit,
    finishEdit: finishEdit,
    reset: resetPosition,
  };
})();
