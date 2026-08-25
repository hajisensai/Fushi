// 查词弹窗尺寸盒的**唯一**决策器（纯函数，无 DOM）。
//
// 尺寸真相源只有一个：app 的 `extension_popup_max_width/height` 偏好（设置页「浏览器扩展
// 独立尺寸」+ 两个滑杆），经查词响应的 theme 变量 `--fushi-popup-max-width/height/zoom`
// 下发。写入口也只有一条：`POST /api/extension/popup-size {maxWidth,maxHeight}`——弹窗
// 右下角拖拽把手、侧边栏拖拽把手、扩展设置页「查词框大小」三处都走它（app 侧统一 clamp +
// 「拖即解锁」independentSize + 只写扩展键）。**扩展本地不得再存一份尺寸**，否则用户在
// app 设置页调完发现不生效，两套值互相盖。
//
// 本模块负责的是真相源之外的那件事：**把下发的尺寸夹进当前视口**。
// 起因：侧边栏文档可以窄到 300px，而 theme 宽度是按 app 窗口定的（400~600px），且这些
// px 长度写在 CSS `zoom` **之下**——zoom=1.4 时 400px 渲染成 560px，连
// `max-width: calc(100vw - 16px)` 这个上限本身也一起被 zoom 放大，根本拦不住 → 弹窗横向
// 溢出，被 `.lookup-pane{overflow-x:hidden}` 硬切掉右半边（用户看到「查词框被切了」）。
// content.js 的落点计算早已把 zoom 折回基准尺度（BUG-1726），侧边栏漏了这一步。
//
// 尺度约定（与 content.js fushiPlacePopup / side-panel.js positionLookup 同源）：
//   「基准尺度」= 写进 style.width / style.maxHeight 的数值，渲染尺寸 = 基准 × zoom。
//   视口尺寸是渲染尺度。所以任何视口上限要除以 zoom 才能与基准值比较。

// 基准最大宽/高的允许范围（逻辑像素）。与 app 设置页两滑杆 + Dart 侧
// effective_lookup_size.dart 的 kLookupPopupMin/MaxWidth/Height 单一同源——扩展覆盖、
// 拖拽把手、滑杆写的是同一个真值，边界必须一致，否则某条路径能写出别的路径写不出的越界值。
// 「弹窗内部布局低于此宽度就崩排版」用的也是这一个数：可用空间不足以在当前 zoom 下容纳它时，
// 压的是 zoom 而不是宽度（见 fushiResolvePopupBox）。content.js 的拖拽下限直接引用本常量。
var FUSHI_POPUP_MIN_WIDTH = 250;    // = kLookupPopupMinWidth
var FUSHI_POPUP_MAX_WIDTH = 2000;   // = kLookupPopupMaxWidth
var FUSHI_POPUP_MIN_HEIGHT = 200;   // = kLookupPopupMinHeight
var FUSHI_POPUP_MAX_HEIGHT = 1600;  // = kLookupPopupMaxHeight
// zoom 压到这个下限就不再压——再小字就不可读了，剩下的溢出交给横向滚动。
var FUSHI_POPUP_MIN_ZOOM = 0.5;

// CSS 长度串 → px 数。接受 '400px' / '400' / 400；无法解析返回 fallback。
// `min(...)` / `calc(...)` 这类函数式长度不是数值，返回 fallback（调用方本就只在
// 「纯 px 主题值」上做算术，函数式串按原样交给 CSS）。
function fushiParsePx(value, fallback) {
  if (typeof value === 'number') return isFinite(value) && value > 0 ? value : fallback;
  if (typeof value !== 'string') return fallback;
  var m = value.trim().match(/^(-?\d+(?:\.\d+)?)\s*px$/i) || value.trim().match(/^(-?\d+(?:\.\d+)?)$/);
  if (!m) return fallback;
  var n = parseFloat(m[1]);
  return isFinite(n) && n > 0 ? n : fallback;
}

// 设置页输入框 → 回写 app 之前的本地 clamp。app 侧 `_onExtensionPopupSize` sink 也会
// clamp 一次（那才是权威），这里只是让用户当场看到被夹住的值，而不是提交完才莫名变化。
// 非数/0/负数返回 null = 「这个值填得不成立，别提交」。
function fushiClampPopupSize(width, height) {
  var w = Number(width);
  var h = Number(height);
  if (!isFinite(w) || w <= 0 || !isFinite(h) || h <= 0) return null;
  return {
    width: Math.min(FUSHI_POPUP_MAX_WIDTH, Math.max(FUSHI_POPUP_MIN_WIDTH, Math.round(w))),
    height: Math.min(FUSHI_POPUP_MAX_HEIGHT, Math.max(FUSHI_POPUP_MIN_HEIGHT, Math.round(h))),
  };
}

// 决策弹窗尺寸盒。输入全是数据、输出全是数据，两个消费端（页面弹窗 / 侧边栏弹窗）共用。
//
// theme：app 下发的 CSS 变量对象（唯一尺寸真相源，可缺 → 用内置默认）。
// viewport：{width, height} 渲染尺度的可用视口（侧边栏传自身文档视口）。缺省不做视口夹取。
// opts.margin：视口两侧留白（渲染尺度，缺省 16）。
//
// 返回 { width, maxHeight, zoom, clamped }：
//   width / maxHeight 是**基准尺度 px 数**（直接 + 'px' 写进 style）；
//   zoom 是最终 zoom（空间实在不足时会低于下发值——宁可整体缩小也不横向切内容）；
//   clamped 标记本次是否因视口不足收敛过（供调用方决定要不要提示/记录，非必须消费）。
function fushiResolvePopupBox(theme, viewport, opts) {
  var t = theme && typeof theme === 'object' ? theme : {};
  var margin = opts && isFinite(opts.margin) ? opts.margin : 16;

  var width = fushiParsePx(t['--fushi-popup-max-width'], 400);
  var maxHeight = fushiParsePx(t['--fushi-popup-max-height'], 360);
  var zoom = parseFloat(t['--fushi-popup-zoom']) || 1;
  if (!(zoom > 0)) zoom = 1;

  var clamped = false;
  var vw = viewport && isFinite(viewport.width) ? viewport.width : 0;
  var vh = viewport && isFinite(viewport.height) ? viewport.height : 0;

  if (vw > 0) {
    var availW = Math.max(1, vw - margin); // 真实可用渲染宽（不许抬高——抬高就掩盖了「放不下」）
    // ① 先在当前 zoom 下压宽度。渲染宽 = width × zoom，故基准上限 = availW / zoom。
    var maxBaseW = availW / zoom;
    if (width > maxBaseW) { width = maxBaseW; clamped = true; }
    // ② 压完仍低于「弹窗内部布局的最小基准宽」= 当前 zoom 下这点空间根本排不开内容。
    //    此时该动的是 zoom 不是宽度：把宽度还原到最小基准宽，改让整窗等比缩小到放得下。
    //    这消除了「只能横向切内容」这个特殊情况。
    if (width < FUSHI_POPUP_MIN_WIDTH) {
      width = FUSHI_POPUP_MIN_WIDTH;
      zoom = Math.max(FUSHI_POPUP_MIN_ZOOM, availW / FUSHI_POPUP_MIN_WIDTH);
      clamped = true;
      // zoom 已到可读下限仍放不下（侧边栏窄到极端）：宽度按下限 zoom 再压回可用空间，
      // 剩余溢出交给 .lookup-pane 的横向滚动，绝不静默切掉内容。
      if (width * zoom > availW) width = availW / zoom;
    }
  }
  if (vh > 0) {
    // 与既有 `min(<theme px>, 80vh)` 语义对齐：vh 是渲染尺度，折回基准要除以 zoom。
    var maxBaseH = (vh * 0.8) / zoom;
    if (maxHeight > maxBaseH) { maxHeight = Math.max(64, maxBaseH); clamped = true; }
  }

  return {
    width: Math.round(width * 100) / 100,
    maxHeight: Math.round(maxHeight * 100) / 100,
    zoom: Math.round(zoom * 1000) / 1000,
    clamped: clamped,
  };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FUSHI_POPUP_MIN_WIDTH,
    FUSHI_POPUP_MIN_HEIGHT,
    FUSHI_POPUP_MAX_WIDTH,
    FUSHI_POPUP_MAX_HEIGHT,
    FUSHI_POPUP_MIN_ZOOM,
    fushiParsePx,
    fushiClampPopupSize,
    fushiResolvePopupBox,
  };
}
