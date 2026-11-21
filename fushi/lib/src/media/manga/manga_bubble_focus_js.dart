import 'dart:convert';

import 'package:fushi/src/media/manga/manga_reader_preferences.dart';

/// 文字条 / 台词栏占用的视口边：桌面右侧台词栏占右边，移动端文字条占底边。
enum MangaTextStripLayout {
  /// 移动端：底部一条，只显示当前气泡。
  strip,

  /// 桌面：右侧一栏，按阅读顺序列出本屏全部气泡。
  panel,
}

/// 台词栏宽度（逻辑像素）。
const double kMangaTextPanelWidth = 320;

/// 文字条 / 台词栏给页面让出的 (右, 下) 边距：页面排版按扣掉它后的视口适配，
/// 文字条 / 台词栏就不压在页图上（`_layoutSource` 与 `.manga-spread` 的 padding）。
({double right, double bottom}) mangaTextStripReserve(
  MangaReaderPreferences preferences,
  MangaTextStripLayout layout,
) {
  if (!preferences.bubbleTextStrip) return (right: 0, bottom: 0);
  return switch (layout) {
    MangaTextStripLayout.panel => (right: kMangaTextPanelWidth, bottom: 0),
    // 两行大字 + 上下内边距。
    MangaTextStripLayout.strip => (
      right: 0,
      bottom: (preferences.bubbleTextStripSize * 1.5 * 2 + 28).roundToDouble(),
    ),
  };
}

/// 逐格读（聚焦模式）+ 文字条 / 台词栏（方案 C）的页内脚本，拼在气泡放大模块
/// （`manga_bubble_zoom_js.dart`）之后，复用它的气泡划分（句子分组）与阅读顺序。
///
/// 查词一律走现有 OCR 命中：
/// - 逐格读只是把画布动画缩放 / 平移到气泡上（`ZOOM` / `PAN_*` / `scrollY` 与捏合、
///   双击缩放同一套状态），点的是原图上的字格，命中与查词路径原封不动；
/// - 文字条 / 台词栏里每个气泡是一个 `.manga-zoom-page[data-page]`，里面是该气泡
///   原 `.ocr-box`（带 `data-manga-sentence` / 分组号 / 字格 `.ocr-char` 与文本节点）
///   的克隆，只去掉绝对定位改成行内排版。`_hitOcrChar` 经 `_bzScopeAt` 把命中限定在
///   条 / 栏里，`buildSelectionPayload` 照常拿到句子、分组号与页号——与在图上点字
///   时同一份 payload，制卡按分组号回原图裁图。
String mangaBubbleFocusJs({
  required MangaReaderPreferences preferences,
  required int focusMs,
  required String focusLabel,
  required String resumeEdge,
  required MangaTextStripLayout stripLayout,
  required String stripEmptyLabel,
}) {
  final int duration = preferences.einkMode ? 0 : focusMs;
  return '''
  // ── 逐格读（聚焦模式）──
  var FC_DIM = '${preferences.bubbleFocusDim}';
  var FC_MS = $duration;
  var FC_LABEL = ${jsonEncode(focusLabel)};
  var FC_RESUME = '$resumeEdge';
  var fcOn = false, fcKey = null, fcLocal = null, fcDim = null, fcAnim = null;
  var fcPendingEdge = null, fcLastTap = null, fcWheelT = 0, fcTurnSeq = 0;
  function _fcSequence(){
    if (!IS_WEBTOON) return _bzSequenceOnScreen();
    // 条漫放大后下一页常在视口外：整份文档里有 OCR 的页都算。
    var pages = Array.prototype.filter.call(document.querySelectorAll('.manga-page'), function(page){
      return page.getAttribute('data-ocr-loaded') !== '0';
    }).map(function(page){
      var r = page.getBoundingClientRect();
      return {l: r.left, t: r.top, bubbles: _bzPageBubbles(page)};
    });
    return _bzSequence(pages, BZ_RTL, true);
  }
  function _fcIndex(seq, key){
    for (var i = 0; i < seq.length; i++) if (seq[i].key === key) return i;
    return -1;
  }
  function _fcNotify(state, seq){
    var b = _bridge();
    if (!b) return;
    b.callHandler('onMangaBubbleFocus', state, seq ? _fcIndex(seq, fcKey) : -1,
        seq ? seq.length : 0, fcPendingEdge || '');
  }
  // 屏幕 px ↔ 画布布局坐标：spread 屏幕 = 布局 × ZOOM + PAN；条漫纵向 = 布局 × ZOOM − scrollY。
  function _fcLocalRect(b){
    var sy = IS_WEBTOON ? window.scrollY : 0;
    return {
      l: (b.l - PAN_X) / ZOOM, r: (b.r - PAN_X) / ZOOM,
      t: (IS_WEBTOON ? b.t + sy : b.t - PAN_Y) / ZOOM,
      b: (IS_WEBTOON ? b.b + sy : b.b - PAN_Y) / ZOOM
    };
  }
  function _fcScreenRect(L){
    var sy = IS_WEBTOON ? window.scrollY : 0;
    return {
      l: L.l * ZOOM + PAN_X, r: L.r * ZOOM + PAN_X,
      t: IS_WEBTOON ? L.t * ZOOM - sy : L.t * ZOOM + PAN_Y,
      b: IS_WEBTOON ? L.b * ZOOM - sy : L.b * ZOOM + PAN_Y
    };
  }
  // 目标视图：气泡放到可用视口（扣掉文字条 / 台词栏）宽或高的 85%，最多 4×、
  // 不低于 1×，气泡中心居中；平移钳在合法区间里（与 _clampPan 同口径）。
  function _fcTarget(L, vw, vh){
    var bw = Math.max(1, L.r - L.l), bh = Math.max(1, L.b - L.t);
    var z = Math.min(0.85 * vw / bw, 0.85 * vh / bh, 4, ZOOM_MAX);
    z = Math.max(1, z);
    var cx = (L.l + L.r) / 2, cy = (L.t + L.b) / 2;
    var px = vw / 2 - cx * z;
    var fullW = vw + RESERVE_R, fullH = vh + RESERVE_B;
    if (z > 1) px = Math.min(0, Math.max(fullW * (1 - z), px));
    var py = 0, sy = 0;
    if (IS_WEBTOON) sy = Math.max(0, cy * z - vh / 2);
    else {
      py = vh / 2 - cy * z;
      if (z > 1) py = Math.min(0, Math.max(fullH * (1 - z), py));
    }
    return {z: z, px: px, py: py, sy: sy};
  }
  function _fcPlaceDim(){
    if (!fcOn || !fcLocal) return;
    if (!fcDim) {
      fcDim = document.createElement('div');
      fcDim.className = 'manga-focus-dim manga-focus-dim-' + FC_DIM;
      document.body.appendChild(fcDim);
    }
    var r = _fcScreenRect(fcLocal), pad = 6;
    fcDim.style.left = (r.l - pad) + 'px';
    fcDim.style.top = (r.t - pad) + 'px';
    fcDim.style.width = (r.r - r.l + 2 * pad) + 'px';
    fcDim.style.height = (r.b - r.t + 2 * pad) + 'px';
  }
  function _fcGo(L){
    var tg = _fcTarget(L, window.innerWidth - RESERVE_R, window.innerHeight - RESERVE_B);
    if (fcAnim) { cancelAnimationFrame(fcAnim); fcAnim = null; }
    var z0 = ZOOM, x0 = PAN_X, y0 = PAN_Y, s0 = IS_WEBTOON ? window.scrollY : 0, t0 = null;
    function apply(k){
      var e = 1 - Math.pow(1 - k, 3);
      ZOOM = z0 + (tg.z - z0) * e;
      PAN_X = x0 + (tg.px - x0) * e;
      PAN_Y = y0 + (tg.py - y0) * e;
      _applyCanvas();
      if (IS_WEBTOON) _zoomAnchorScrollTo(s0 + (tg.sy - s0) * e);
      _fcPlaceDim();
    }
    function settle(){
      fcAnim = null;
      var b = _bridge();
      if (b) b.callHandler('onMangaZoomChanged', Math.round(ZOOM * 100));
    }
    if (!(FC_MS > 0)) { apply(1); settle(); return; }
    fcAnim = requestAnimationFrame(function frame(t){
      if (t0 === null) t0 = t;
      var k = Math.min(1, (t - t0) / FC_MS);
      apply(k);
      if (k < 1) fcAnim = requestAnimationFrame(frame); else settle();
    });
  }
  function _fcFocusBubble(b){
    fcKey = b.key;
    fcLocal = _fcLocalRect(b);
    _fcGo(fcLocal);
    _fcPlaceDim();
    if (typeof _tsSetCurrent === 'function') _tsSetCurrent(b.key);
    _fcNotify('state', _fcSequence());
  }
  function _fcEnter(bubble){
    if (!bubble) {
      var seq = _fcSequence();
      bubble = (bzMouseX >= 0 ? _bzBubbleAt(bzMouseX, bzMouseY) : null) || seq[0] || null;
    }
    if (!bubble) return false;
    if (bzLayer) _bzClose(true, false);
    fcOn = true;
    fcPendingEdge = null;
    _fcFocusBubble(bubble);
    _fcNotify('enter', _fcSequence());
    return true;
  }
  function _fcExit(keepZoom){
    if (!fcOn) return false;
    fcOn = false; fcKey = null; fcLocal = null; fcPendingEdge = null; fcLastTap = null;
    if (fcAnim) { cancelAnimationFrame(fcAnim); fcAnim = null; }
    if (fcDim) { fcDim.remove(); fcDim = null; }
    if (!keepZoom) {
      _animateZoomTo(ZOOM_REST, window.innerWidth / 2, window.innerHeight / 2, function(){
        if (ZOOM <= 1) { _recenterPan(); _applyCanvas(); }
      });
    }
    _fcNotify('exit', null);
    return true;
  }
  function _fcStep(dir){
    if (!fcOn) return false;
    var seq = _fcSequence();
    var next = seq[_fcIndex(seq, fcKey) + dir];
    if (next) { _fcFocusBubble(next); return true; }
    if (IS_WEBTOON) return false;
    // 跨页：交给 Dart 翻页；落定后（同窗翻页由 _bzAfterTranslate，换窗重建文档由
    // FC_RESUME）聚焦新跨页的第一个 / 最后一个气泡。
    var edge = dir > 0 ? 'first' : 'last';
    fcPendingEdge = edge;
    _fcNotify('turn', seq);
    var b = _bridge();
    if (!b) return true;
    var turnSeq = fcTurnSeq;
    var answer = b.callHandler('onMangaTurn', dir > 0 ? 'next' : 'prev');
    // Dart 处理完这次翻页（含换章）才答复。答复时既没翻页（没走 _fcAfterTranslate）
    // 也还在等这个落点 = 翻页被拒（书 / 章尽头、换章中）：撤销落点、留在当前气泡，
    // 并回报 state 让 Dart 清掉它那份落点。换窗 / 换章重建文档时旧脚本已销毁，不会到这里。
    if (answer && answer.then) {
      var settle = function(){
        if (fcOn && fcPendingEdge === edge && fcTurnSeq === turnSeq) {
          fcPendingEdge = null;
          _fcNotify('state', _fcSequence());
        }
      };
      answer.then(settle, settle);
    }
    return true;
  }
  function _fcFocusEdge(edge){
    var seq = _fcSequence();
    var target = edge === 'last' ? seq[seq.length - 1] : seq[0];
    fcPendingEdge = null;
    if (target) { fcOn = true; _fcFocusBubble(target); _fcNotify('enter', seq); }
    else if (fcOn) _fcExit(true);
  }
  // 翻页后：本来就在等跨页落点就聚焦过去；不是逐格读自己翻的页（点热区 / 拖动）
  // 就退出逐格读，保留当前视图。
  function _fcAfterTranslate(){
    fcTurnSeq++;
    if (!fcOn) return;
    if (!fcPendingEdge) { _fcExit(true); return; }
    var edge = fcPendingEdge;
    if (fcDim) { fcDim.remove(); fcDim = null; }
    // 翻页过渡（#manga-root 的 transform）中量到的是半路位置：等翻页落定
    // （动画收尾或被打断都算；无动画时立即）再量新跨页、聚焦首 / 末气泡。
    _onPageSettled(function(){
      if (fcOn && fcPendingEdge === edge) _fcFocusEdge(edge);
    });
  }
  function _fcRelease(p, x, y){
    var dx = x - p.x, dy = y - p.y, el = Math.max(1, Date.now() - p.t);
    var ax = Math.abs(dx), ay = Math.abs(dy);
    if (p.type !== 'mouse' && ax > ay * 1.5 &&
        (ax >= 72 || (ax >= 36 && ax / el * 1000 >= 900))) {
      _fcStep((dx > 0) === BZ_RTL ? 1 : -1);
      return;
    }
    if (ax >= 20 || ay >= 20 || el >= 500) return;
    if (p.armed) {
      // 再双击 = 退出；第一击若查了词一并撤回（与气泡放大同一条撤回路径）。
      var retract = _bzTakeSelection();
      _fcExit(false);
      if (retract) _bzNotify('close', true);
      return;
    }
    fcLastTap = {t: Date.now(), x: x, y: y};
    if (_selectOcrChar(x, y, false)) return;
    var r = fcLocal ? _fcScreenRect(fcLocal) : null;
    if (r && x >= r.l - 8 && x <= r.r + 8 && y >= r.t - 8 && y <= r.b + 8) return;
    // 点气泡外（压暗区）= 退出。
    fcLastTap = null;
    _fcExit(false);
  }
  function _fcRecentTap(x, y){
    return !!(fcLastTap && Date.now() - fcLastTap.t <= DBL_MS && _bzNear(x, y, fcLastTap));
  }
  // 逐格读里鼠标的单击（经 _onTap → _bzOnTap 进来）：点字查词；点当前气泡里的空白
  // 不动；点气泡外退出。
  function _fcTap(x, y){
    if (_selectOcrChar(x, y, false)) return true;
    var r = fcLocal ? _fcScreenRect(fcLocal) : null;
    if (r && x >= r.l - 8 && x <= r.r + 8 && y >= r.t - 8 && y <= r.b + 8) return true;
    _fcExit(false);
    return true;
  }
  // 按下时决定这次按压归谁（_bzPointerDown 调）：落在文字条 / 台词栏里归文字条；
  // 逐格读中触屏的按压归逐格读（左右滑换气泡，不平移、不翻页）。鼠标在逐格读里照常
  // 拖动平移。null = 不接管。
  function _fcClaimPress(e){
    var x = e.clientX, y = e.clientY;
    var p = {id: e.pointerId, x: x, y: y, t: Date.now(), type: e.pointerType || ''};
    if (_tsScopeAt(x, y)) { p.kind = 'ts'; return p; }
    if (fcOn && p.type !== 'mouse') { p.kind = 'fc'; p.armed = _fcRecentTap(x, y); return p; }
    return null;
  }
  // 放大层右上角的「⤢ 逐格读」。
  function _fcDecorateLayer(layer){
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'manga-bz-focus';
    btn.setAttribute('aria-label', FC_LABEL);
    btn.title = FC_LABEL;
    btn.textContent = '\\u2922';
    layer.appendChild(btn);
  }
  // 逐格读里滚轮 = 跳气泡（Ctrl+滚轮仍是缩放；台词栏里滚轮滚台词栏）。
  window.addEventListener('wheel', function(e){
    if (!fcOn || e.ctrlKey || e.metaKey) return;
    if (typeof _tsWheelInside === 'function' && _tsWheelInside(e)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    var now = Date.now();
    if (now - fcWheelT < 280) return;
    var d = e.deltaY || e.deltaX || 0;
    if (!d) return;
    fcWheelT = now;
    _fcStep(d > 0 ? 1 : -1);
  }, {passive: false, capture: true});
  // WebView 持焦时的 Tab / Shift+Tab（Flutter 持焦那条在 Dart 的 _handleReaderKey，
  // 同为固定键：逐格读开着时才拦）。
  window.addEventListener('keydown', function(e){
    if (!fcOn || e.key !== 'Tab' || e.ctrlKey || e.altKey || e.metaKey) return;
    e.preventDefault();
    _fcStep(e.shiftKey ? -1 : 1);
  }, true);
  window.__mangaFocusToggle = function(){
    if (fcOn) { _fcExit(false); return 'exit'; }
    return _fcEnter(bzLayer ? bzLayer.bubble : null) ? 'enter' : 'none';
  };
  window.__mangaFocusStep = function(dir){ return _fcStep(dir); };
  window.__mangaFocusExit = function(){ return _fcExit(false); };
  window.__mangaFocusState = function(){ return {on: fcOn, key: fcKey, zoom: ZOOM}; };
  if (FC_RESUME) {
    // 跨窗翻页重建了文档：页面排好后接着聚焦新跨页的首 / 末气泡。
    fcOn = true;
    fcPendingEdge = FC_RESUME;
    window.addEventListener('load', function(){
      requestAnimationFrame(function(){ requestAnimationFrame(function(){
        if (fcOn && fcPendingEdge) _fcFocusEdge(fcPendingEdge);
      }); });
    });
  }
  // ── 文字条 / 台词栏（方案 C）──
  var TS_ON = ${preferences.bubbleTextStrip};
  var TS_LAYOUT = '${stripLayout.name}';
  var TS_SIZE = ${preferences.bubbleTextStripSize};
  var TS_EMPTY = ${jsonEncode(stripEmptyLabel)};
  var tsEl = null, tsKey = null, tsScrollT = null;
  // 气泡的原 OCR 块（句子分组 / 无分组时的单块）。
  function _tsBoxesOf(b){
    var part = b.key.slice(b.key.indexOf(':') + 1);
    var sel = part.charAt(0) === 'b'
        ? '.ocr-box[data-manga-block="' + part.slice(1) + '"]'
        : '.ocr-box[data-manga-sentence-group="' + part + '"]';
    return Array.prototype.slice.call(b.page.querySelectorAll(sel));
  }
  function _tsItem(b){
    var wrap = document.createElement('div');
    wrap.className = 'manga-zoom-page manga-ts-item';
    wrap.setAttribute('data-page', b.page.getAttribute('data-page'));
    wrap.setAttribute('data-ts-key', b.key);
    if (b.key === tsKey) wrap.classList.add('manga-ts-active');
    _tsBoxesOf(b).forEach(function(box){
      var c = box.cloneNode(true);
      c.removeAttribute('style');
      c.classList.remove('manga-speaking', 'manga-ts-current', 'manga-ts-hover');
      c.querySelectorAll('.ocr-char').forEach(function(ch){ ch.removeAttribute('style'); });
      wrap.appendChild(c);
    });
    return wrap;
  }
  function _tsOutline(bubbles, cls){
    document.querySelectorAll('.manga-page .ocr-box.' + cls).forEach(function(el){
      el.classList.remove(cls);
    });
    bubbles.forEach(function(b){
      _tsBoxesOf(b).forEach(function(el){ el.classList.add(cls); });
    });
  }
  function _tsFind(seq, key){
    var i = _fcIndex(seq, key);
    return i >= 0 ? seq[i] : null;
  }
  function _tsBuild(){
    if (!TS_ON) return;
    if (!tsEl) {
      tsEl = document.createElement('div');
      tsEl.className = 'manga-text-strip manga-ts-' + TS_LAYOUT;
      tsEl.style.fontSize = TS_SIZE + 'px';
      tsEl.addEventListener('pointerover', function(e){
        var it = e.target && e.target.closest ? e.target.closest('.manga-ts-item') : null;
        var b = it ? _tsFind(_bzSequenceOnScreen(), it.getAttribute('data-ts-key')) : null;
        _tsOutline(b ? [b] : [], 'manga-ts-hover');
      });
      tsEl.addEventListener('pointerleave', function(){ _tsOutline([], 'manga-ts-hover'); });
      document.body.appendChild(tsEl);
    }
    var seq = _bzSequenceOnScreen();
    tsEl.textContent = '';
    if (!seq.length) {
      var empty = document.createElement('div');
      empty.className = 'manga-ts-empty';
      empty.textContent = TS_EMPTY;
      tsEl.appendChild(empty);
      _tsOutline([], 'manga-ts-current');
      return;
    }
    if (TS_LAYOUT === 'panel') {
      seq.forEach(function(b){ tsEl.appendChild(_tsItem(b)); });
      return;
    }
    var cur = _tsFind(seq, tsKey) || seq[0];
    tsKey = cur.key;
    tsEl.appendChild(_tsItem(cur));
    _tsOutline([cur], 'manga-ts-current');
  }
  function _tsSetCurrent(key){
    if (!TS_ON) return;
    tsKey = key;
    if (TS_LAYOUT === 'strip' || !tsEl) { _tsBuild(); return; }
    tsEl.querySelectorAll('.manga-ts-item').forEach(function(it){
      var on = it.getAttribute('data-ts-key') === key;
      it.classList.toggle('manga-ts-active', on);
      if (on && it.scrollIntoView) it.scrollIntoView({block: 'nearest'});
    });
  }
  function _tsStep(dir){
    var seq = _bzSequenceOnScreen();
    var next = seq[_fcIndex(seq, tsKey) + dir];
    if (!next) return false;
    if (fcOn) { _fcFocusBubble(next); return true; }
    tsKey = next.key;
    _tsBuild();
    return true;
  }
  function _tsScopeAt(x, y){
    if (!tsEl) return null;
    var r = tsEl.getBoundingClientRect();
    if (x < r.left || x > r.right || y < r.top || y > r.bottom) return null;
    return tsEl;
  }
  function _tsWheelInside(e){
    return !!(tsEl && e.target && tsEl.contains(e.target));
  }
  // 台词栏里的滚轮只滚台词栏：拦在 window 捕获阶段，document 上的缩放 / 滚轮翻页收不到。
  window.addEventListener('wheel', function(e){
    if (_tsWheelInside(e)) e.stopPropagation();
  }, {passive: true, capture: true});
  function _tsRelease(p, x, y){
    var dx = x - p.x, dy = y - p.y, el = Math.max(1, Date.now() - p.t);
    var ax = Math.abs(dx), ay = Math.abs(dy);
    // 文字条上左右滑 = 换气泡（阈值与翻页 swipe 同口径）；台词栏是竖列表，不滑。
    if (TS_LAYOUT === 'strip' && p.type !== 'mouse' && ax > ay * 1.5 &&
        (ax >= 72 || (ax >= 36 && ax / el * 1000 >= 900))) {
      _tsStep((dx > 0) === BZ_RTL ? 1 : -1);
      return;
    }
    if (ax >= 20 || ay >= 20 || el >= 500) return;
    _selectOcrChar(x, y, false);
  }
  function _tsScheduleRefresh(delay){
    if (!TS_ON) return;
    if (tsScrollT) clearTimeout(tsScrollT);
    tsScrollT = setTimeout(function(){ tsScrollT = null; _tsBuild(); }, delay);
  }
  if (TS_ON) {
    window.addEventListener('load', function(){ _tsScheduleRefresh(0); });
    requestAnimationFrame(function(){ requestAnimationFrame(_tsBuild); });
    if (IS_WEBTOON) {
      window.addEventListener('scroll', function(){
        if (!fcOn) _tsScheduleRefresh(250);
      }, {passive: true});
    }
  }
  window.__mangaTextStripRefresh = function(){ _tsBuild(); };
  // 同窗翻页之后（__mangaApplyTranslate）：逐格读接跨页落点，文字条 / 台词栏换成新跨页。
  function _bzAfterTranslate(){
    _fcAfterTranslate();
    tsKey = null;
    if (TS_ON) _onPageSettled(_tsBuild);
  }
''';
}
