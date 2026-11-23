import 'dart:convert';

import 'package:fushi/src/media/manga/manga_reader_preferences.dart';

/// 气泡原位放大（方案 A）的页内脚本，拼进 `mangaWindowDocument` 的手势机 IIFE。
///
/// ## 放大层怎么做：克隆整页节点 + transform
///
/// 浮层（`.manga-bubble-zoom`，`position:fixed`，挂在 body 上、不受画布缩放）
/// 里放的是**该页 `.manga-page` 的深拷贝**——页图 + 全部 OCR 块 / 字格节点，
/// `data-page` / `data-manga-sentence` / `data-manga-sentence-group` /
/// `data-utf16-start` 等属性和文本节点原样带过去，只把类名换成 `.manga-zoom-page`
/// （避免被 `querySelectorAll('.manga-page')` 的排版 / 滚动 / 补扫逻辑当成真页），
/// 再施加一个 `translate + scale` 让气泡中心落到浮层中心。
///
/// 这样查词**不另写一套**：
/// - 命中仍是 `_hitOcrChar` / `_selectOcrCharDetail`（它们只多了一步：落点在浮层里时
///   只在浮层的字格里挑，否则浮层下面被盖住的原图字格面积更小、会被选中）；
/// - 选词仍是 `fushiSelection.selectFromPosition`，`buildSelectionPayload` 从字格
///   往上找 `[data-manga-sentence]` 与 `.manga-page, .manga-zoom-page` 得到句子、
///   分组号与页号——和在原图上点字逐字段一致，Dart 的查词 / 制卡（裁图按分组号
///   回原图像素坐标）无需区分来源；
/// - 查词高亮（CSS Highlight / 降级 span）落在浮层的字格上，弹窗锚到放大后的
///   句子框；鼠标拖选（`user-select:text`）、Shift 悬停查词同理。
///
/// 没选「把浮层坐标反算回原页再调原命中」：那样选区、高亮和弹窗锚点都落在被浮层
/// 盖住的原图字格上，用户看不到查的是哪个字，弹窗也锚错位置。
///
/// ## 双击与单击查词
///
/// 单击字仍**零延迟**查词（`_onTap` 里的命中顺序不变）。双击气泡时第一击已经发起
/// 查词：第二击若落在同一处、在双击窗口内，就改判为「放大这个气泡」并撤回第一击
/// 的查词（`onMangaBubbleZoom(open, retract=true)` → Dart `clearDictionaryResult`，
/// 它会推进查词代号，在途结果作废）。第二击可能经两条路到达：弹窗还没出来时直接
/// 打在 WebView 上（按下时武装，同 `_armDoubleTapOnDown`）；弹窗已出来时打在 Dart
/// 的 barrier 上、经 `__mangaBarrierTapAt` 转进来，此时返回 `'zoom'`（≠ `'hit'`，
/// Dart 照常关弹窗）。代价是双击气泡时查词弹窗可能一闪即收；单击查词延迟为 0。
String mangaBubbleZoomJs({
  required MangaReaderPreferences preferences,
  required bool bookRtl,
  // 悬停查词修饰键在 JS 事件上的字段名（`shiftKey` / `ctrlKey` / …），同手势机的 hoverKey。
  required String hoverKey,
  required int openMs,
  required int closeMs,
  required String easing,
  // 浮层左上角「×」收起按钮的无障碍名 / 悬停提示。
  String closeLabel = '',
}) {
  final bool enabled = preferences.bubbleZoom;
  final int openDuration = preferences.einkMode ? 0 : openMs;
  final int closeDuration = preferences.einkMode ? 0 : closeMs;
  final double scale =
      preferences.bubbleZoomScale.clamp(
        kMangaBubbleZoomScaleMin,
        kMangaBubbleZoomScaleMax,
      ) /
      100.0;
  return '''
  // ── 气泡放大：配置 ──
  var BZ_ENABLED = $enabled;
  var BZ_HOVER = '${preferences.bubbleZoomHover}';
  var BZ_DELAY = ${preferences.bubbleZoomDelay};
  // 原有的悬停查词意图（按住查词修饰键 / 用户开了「悬停自动查词」）优先于悬停放大：
  // 默认开着的停留放大不能悄悄改掉存量用户的悬停查词习惯。
  var BZ_LOOKUP_ON_HOVER = ${preferences.lookupOnHover};
  var BZ_LOOKUP_KEY = '$hoverKey';
  var BZ_SCALE = $scale;
  // 阅读顺序跟书的开本方向走（条漫没有开本方向时 Dart 传的是书的设置）。
  var BZ_RTL = $bookRtl;
  // 动效时长由 Dart 的 FushiMotion 经 fushiMotionDuration 注入（减弱动态 / 墨水屏 = 0）。
  var BZ_OPEN_MS = $openDuration, BZ_CLOSE_MS = $closeDuration;
  var BZ_EASE = '$easing';
  var BZ_CLOSE_LABEL = ${jsonEncode(closeLabel)};
  // 鼠标移出浮层多久收起。
  var BZ_LEAVE_MS = 300;
  // barrier 只报松手：双击窗口从「第一击松手→第二击按下」(DBL_MS) 换成「松手→
  // 松手」要加上第二击按住的时长（常人点按 <200ms）。
  var BZ_BARRIER_SLACK = 200;
  var BZ_WEBTOON_DOUBLE_TAP = ${preferences.webtoonDoubleTapZoom};
  // ── 气泡放大：纯几何 ──
  // 阅读顺序：按纵向重叠把气泡分成「行」（两块纵向重叠超过较矮者的 40% 算同一行，
  // 行与行从上到下），行内按阅读方向排（RTL 从右到左）。
  function _bzOrderRows(items, rtl){
    var sorted = items.slice().sort(function(a, b){ return (a.t - b.t) || (a.l - b.l); });
    var rows = [];
    for (var i = 0; i < sorted.length; i++){
      var it = sorted[i];
      var row = rows.length ? rows[rows.length - 1] : null;
      if (row) {
        var overlap = Math.min(row.b, it.b) - Math.max(row.t, it.t);
        var minH = Math.min(row.b - row.t, it.b - it.t);
        if (minH > 0 && overlap >= minH * 0.4) {
          row.items.push(it);
          row.t = Math.min(row.t, it.t);
          row.b = Math.max(row.b, it.b);
          continue;
        }
      }
      rows.push({t: it.t, b: it.b, items: [it]});
    }
    var out = [];
    for (var r = 0; r < rows.length; r++){
      rows[r].items.sort(function(a, b){
        var ca = (a.l + a.r) / 2, cb = (b.l + b.r) / 2;
        return rtl ? cb - ca : ca - cb;
      });
      out.push.apply(out, rows[r].items);
    }
    return out;
  }
  // 多页连成一个序列：双页模式按开本方向（RTL 先右页），条漫从上到下。
  function _bzSequence(pages, rtl, vertical){
    var ordered = pages.slice().sort(function(a, b){
      if (vertical) return a.t - b.t;
      return rtl ? b.l - a.l : a.l - b.l;
    });
    var out = [];
    for (var i = 0; i < ordered.length; i++){
      out.push.apply(out, _bzOrderRows(ordered[i].bubbles, rtl));
    }
    return out;
  }
  // 浮层几何：气泡 + 四周一圈页面（每边气泡短边的 18%，至少 6px）放大 s 倍，以气泡
  // 中心为锚、整体夹进视口（四边留 8px）。放大后放不进视口就把倍率降到刚好放得下，
  // 但不低于 1。返回浮层框 {l,t,w,h}、实际倍率 s 与气泡中心 {cx,cy}（屏幕 px）。
  var BZ_MARGIN = 0.18, BZ_EDGE = 8;
  function _bzLayerGeom(b, vw, vh, scale){
    var bw = Math.max(1, b.r - b.l), bh = Math.max(1, b.b - b.t);
    var m = Math.max(6, Math.min(bw, bh) * BZ_MARGIN);
    var cw = bw + 2 * m, ch = bh + 2 * m;
    var availW = Math.max(1, vw - 2 * BZ_EDGE), availH = Math.max(1, vh - 2 * BZ_EDGE);
    var s = Math.max(1, Math.min(scale, availW / cw, availH / ch));
    var w = Math.min(cw * s, availW), h = Math.min(ch * s, availH);
    var cx = (b.l + b.r) / 2, cy = (b.t + b.b) / 2;
    var l = Math.min(Math.max(BZ_EDGE, cx - w / 2), vw - BZ_EDGE - w);
    var t = Math.min(Math.max(BZ_EDGE, cy - h / 2), vh - BZ_EDGE - h);
    return {l: l, t: t, w: w, h: h, s: s, cx: cx, cy: cy};
  }
  // ── 气泡放大：DOM ──
  var bzLayer = null;
  // 屏上可放大的页：有 OCR 数据（data-ocr-loaded 不是 0）的真页（不含浮层克隆）。
  function _bzVisiblePages(){
    return Array.prototype.filter.call(document.querySelectorAll('.manga-page'), function(page){
      if (page.getAttribute('data-ocr-loaded') === '0') return false;
      if (!IS_WEBTOON) return Number(page.getAttribute('data-spread')) === CURRENT;
      var r = page.getBoundingClientRect();
      return r.bottom > 0 && r.top < window.innerHeight;
    });
  }
  // 一页的气泡：同一句子分组（data-manga-sentence-group，与查词 / 制卡同一次分组）
  // 的块合成一个目标，外接框取并集（屏幕 px）。
  function _bzPageBubbles(page){
    var index = Number(page.getAttribute('data-page'));
    var byKey = {}, list = [];
    var boxes = page.querySelectorAll('.ocr-box');
    for (var i = 0; i < boxes.length; i++){
      var box = boxes[i];
      if (!(box.textContent || '').trim()) continue;
      var r = box.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) continue;
      var g = box.getAttribute('data-manga-sentence-group');
      var key = index + ':' + (g === null ? 'b' + box.getAttribute('data-manga-block') : g);
      var it = byKey[key];
      if (!it) {
        it = byKey[key] = {key: key, page: page, l: r.left, t: r.top, r: r.right, b: r.bottom};
        list.push(it);
      } else {
        it.l = Math.min(it.l, r.left); it.t = Math.min(it.t, r.top);
        it.r = Math.max(it.r, r.right); it.b = Math.max(it.b, r.bottom);
      }
    }
    return list;
  }
  // (x, y) 落在哪个气泡上（多个重叠取面积最小的）；没有 OCR / 没点中返回 null。
  function _bzBubbleAt(x, y){
    var pages = _bzVisiblePages(), best = null, bestArea = Infinity;
    for (var i = 0; i < pages.length; i++){
      var pr = pages[i].getBoundingClientRect();
      if (x < pr.left || x > pr.right || y < pr.top || y > pr.bottom) continue;
      var bubbles = _bzPageBubbles(pages[i]);
      for (var j = 0; j < bubbles.length; j++){
        var b = bubbles[j];
        if (x < b.l - 2 || x > b.r + 2 || y < b.t - 2 || y > b.b + 2) continue;
        var area = (b.r - b.l) * (b.b - b.t);
        if (area < bestArea) { best = b; bestArea = area; }
      }
    }
    return best;
  }
  function _bzSequenceOnScreen(){
    var pages = _bzVisiblePages().map(function(page){
      var r = page.getBoundingClientRect();
      return {l: r.left, t: r.top, bubbles: _bzPageBubbles(page)};
    });
    return _bzSequence(pages, BZ_RTL, IS_WEBTOON);
  }
  function _bzBuild(bubble){
    var page = bubble.page;
    var pr = page.getBoundingClientRect();
    var lw = page.offsetWidth || 1, lh = page.offsetHeight || 1;
    // 页在屏上的缩放（= 画布 ZOOM）：页盒本身不旋转，旋转 / 裁边都在 .manga-source
    // 的内联 transform 里，克隆原样带走。
    var k = pr.width / lw || 1;
    var g = _bzLayerGeom(bubble, window.innerWidth, window.innerHeight, BZ_SCALE);
    var layer = document.createElement('div');
    layer.className = 'manga-bubble-zoom';
    layer.style.left = g.l + 'px'; layer.style.top = g.t + 'px';
    layer.style.width = g.w + 'px'; layer.style.height = g.h + 'px';
    var clone = page.cloneNode(true);
    clone.className = 'manga-zoom-page';
    clone.removeAttribute('data-spread');
    var f = k * g.s;
    var lx = (g.cx - pr.left) / k, ly = (g.cy - pr.top) / k;
    var cs = clone.style;
    cs.position = 'absolute'; cs.left = '0'; cs.top = '0'; cs.margin = '0';
    cs.width = lw + 'px'; cs.height = lh + 'px';
    cs.maxWidth = 'none'; cs.maxHeight = 'none';
    cs.transformOrigin = '0 0';
    cs.transform = 'translate(' + (g.w / 2 - lx * f) + 'px,' + (g.h / 2 - ly * f) + 'px) scale(' + f + ')';
    var img = clone.querySelector('img');
    if (img) {
      img.setAttribute('loading', 'eager');
      // 按显示尺寸降采样的页图（BUG-4704）放大后会糊：先用已解码的那张，原图到了再换。
      var full = img.getAttribute('data-src');
      if (full && img.getAttribute('src') !== full) {
        var pre = new Image();
        pre.onload = function(){ img.setAttribute('src', full); };
        pre.src = full;
      }
    }
    layer.appendChild(clone);
    // 左上角「×」：显式的收起入口（拍板台 _5emrTFV1l）。按压由 _bzPointerDown 认领、
    // _bzRelease 收起；查词弹窗开着时点它经 barrier 进 _bzBarrierTap。
    var close = document.createElement('button');
    close.type = 'button';
    close.className = 'manga-bz-close';
    close.setAttribute('aria-label', BZ_CLOSE_LABEL);
    close.title = BZ_CLOSE_LABEL;
    close.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6L18 18M18 6L6 18"/></svg>';
    layer.appendChild(close);
    // 逐格读（manga_bubble_focus_js.dart）在浮层右上角加「⤢」入口。
    if (typeof _fcDecorateLayer === 'function') _fcDecorateLayer(layer);
    document.body.appendChild(layer);
    return {el: layer, geom: g, bubble: bubble, close: close};
  }
  // 从「贴在原气泡上、缩回 1/s」的状态长出来：起点与原图逐像素重合，看起来是气泡
  // 在原位鼓起来；收起反向。
  function _bzCollapsedTransform(g){
    var dx = g.cx - (g.l + g.w / 2), dy = g.cy - (g.t + g.h / 2);
    return 'translate(' + dx + 'px,' + dy + 'px) scale(' + (1 / g.s) + ')';
  }
  function _bzAnimateIn(layer, g){
    if (!(BZ_OPEN_MS > 0)) return;
    layer.style.transition = 'none';
    layer.style.transform = _bzCollapsedTransform(g);
    layer.style.opacity = '0';
    void layer.offsetWidth;
    layer.style.transition = 'transform ' + BZ_OPEN_MS + 'ms ' + BZ_EASE +
        ',opacity ' + Math.round(BZ_OPEN_MS / 2) + 'ms linear';
    layer.style.transform = 'none';
    layer.style.opacity = '1';
  }
  function _bzDestroy(layer, g, instant){
    layer.setAttribute('data-closing', '1');
    layer.style.pointerEvents = 'none';
    if (instant || !(BZ_CLOSE_MS > 0)) { layer.remove(); return; }
    layer.style.transition = 'transform ' + BZ_CLOSE_MS + 'ms ' + BZ_EASE +
        ',opacity ' + BZ_CLOSE_MS + 'ms linear';
    layer.style.transform = _bzCollapsedTransform(g);
    layer.style.opacity = '0';
    setTimeout(function(){ layer.remove(); }, BZ_CLOSE_MS);
  }
  // 落点在打开的浮层里时返回浮层里的克隆页，否则 null。
  function _bzInLayer(x, y){
    if (!bzLayer) return false;
    var r = bzLayer.el.getBoundingClientRect();
    return !(x < r.left || x > r.right || y < r.top || y > r.bottom);
  }
  function _bzLayerScopeAt(x, y){
    return _bzInLayer(x, y) ? bzLayer.el.firstChild : null;
  }
  // 字格命中的限定范围：放大浮层，或文字条 / 台词栏（manga_bubble_focus_js.dart）。
  // 范围里是原 OCR 节点的克隆，盖在原图字格之上，不限定就会被「最小面积」挑走下面的原字格。
  function _bzScopeAt(x, y){
    var layer = _bzLayerScopeAt(x, y);
    if (layer) return layer;
    return typeof _tsScopeAt === 'function' ? _tsScopeAt(x, y) : null;
  }
  // 当前选区（查词）是否落在浮层里——查词弹窗开着时浮层不随鼠标离开收起。
  // 落点是否在浮层的「×」上（含按钮四周补足到 48px 的命中区，同 CSS 的 ::before）。
  function _bzOnCloseButton(x, y){
    var btn = bzLayer && bzLayer.close;
    if (!btn) return false;
    var r = btn.getBoundingClientRect();
    var pad = Math.max(0, (48 - Math.min(r.right - r.left, r.bottom - r.top)) / 2);
    return !(x < r.left - pad || x > r.right + pad || y < r.top - pad || y > r.bottom + pad);
  }
  function _bzSelectionInLayer(){
    var s = window.fushiSelection && window.fushiSelection.selection;
    var node = s && s.startNode;
    return !!(bzLayer && node && bzLayer.el.contains(node));
  }
  // ── 气泡放大：手势 ──
  var bzLastTap = null, bzDblArmed = false, bzPress = null, bzPointerType = '';
  var bzHoverTimer = null, bzHoverKey = null, bzLeaveTimer = null;
  var bzMouseX = -1, bzMouseY = -1, bzCtrl = false, bzLookupKey = false;
  function _bzNotify(state, retract){
    var b = _bridge();
    if (b) b.callHandler('onMangaBubbleZoom', state, !!retract);
  }
  function _bzDoubleTapAllowed(){
    return BZ_ENABLED && (!IS_WEBTOON || BZ_WEBTOON_DOUBLE_TAP);
  }
  // 撤回第一击的查词：清掉 JS 选区；有选区（第一击命中了字）才让 Dart 撤回。
  function _bzTakeSelection(){
    var sel = window.fushiSelection;
    if (!sel || !sel.selection) return false;
    sel.clearSelection();
    return true;
  }
  function _bzCancelHover(){
    if (bzHoverTimer) { clearTimeout(bzHoverTimer); bzHoverTimer = null; }
    bzHoverKey = null;
  }
  function _bzCancelLeave(){
    if (bzLeaveTimer) { clearTimeout(bzLeaveTimer); bzLeaveTimer = null; }
  }
  function _bzOpen(bubble, retract){
    if (bzLayer && bzLayer.bubble.key === bubble.key) return;
    _bzCancelHover();
    _bzCancelLeave();
    if (bzLayer) {
      if (_bzSelectionInLayer()) window.fushiSelection.clearSelection();
      _bzDestroy(bzLayer.el, bzLayer.geom, true);
      bzLayer = null;
    }
    bzLayer = _bzBuild(bubble);
    _bzAnimateIn(bzLayer.el, bzLayer.geom);
    _bzNotify('open', retract);
  }
  function _bzClose(instant, retract){
    _bzCancelHover();
    _bzCancelLeave();
    if (!bzLayer) return false;
    if (_bzSelectionInLayer()) window.fushiSelection.clearSelection();
    var old = bzLayer;
    bzLayer = null;
    bzPress = null;
    _bzDestroy(old.el, old.geom, instant);
    _bzNotify('close', retract);
    return true;
  }
  function _bzNear(x, y, tap){
    var dx = x - tap.x, dy = y - tap.y;
    return dx * dx + dy * dy <= DBL_SLOP * DBL_SLOP;
  }
  function _bzRecentTap(x, y, slack, inLayer){
    return !!(bzLastTap && bzLastTap.inLayer === inLayer &&
        Date.now() - bzLastTap.t <= DBL_MS + slack && _bzNear(x, y, bzLastTap));
  }
  // 浮层外的按下（含浮层没开）：第二击按下时就武装双击，同 _armDoubleTapOnDown。
  function _bzArmOnDown(x, y){
    bzDblArmed = _bzRecentTap(x, y, 0, false);
  }
  // 直接打在 WebView 上的单击（浮层里的按压走 _bzRelease）。true = 已消费。
  function _bzOnTap(x, y){
    // 逐格读里鼠标的单击（触屏的按压由 _fcClaimPress 接管）。
    if (typeof fcOn !== 'undefined' && fcOn) return _fcTap(x, y);
    if (!BZ_ENABLED) return false;
    var armed = bzDblArmed;
    bzDblArmed = false;
    if (bzLayer) {
      // 点浮层外 = 收起。触屏这一击就此消费；鼠标照常往下走（热区翻页 / 查词）。
      bzLastTap = null;
      _bzClose(false, false);
      return bzPointerType !== 'mouse';
    }
    if (!_bzDoubleTapAllowed()) return false;
    var bubble = _bzBubbleAt(x, y);
    if (!bubble) { bzLastTap = null; return false; }
    if (armed || _bzRecentTap(x, y, 0, false)) {
      bzLastTap = null;
      lastTapT = 0;
      _cancelPendingEmptyTap();
      _bzOpen(bubble, _bzTakeSelection());
      return true;
    }
    bzLastTap = {t: Date.now(), x: x, y: y, inLayer: false};
    return false;
  }
  // barrier（查词弹窗开着）转进来的单击。返回 null = 照常走命中；'zoom' / 'miss'
  // = 已处理，Dart 关弹窗。
  function _bzBarrierTap(x, y){
    if (!BZ_ENABLED || (typeof fcOn !== 'undefined' && fcOn)) return null;
    if (bzLayer) {
      if (!_bzInLayer(x, y)) { bzLastTap = null; _bzClose(false, false); return 'miss'; }
      // 弹窗开着时点「×」：收起浮层，Dart 照常关弹窗（选区在浮层里，_bzClose 会清）。
      if (_bzOnCloseButton(x, y)) { bzLastTap = null; _bzClose(false, false); return 'miss'; }
      if (_bzRecentTap(x, y, BZ_BARRIER_SLACK, true)) {
        bzLastTap = null;
        _bzTakeSelection();
        _bzClose(false, false);
        return 'zoom';
      }
      return null;
    }
    if (_bzDoubleTapAllowed() && _bzRecentTap(x, y, BZ_BARRIER_SLACK, false)) {
      var bubble = _bzBubbleAt(x, y);
      if (bubble) {
        bzLastTap = null;
        _bzTakeSelection();
        _bzOpen(bubble, false);
        return 'zoom';
      }
    }
    return null;
  }
  function _bzNoteBarrierTap(x, y){
    if (!BZ_ENABLED) return;
    var inLayer = _bzInLayer(x, y);
    bzLastTap = (inLayer || _bzBubbleAt(x, y))
        ? {t: Date.now(), x: x, y: y, inLayer: inLayer} : null;
  }
  // 按下落在打开的浮层里：这次按压归浮层（不平移、不翻页），长按照旧弹图片动作面板。
  function _bzPointerDown(e){
    bzPointerType = e.pointerType || '';
    // 文字条 / 台词栏、逐格读里的按压归它们（manga_bubble_focus_js.dart）。
    var claimed = typeof _fcClaimPress === 'function' ? _fcClaimPress(e) : null;
    if (claimed) {
      bzPress = claimed;
      has = false;
      _cancelPendingEmptyTap();
      _armLongPress(e);
      return true;
    }
    if (!bzLayer || !_bzInLayer(e.clientX, e.clientY)) {
      _bzArmOnDown(e.clientX, e.clientY);
      return false;
    }
    var target = e.target && e.target.closest ? e.target : null;
    bzPress = {id: e.pointerId, x: e.clientX, y: e.clientY, t: Date.now(),
      type: e.pointerType || '', armed: _bzRecentTap(e.clientX, e.clientY, 0, true),
      btn: !!(target && target.closest('.manga-bz-focus')),
      close: !!(target && target.closest('.manga-bz-close'))};
    has = false;
    _cancelPendingEmptyTap();
    // 按在角上按钮上不弹图片动作面板：那是按钮，不是页图。
    if (!bzPress.btn && !bzPress.close) _armLongPress(e);
    return true;
  }
  function _bzRelease(p, x, y){
    var dx = x - p.x, dy = y - p.y, el = Math.max(1, Date.now() - p.t);
    var ax = Math.abs(dx), ay = Math.abs(dy);
    if (p.kind && typeof _fcRelease === 'function') {
      if (p.kind === 'ts') _tsRelease(p, x, y); else _fcRelease(p, x, y);
      return;
    }
    if (p.btn) {
      if (ax < 20 && ay < 20 && bzLayer && typeof _fcEnter === 'function') _fcEnter(bzLayer.bubble);
      return;
    }
    // 「×」：按下松开在原处才收起（按下后拖走 = 反悔）。浮层里的选区由 _bzClose 清掉。
    if (p.close) {
      if (ax < 20 && ay < 20) { bzLastTap = null; _bzClose(false, false); }
      return;
    }
    // 左右滑 = 换相邻气泡（阈值与翻页 swipe 同口径）；RTL 书向右滑是下一个。
    if (p.type !== 'mouse' && ax > ay * 1.5 &&
        (ax >= 72 || (ax >= 36 && ax / el * 1000 >= 900))) {
      _bzStep((dx > 0) === BZ_RTL ? 1 : -1);
      return;
    }
    if (ax >= 20 || ay >= 20 || el >= 500) return;
    if (p.armed) {
      bzLastTap = null;
      _bzClose(false, _bzTakeSelection());
      return;
    }
    _selectOcrChar(x, y, false);
    bzLastTap = {t: Date.now(), x: x, y: y, inLayer: true};
  }
  // 取走（并清掉）指针 id 对应的浮层按压；id 为 null = 无条件丢弃（第二指落下进捏合）。
  function _bzTakePress(id){
    var p = bzPress;
    if (!p || (id !== null && p.id !== id)) return null;
    bzPress = null;
    return id === null ? null : p;
  }
  function _bzViewportChanged(){
    if (bzLayer) _bzClose(true, false);
    if (typeof _fcPlaceDim === 'function') _fcPlaceDim();
  }
  function _bzStep(dir){
    if (!bzLayer) return false;
    var seq = _bzSequenceOnScreen(), at = -1;
    for (var i = 0; i < seq.length; i++) if (seq[i].key === bzLayer.bubble.key) at = i;
    var next = seq[at + dir];
    if (!next) return false;
    _bzOpen(next, _bzTakeSelection());
    return true;
  }
  function _bzLookupKeyHeld(e){ return !!(e && e[BZ_LOOKUP_KEY]); }
  // 鼠标指向原图气泡时这次悬停算不算「要放大」。显式的查词意图优先：
  // - 按住查词修饰键（lookupKey）= 要查原图上的字，不放大（修饰键恰好也是 Ctrl 时
  //   「按住 Ctrl 放大」让位给查词）；
  // - 开了「悬停自动查词」时，悬停本身就是查词，停留放大不接管（「按住 Ctrl」
  //   是另一个显式手势，照常放大）。
  function _bzHoverTrigger(ctrl, lookupKey){
    if (!BZ_ENABLED || lookupKey) return false;
    if (BZ_HOVER === 'dwell') return !BZ_LOOKUP_ON_HOVER;
    return BZ_HOVER === 'ctrl' && !!ctrl;
  }
  // 这次悬停归放大时，原图上的悬停查词让位（查词在浮层 / 文字条里做）；浮层里照常悬停查词。
  function _bzBlocksHoverLookup(x, y, ctrl, lookupKey){
    // 逐格读里读的就是原图，原图上的悬停查词照常。
    if (typeof fcOn !== 'undefined' && fcOn) return false;
    return _bzHoverTrigger(ctrl, lookupKey) && !_bzScopeAt(x, y);
  }
  function _bzLeaveFire(){
    bzLeaveTimer = null;
    if (!bzLayer) return;
    // 正在等着换到另一个气泡：由它接手，不先收起再弹（不闪）。
    if (bzHoverTimer) return;
    if (bzMouseX >= 0 && _bzInLayer(bzMouseX, bzMouseY)) return;
    // 查词弹窗开着（选区在浮层里）：保持。
    if (_bzSelectionInLayer()) return;
    _bzClose(false, false);
  }
  function _bzArmLeave(){
    if (bzLayer && !bzLeaveTimer) bzLeaveTimer = setTimeout(_bzLeaveFire, BZ_LEAVE_MS);
  }
  function _bzHover(x, y, ctrl, buttons, lookupKey){
    bzMouseX = x; bzMouseY = y; bzCtrl = ctrl; bzLookupKey = !!lookupKey;
    if (!BZ_ENABLED || BZ_HOVER === 'off') return;
    if (typeof fcOn !== 'undefined' && fcOn) return;
    if (typeof _tsScopeAt === 'function' && _tsScopeAt(x, y)) { _bzCancelHover(); _bzArmLeave(); return; }
    if (buttons) { _bzCancelHover(); return; }
    if (bzLayer && _bzInLayer(x, y)) { _bzCancelHover(); _bzCancelLeave(); return; }
    var bubble = _bzHoverTrigger(ctrl, lookupKey) ? _bzBubbleAt(x, y) : null;
    if (bubble && bzLayer && bubble.key === bzLayer.bubble.key) bubble = null;
    if (!bubble) { _bzCancelHover(); _bzArmLeave(); return; }
    if (bzHoverKey === bubble.key) return;
    _bzCancelHover();
    bzHoverKey = bubble.key;
    bzHoverTimer = setTimeout(function(){
      bzHoverTimer = null;
      bzHoverKey = null;
      // 停住才弹：到点时鼠标还在同一个气泡上、触发条件仍成立。
      var again = bzMouseX >= 0 ? _bzBubbleAt(bzMouseX, bzMouseY) : null;
      if (!again || again.key !== bubble.key || !_bzHoverTrigger(bzCtrl, bzLookupKey)) {
        _bzArmLeave();
        return;
      }
      _bzOpen(again, false);
    }, BZ_HOVER === 'ctrl' ? 0 : BZ_DELAY);
  }
  document.addEventListener('pointermove', function(e){
    if (e.pointerType !== 'mouse') return;
    _bzHover(e.clientX, e.clientY, !!e.ctrlKey, e.buttons, _bzLookupKeyHeld(e));
  }, {passive: true});
  if (document.documentElement) {
    document.documentElement.addEventListener('mouseleave', function(){
      bzMouseX = -1; bzMouseY = -1;
      _bzCancelHover();
      _bzArmLeave();
    });
  }
  // 「按住 Ctrl」触发：鼠标停着不动、只按下 Ctrl 也要弹。Esc 由 Dart 统一处理
  // （它要决定是收浮层还是退书，两边各判一次会抢）。
  // 鼠标停着不动时按下查词修饰键：撤掉还没到点的停留放大，让这次悬停归查词。
  window.addEventListener('keydown', function(e){
    if (_bzLookupKeyHeld(e)) { bzLookupKey = true; _bzCancelHover(); }
    if (e.key === 'Control' && !e.repeat && BZ_HOVER === 'ctrl' && bzMouseX >= 0) {
      _bzHover(bzMouseX, bzMouseY, true, 0, _bzLookupKeyHeld(e));
    }
  }, true);
  window.addEventListener('keyup', function(e){
    bzLookupKey = _bzLookupKeyHeld(e);
  }, true);
  // 视口变了（滚动 / 翻页 / 缩放平移 / 窗口尺寸）浮层就失去锚点：立即收起。
  window.addEventListener('scroll', function(){
    if (bzLayer) _bzClose(true, false);
  }, {passive: true});
  window.__mangaBubbleZoomClose = function(){ return _bzClose(false, false); };
  window.__mangaBubbleZoomOpen = function(){ return !!bzLayer; };
''';
}

/// 放大浮层角上按钮的样式表：左上「×」收起（`.manga-bz-close`）、右上「⤢ 逐格读」
/// （`.manga-bz-focus`，manga_bubble_focus_js.dart）。两颗按钮同一套外观：
/// - MD3（[appleStyle] = false）：40px 圆形深色容器 + 白色图标，悬停 / 按下叠 8% / 12%
///   的 state layer（`::after`），按下缩到 0.92（同 `FushiPressScale`）、悬停放大 1.06
///   （同 `FushiHoverLift`）；
/// - Apple：30px 圆形半透明毛玻璃（`backdrop-filter`）+ 粗笔画 xmark，按下缩到 0.9 并
///   变暗（iOS 按压惯例），悬停只加深底色。
/// 视觉尺寸不足 48px 的部分由透明 `::before` 补足命中区（`_bzOnCloseButton` 同口径）。
/// [motionMs] 来自 Dart 的 `fushiMotionDuration(FushiMotion.short)`：减弱动态效果时为 0，
/// 此时不写过渡、不做缩放；墨水屏一律不做动效与半透明。
String mangaBubbleZoomButtonCss({
  required bool einkMode,
  required bool appleStyle,
  required int motionMs,
}) {
  final int size = appleStyle ? 30 : 40;
  final int icon = appleStyle ? 13 : 20;
  final double stroke = appleStyle ? 3.2 : 2.2;
  final int pad = (48 - size) ~/ 2;
  final bool animate = motionMs > 0 && !einkMode;
  const String both = '.manga-bz-close,.manga-bz-focus';
  final String surface;
  if (einkMode) {
    surface = 'background:#fff;color:#000;border:1px solid #000;';
  } else if (appleStyle) {
    surface =
        'border:0;background:rgba(44,44,46,.58);color:rgba(255,255,255,.94);'
        '-webkit-backdrop-filter:blur(18px) saturate(180%);'
        'backdrop-filter:blur(18px) saturate(180%);';
  } else {
    surface =
        'border:0;background:rgba(20,20,20,.62);color:#fff;'
        'box-shadow:0 1px 2px rgba(0,0,0,.3),0 1px 3px 1px rgba(0,0,0,.15);';
  }
  final String transition = animate
      ? 'transition:transform ${motionMs}ms cubic-bezier(.2,0,0,1),'
            'background-color ${motionMs}ms linear,opacity ${motionMs}ms linear;'
      : '';
  final StringBuffer css = StringBuffer()
    ..write(
      '$both{position:absolute;top:6px;z-index:2;box-sizing:border-box;'
      'width:${size}px;height:${size}px;border-radius:${size ~/ 2}px;'
      'padding:0;margin:0;cursor:pointer;display:flex;align-items:center;'
      'justify-content:center;font:${appleStyle ? 16 : 20}px/1 sans-serif;'
      '-webkit-tap-highlight-color:transparent;user-select:none;'
      '$surface$transition}',
    )
    ..write('.manga-bz-close{left:6px;}.manga-bz-focus{right:6px;}')
    ..write(
      '.manga-bz-close::before,.manga-bz-focus::before{content:"";'
      'position:absolute;left:-${pad}px;top:-${pad}px;right:-${pad}px;'
      'bottom:-${pad}px;}',
    )
    ..write(
      '.manga-bz-close svg{width:${icon}px;height:${icon}px;'
      'pointer-events:none;}'
      '.manga-bz-close path{fill:none;stroke:currentColor;'
      'stroke-width:$stroke;stroke-linecap:round;}',
    );
  if (einkMode) return css.toString();
  if (appleStyle) {
    css
      ..write(
        '@media (hover:hover){.manga-bz-close:hover,.manga-bz-focus:hover'
        '{background:rgba(44,44,46,.74);}}',
      )
      ..write(
        '.manga-bz-close:active,.manga-bz-focus:active{opacity:.7;'
        '${animate ? 'transform:scale(.9);' : ''}}',
      );
  } else {
    css
      ..write(
        '.manga-bz-close::after,.manga-bz-focus::after{content:"";'
        'position:absolute;left:0;top:0;right:0;bottom:0;'
        'border-radius:inherit;background:currentColor;opacity:0;'
        'pointer-events:none;'
        '${animate ? 'transition:opacity ${motionMs}ms linear;' : ''}}',
      )
      ..write(
        '@media (hover:hover){.manga-bz-close:hover::after,'
        '.manga-bz-focus:hover::after{opacity:.08;}'
        '${animate ? '.manga-bz-close:hover,.manga-bz-focus:hover{transform:scale(1.06);}' : ''}}',
      )
      ..write(
        '.manga-bz-close:active::after,.manga-bz-focus:active::after'
        '{opacity:.12;}'
        '${animate ? '.manga-bz-close:active,.manga-bz-focus:active{transform:scale(.92);}' : ''}',
      );
  }
  return css.toString();
}
