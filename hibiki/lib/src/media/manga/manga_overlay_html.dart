import 'dart:ui';

import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

/// 把一页所有 mokuro block 渲染成绝对定位的透明 `<p class="ocr-box">` 层。
///
/// 关键不变式（依据 reader_selection_scripts.dart）：
/// - 每个 block 一个 `<p>`（findParagraph 认 p → 扫描 TreeWalker 根落框内，天然不跨框）。
/// - 框内多行用 `<br>` 连接，绝不用 `\n`（`\n` 是 scanDelimiter，会截断扫描）。
/// - 坐标取百分比（box / page.size），自适应缩放。
/// - 字号用容器查询单位 `cqi`（fontSize / img_width * 100），相对 `.manga-page`
///   容器的 inline-size（宽度）等比缩放，让透明文字铺满本页框、命中区域与可视框
///   一致。绝不用 `font-size:%`：% 相对父字号≈1.6px 会让透明文字塌缩到框角，导致
///   点击全部 miss（ERRATA H5）。spread 双页各自相对本页宽度，故用容器查询单位而
///   非 vh/vw（vh/vw 跨页共用视口会算错另一半页）。
///   用 `inline-size` 容器而非 `size`：`container-type:size` 建立两轴 size
///   containment，会让 img 驱动的页高塌成 0（容器尺寸不受后代影响）；
///   `inline-size` 只约束宽度轴，页高仍由 `<img height:auto>` 正常撑开。
/// - 竖排框 writing-mode:vertical-rl；文字 color:transparent；margin/padding 清零；
///   pointer-events:auto（仅底图 <img> 为 none）。
String mangaOcrBoxesHtml(MokuroImage page) {
  final double pageWidth = page.size.width <= 0 ? 1 : page.size.width;
  final double pageHeight = page.size.height <= 0 ? 1 : page.size.height;
  final StringBuffer buffer = StringBuffer();
  for (final MokuroBlock block in page.blocks) {
    final Rect r = block.rectangle;
    final double leftPct = (r.left / pageWidth) * 100;
    final double topPct = (r.top / pageHeight) * 100;
    final double widthPct = (r.width / pageWidth) * 100;
    final double heightPct = (r.height / pageHeight) * 100;
    // ERRATA H5：字号按页宽折算为容器查询 inline-size 单位（cqi），随 .manga-page
    // 容器宽度等比缩放，让透明文字铺满 OCR 框、命中区域与可视框一致。用 cqi 而非
    // cqh，因容器是 inline-size 类型（size 类型会塌缩 img 驱动的页高，见上方文档）。
    // ERRATA M1：mokuro 偶尔给 font_size==0（缺字段容错回退）→ font-size:0cqi 会把
    // 透明文字塌成 0 高、整框命中区域塌缩到原点，点框全 miss。给一个非零下限
    // （3cqi≈正常正文字号档），保证框始终可命中。
    final double rawCqi = (block.fontSize / pageWidth) * 100;
    final double fontCqi = rawCqi > 0 ? rawCqi : 3.0;
    final String writingMode =
        block.isVertical ? 'writing-mode:vertical-rl;' : '';
    final String inner =
        block.lines.map(_escapeHtml).join('<br>'); // 行间 <br>，绝不 \n
    buffer.write('<p class="ocr-box" style="'
        'position:absolute;'
        'left:${_pct(leftPct)};'
        'top:${_pct(topPct)};'
        'width:${_pct(widthPct)};'
        'height:${_pct(heightPct)};'
        'font-size:${_num(fontCqi)}cqi;'
        '$writingMode'
        'color:transparent;'
        'margin:0;'
        'padding:0;'
        'pointer-events:auto;'
        '">$inner</p>');
  }
  return buffer.toString();
}

/// 一整页：底图 `<img pointer-events:none>` + 上层 OCR 框。
///
/// `.manga-page` 声明 `container-type:inline-size`，为框字号的 `cqi` 单位提供参照
/// 宽度（ERRATA H5）；每页独立成容器，spread 双页各自相对本页宽。用 inline-size 而
/// 非 size：size containment 会让 img 驱动的页尺寸塌成 0、所有百分比框塌到原点重叠
/// 串字；inline-size 只约束宽度轴。
///
/// 尺寸策略（CRITICAL-1 修复，re-review）：spread 模式下「一个跨页单元恰好占 100vw
/// 并居中」是硬约束——故 spread 改为**槽宽驱动**：每页给一个 definite 宽度
/// `width:(100/pagesInSpread)vw`（双页 50vw / 单页 100vw），高度由 `aspect-ratio`
/// 从 definite 宽度推出。这样跨页单元横向恒等于 100vw，消除了原「渲染宽=100vh*(w/h)
/// >100vw 单页就被横向裁切」的 bug。`<img object-fit:contain>` 让页在槽内等比内含：
/// 竖屏下高页只上下留白；但**短/横屏视口**下槽高(slotWidth·h/w)可能 > 100vh，被
/// `#manga-viewport{overflow:hidden;height:100vh}` 上下居中裁切——属设备宽高比权衡，
/// 留真机横屏复核（NEW-4）。webtoon 仍是宽驱动（每页宽=100vw），由窗口文档 style 块给定。
/// [spreadIndex] 标注本页所属的跨页号（写入 `data-spread`）。[pagesInSpread] 标注本页
/// 所在跨页的页数（1=单页 / 2=双页），决定 spread 槽宽；写入 `data-spread-pages` 仅供
/// 调试/测试，槽宽本身由内联 `width` 落实，不依赖 CSS 类选择。
///
/// [pageIndex] 是本页在整卷里的 0-based 页码（写入 `data-page`），连同页图原始
/// 像素尺寸（`data-pw` / `data-ph`）供补扫模式把视口矩形换算回**页图像素坐标**：
/// div 的 aspect-ratio 与页图一致 + `object-fit:contain`，图恒铺满 div（无信箱
/// 留白），故 div getBoundingClientRect 与页图像素是纯线性映射。
String mangaPageDivHtml(MokuroImage page, String imgSrc,
    {int spreadIndex = 0,
    int pagesInSpread = 1,
    int pageIndex = 0,
    bool isWebtoon = false}) {
  // div 内联声明：
  // - position:relative —— OCR 框绝对定位的包含块。
  // - container-type:inline-size —— cqi 参照宽（自包含，不依赖外部 style 块）。
  // spread：内联 width 给 definite 宽（50vw/100vw），高由 aspect-ratio 推；
  //   inline-size containment 不阻止显式 width（width 是 used value，非内容撑开），
  //   故 OCR 框 cqi 参照有效、底图按 object-fit:contain 等比内含进槽。
  // webtoon：宽由 style 块的 .manga-page{width:100vw} 给定（外部），这里只给
  //   aspect-ratio 让高从 definite 宽推出，不再内联 width（避免与 style 块冲突）。
  final double w = page.size.width <= 0 ? 1 : page.size.width;
  final double h = page.size.height <= 0 ? 1 : page.size.height;
  // spread 槽宽：双页各占 50vw、单页占 100vw，跨页单元横向合计恒 100vw。
  final int slots = pagesInSpread <= 1 ? 1 : pagesInSpread;
  final String widthCss = isWebtoon ? '' : 'width:${_num(100.0 / slots)}vw;';
  return '<div class="manga-page" data-spread="$spreadIndex" '
      'data-spread-pages="$pagesInSpread" '
      'data-page="$pageIndex" data-pw="${_num(w)}" data-ph="${_num(h)}" '
      'style="position:relative;container-type:inline-size;'
      '$widthCss'
      'aspect-ratio:${_num(w)}/${_num(h)};">'
      '<img src="${_escapeAttr(imgSrc)}" loading="lazy" decoding="async" '
      'style="pointer-events:none;">'
      '${mangaOcrBoxesHtml(page)}'
      '</div>';
}

/// 自包含窗口文档：spread → flex-row（RTL 经 direction:rtl 排序）+ 视口裁剪 +
/// translateX 只显示当前跨页；webtoon → 竖向堆叠 + 滚动。内联选词 JS + 一个
/// 手势机（swipe→翻页 / scroll→滚动报告 / tap→选词或放大）。
///
/// ERRATA C1（选词路径收敛不变式）：本文档对 OCR 框的 `selectText` 调用是**全工程
/// 唯一**一处，调用 `hoshiSelection.selectText(e.clientX, e.clientY, 40, false)`
/// （四参：maxLength=40 + fromHover=false，对齐 develop 的四参签名 TODO-851）。
/// 漏 maxLength → 扫描循环 gate `< undefined` 恒假 → text 恒空 →
/// onTextSelected 永不触发（查词哑火）。Task 19 的内联选区 JS 只注入
/// ReaderSelectionScripts 的定义，不得再加第二处 selectText。手势机与选词
/// pointerup 共存，但选词命中仍只这一条路径（tap 且命中 `.ocr-box` 才走 selectText）。
///
/// ERRATA C1（翻页导航）：spread 模式把 strip 包进 `#manga-viewport`
/// (`overflow:hidden`)，每跨页单元宽恒 100vw（双页 50vw×2 / 单页 100vw），靠
/// translateX 平移使**只显示当前跨页**（RTL 取镜像）；翻页/恢复定位都改 translateX，
/// 不重 loadData。
///
/// webtoon（HIGH-2 修复，re-review）：调用方把**全部页**一次性渲染进单文档（不做
/// 窗口化/不滑窗 loadData——窗口化只是 spread 的优化），靠文档竖滚翻页；`onMangaScroll`
/// 只更新进度，绝不在滚动中 loadData 重建（否则在手指下抹掉重建抖动/抢滚）。恢复用
/// 页内 fraction（`__mangaScrollToSpread`）一次定位即可。
///
/// [currentSpread] 是恢复/翻页时要对齐到视口的跨页号；[restoreFraction] 是 webtoon
/// 恢复时的**页内**归一化偏移（0..1，spread 忽略）。[pagesPerSpread] 与 [pages] 等长，
/// 给每页标注其所在跨页的页数（spread 槽宽 50vw/100vw 用）。手势经 `onMangaTurn`(+1/-1)、
/// `onMangaScroll`({fraction, topPage}) 回 Dart 推进 `_currentSpread`/`_currentPage`。
String mangaWindowDocument(
  List<MokuroImage> pages,
  List<String> imgSrcs, {
  required MangaReadingMode mode,
  required String spreadDirection,
  required String inlineSelectionJs,
  List<int>? pageSpreadIndices,
  List<int>? pagesPerSpread,
  List<int>? pageNumbers,
  int currentSpread = 0,
  double restoreFraction = 0,
}) {
  final bool isWebtoon = mode == MangaReadingMode.webtoon;
  // RTL 仅对 spread 横排有意义；direction:rtl 让 flex-row 从右往左排页。
  final bool rtl = !isWebtoon && spreadDirection == 'rtl';
  final String directionCss = rtl ? 'direction:rtl;' : 'direction:ltr;';

  final StringBuffer pagesHtml = StringBuffer();
  final int count =
      pages.length < imgSrcs.length ? pages.length : imgSrcs.length;
  for (int i = 0; i < count; i++) {
    final int spreadIndex =
        (pageSpreadIndices != null && i < pageSpreadIndices.length)
            ? pageSpreadIndices[i]
            : 0;
    // 本页所在跨页的页数（CRITICAL-1：决定 spread 槽宽 50vw/100vw）。缺省/webtoon
    // 视为单页。
    final int slotPages =
        (!isWebtoon && pagesPerSpread != null && i < pagesPerSpread.length)
            ? pagesPerSpread[i]
            : 1;
    // 真实页码（窗口化文档里数组序 != 整卷页码）；缺省退回数组序（webtoon 全量
    // 渲染时两者一致）。
    final int pageNumber =
        (pageNumbers != null && i < pageNumbers.length) ? pageNumbers[i] : i;
    pagesHtml.write(mangaPageDivHtml(
      pages[i],
      imgSrcs[i],
      spreadIndex: spreadIndex,
      pagesInSpread: slotPages,
      pageIndex: pageNumber,
      isWebtoon: isWebtoon,
    ));
  }

  // 容器尺寸策略（CRITICAL-1 修复，re-review）：给 .manga-page 一个 definite 轴
  // （视口单位），另一轴由内联 aspect-ratio 推出（见 mangaPageDivHtml），使两轴都
  // definite → inline-size containment 下 cqi 参照有效、OCR 框百分比不塌缩。
  // - spread（flex-row）：每页**宽**= (100/跨页页数)vw（双页 50vw / 单页 100vw，
  //   内联给定），高由 aspect-ratio 推出。一个跨页单元横向恒占 100vw，消除横向溢出
  //   裁切；竖版长页竖屏下上下留白（img object-fit:contain），短/横屏视口下可能上下
  //   居中裁切（设备权衡）。#manga-viewport 锁高
  //   100vh + align-items:center 让页在视口内垂直居中，overflow:hidden 横向裁剪、
  //   translateX 平移到当前跨页。
  // - webtoon（column）：每页宽=100vw，高由 aspect-ratio 推出，文档竖滚。
  // 用视口单位而非 height:100% 链：WebView initialData 文档 html/body 高度链常解析
  // 为 0。
  final String rootSizing = isWebtoon
      ? '#manga-root{display:flex;flex-direction:column;$directionCss'
          'width:100vw;align-items:flex-start;}'
          '.manga-page{width:100vw;}'
      : '#manga-viewport{overflow:hidden;width:100vw;height:100vh;}'
          '#manga-root{display:flex;flex-direction:row;$directionCss'
          'height:100vh;align-items:center;'
          'transition:transform 0.18s ease-out;will-change:transform;}';

  // spread 时 strip 包进 overflow:hidden 视口；webtoon 时 root 直接在 body。
  final String body = isWebtoon
      ? '<div id="manga-root">${pagesHtml.toString()}</div>'
      : '<div id="manga-viewport">'
          '<div id="manga-root">${pagesHtml.toString()}</div>'
          '</div>';

  return '<!DOCTYPE html>'
      '<html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1,'
      'maximum-scale=1,user-scalable=no">'
      '<style>'
      // BUG-051：禁用原生文字选区 + 图片拖拽。桌面 WebView 上鼠标拖动会触发浏览器
      // 原生 image drag-and-drop / 文字选区，拖出一个半透明残影（用户称「秃瓢」）并
      // 抢走指针，让 swipe→onMangaTurn 哑火。查词走坐标式 DOM 读取（hoshiSelection
      // 用 elementFromPoint + TreeWalker + createRange，不依赖 window.getSelection），
      // 故禁 user-select 不影响查词，反而让鼠标拖动变成干净的 swipe。
      'html,body{margin:0;padding:0;background:#000;height:100%;'
      '-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;}'
      '$rootSizing'
      '.manga-page{position:relative;flex:0 0 auto;'
      'container-type:inline-size;}'
      '.manga-page img{display:block;width:100%;height:100%;'
      'object-fit:contain;-webkit-user-drag:none;user-drag:none;}'
      '.ocr-box{margin:0;padding:0;pointer-events:auto;}'
      '</style></head>'
      '<body>'
      '$body'
      '<script>$inlineSelectionJs</script>'
      '<script>'
      '${_mangaGestureJs(
    isWebtoon: isWebtoon,
    rtl: rtl,
    currentSpread: currentSpread,
    restoreFraction: restoreFraction,
  )}'
      '</script>'
      '</body></html>';
}

/// 内联手势机 + 翻页/滚动几何。一个 pointerdown/pointerup 对（消歧 tap vs swipe）+
/// webtoon 滚动监听 + spread 鼠标滚轮翻页（BUG-051）。tap 命中 `.ocr-box` → 选词
/// （唯一 selectText 路径）；tap 命中裸图（`.manga-page img`，框间）→ `onImageTap`（H1）。
/// swipe（仅 spread）→ `onMangaTurn`。spread 鼠标 `wheel` → `onMangaTurn`（桌面 swipe
/// 等价物，overflow:hidden 视口下滚轮本是死操作；带 320ms 锁合并连发）。webtoon 滚动
/// 节流 → `onMangaScroll`。`dragstart` 全程 preventDefault + CSS user-select/user-drag
/// 禁用，消除桌面拖动时的原生图片/选区残影（「秃瓢」）。手势阈值镜像 reader
/// （absDx>absDy 判 swipe，小位移判 tap）。spread translateX 在 [_mangaApplyTranslate]
/// 按 data-spread 测量。
///
/// 补扫模式（P4）：Dart 调 `window.__mangaSetRescanMode(true/false)` 进入/退出；
/// 模式内指针独占给橡皮筋框选（查词/swipe/滚轮翻页全旁路），松手换算页图像素
/// 坐标经 `onMangaBoxSelected` 回 Dart（协议见函数体注释）。
String _mangaGestureJs({
  required bool isWebtoon,
  required bool rtl,
  required int currentSpread,
  required double restoreFraction,
}) {
  // RTL：strip 视觉镜像，但 DOM offsetLeft 仍是几何坐标；translateX 统一把目标跨页
  // 首页 offsetLeft 平移到视口左边缘（width=100vw 的视口里目标跨页正好填满）。
  return '''
(function(){
  function _bridge(){ return window.flutter_inappwebview; }
  // ── spread translateX：把 data-spread==target 的首页平移到视口左边缘 ──
  window.__mangaApplyTranslate = function(target){
    var root = document.getElementById('manga-root');
    if (!root) return;
    var pages = root.querySelectorAll('.manga-page[data-spread="'+target+'"]');
    if (!pages.length) { root.style.transform = 'translateX(0px)'; return; }
    var first = pages[0];
    // 取目标跨页 DOM 上最靠左的页（RTL 双页时 offsetLeft 最小的那张）。
    for (var i = 1; i < pages.length; i++) {
      if (pages[i].offsetLeft < first.offsetLeft) first = pages[i];
    }
    root.style.transform = 'translateX(' + (-first.offsetLeft) + 'px)';
  };
  // ── webtoon scrollTo：恢复时把 data-spread==target 的页顶滚进视口，再按**页内**
  //    fraction 微调（HIGH-1：fraction 是 (scrollY-page.offsetTop)/page.offsetHeight
  //    页内归一化，与 onMangaScroll 报的口径一致；绝非文档全局 fraction）──
  window.__mangaScrollToSpread = function(target, fraction){
    var page = document.querySelector('.manga-page[data-spread="'+target+'"]');
    if (!page) return;
    var top = page.offsetTop + (fraction || 0) * page.offsetHeight;
    window.scrollTo(0, top);
  };
  // ── 补扫模式（P4 单框补扫）──
  // Dart 经 window.__mangaSetRescanMode(true/false) 进入/退出。模式内：
  // - pointer 拖出橡皮筋矩形（fixed 定位半透明框，纯视觉反馈）；
  // - 查词 tap / swipe 翻页 / 滚轮翻页全部旁路（选区手势独占指针）；
  // - 松手把视口矩形换算成**页图像素坐标**（框中心命中的 .manga-page 的
  //   data-page/data-pw/data-ph + getBoundingClientRect 线性映射；spread 跨页时
  //   以框中心判定落页并 clamp 进该页），经 onMangaBoxSelected 回 Dart；
  // - 任一维 < 8px（视口坐标）忽略并保持模式（用户重画）；
  // - 有效框发出后自动退出模式（Dart 端收到即复位按钮态）。
  var RESCAN = false;
  var rescanStart = null;
  var rescanEl = null;
  window.__mangaSetRescanMode = function(on){
    RESCAN = !!on;
    // 模式内禁掉触摸原生滚动（webtoon 竖滚会抢拖框手势）。
    document.body.style.touchAction = RESCAN ? 'none' : '';
    if (!RESCAN) _rescanClear();
  };
  function _rescanClear(){
    if (rescanEl && rescanEl.parentNode) rescanEl.parentNode.removeChild(rescanEl);
    rescanEl = null;
    rescanStart = null;
  }
  function _rescanUpdate(x, y){
    if (!rescanStart) return;
    if (!rescanEl) {
      rescanEl = document.createElement('div');
      rescanEl.id = 'manga-rescan-rect';
      rescanEl.style.cssText = 'position:fixed;z-index:2147483647;'
        + 'pointer-events:none;border:2px solid rgba(66,165,245,0.9);'
        + 'background:rgba(66,165,245,0.25);';
      document.body.appendChild(rescanEl);
    }
    rescanEl.style.left = Math.min(rescanStart.x, x) + 'px';
    rescanEl.style.top = Math.min(rescanStart.y, y) + 'px';
    rescanEl.style.width = Math.abs(x - rescanStart.x) + 'px';
    rescanEl.style.height = Math.abs(y - rescanStart.y) + 'px';
  }
  function _rescanFinish(x, y){
    var start = rescanStart;
    _rescanClear();
    if (!start) return;
    if (Math.abs(x - start.x) < 8 || Math.abs(y - start.y) < 8) return;
    var cx = (start.x + x) / 2, cy = (start.y + y) / 2;
    var pages = document.querySelectorAll('.manga-page');
    var target = null, tr = null;
    for (var i = 0; i < pages.length; i++) {
      var r = pages[i].getBoundingClientRect();
      if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
        target = pages[i];
        tr = r;
        break;
      }
    }
    if (!target || tr.width <= 0 || tr.height <= 0) return;
    var pw = parseFloat(target.getAttribute('data-pw')) || 0;
    var ph = parseFloat(target.getAttribute('data-ph')) || 0;
    if (pw <= 0 || ph <= 0) return;
    var pageIndex = parseInt(target.getAttribute('data-page'), 10) || 0;
    function toPx(v){ return Math.min(pw, Math.max(0, (v - tr.left) / tr.width * pw)); }
    function toPy(v){ return Math.min(ph, Math.max(0, (v - tr.top) / tr.height * ph)); }
    RESCAN = false;
    document.body.style.touchAction = '';
    var b = _bridge();
    if (!b) return;
    b.callHandler('onMangaBoxSelected', JSON.stringify({
      pageIndex: pageIndex,
      left: toPx(Math.min(start.x, x)),
      top: toPy(Math.min(start.y, y)),
      right: toPx(Math.max(start.x, x)),
      bottom: toPy(Math.max(start.y, y))
    }));
  }
  document.addEventListener('pointermove', function(e){
    if (RESCAN && rescanStart) _rescanUpdate(e.clientX, e.clientY);
  }, {passive: true});
  var IS_WEBTOON = $isWebtoon;
  var CURRENT = $currentSpread;
  var RESTORE_FRACTION = ${restoreFraction.toStringAsFixed(6)};
  function _initPosition(){
    if (IS_WEBTOON) window.__mangaScrollToSpread(CURRENT, RESTORE_FRACTION);
    else window.__mangaApplyTranslate(CURRENT);
  }
  // 图片/布局完成前 offsetLeft/offsetTop 可能为 0；首帧后 + load 后各定位一次。
  if (document.readyState === 'complete') { _initPosition(); }
  window.addEventListener('load', _initPosition);
  requestAnimationFrame(function(){ requestAnimationFrame(_initPosition); });

  // ── 手势消歧（pointer，覆盖触摸/鼠标）──
  var sx = 0, sy = 0, st = 0, has = false;
  function _start(x, y){ has = true; sx = x; sy = y; st = Date.now(); }
  // OCR 框 / 裸图判定一律用坐标（elementFromPoint），与 selectText 内部命中口径一致，
  // 不依赖 e.target（事件冒泡/合成事件时 e.target 可能是 root 而非框）。
  function _hitOcrBox(x, y){
    var el = document.elementFromPoint(x, y);
    return !!(el && el.closest && el.closest('.ocr-box'));
  }
  function _imgUrlAt(x, y){
    var el = document.elementFromPoint(x, y);
    var page = el && el.closest ? el.closest('.manga-page') : null;
    if (!page) return null;
    var img = page.querySelector('img');
    return img && img.src ? img.src : null;
  }
  function _onTap(x, y){
    var b = _bridge();
    if (!b) return;
    if (_hitOcrBox(x, y)) {
      // 唯一 selectText 路径（命中框才走选词）。
      if (window.hoshiSelection) window.hoshiSelection.selectText(x, y, 40, false);
      return;
    }
    // 框间裸图 → 放大（H1）。
    var url = _imgUrlAt(x, y);
    if (url) b.callHandler('onImageTap', url);
    else b.callHandler('onTapEmpty');
  }
  function _end(x, y){
    // 无配对 pointerdown（has=false）：合成事件或捕获丢失，没有位移可判 swipe →
    // 只能是 tap，直接走 tap 路径（不丢选词）。
    if (!has) { _onTap(x, y); return; }
    has = false;
    var dx = x - sx, dy = y - sy, el = Date.now() - st;
    var ax = Math.abs(dx), ay = Math.abs(dy);
    var vel = ax / Math.max(1, el) * 1000;
    if (!IS_WEBTOON && ax > ay && (ax >= 72 || (ax >= 36 && vel >= 900))) {
      var b = _bridge();
      if (!b) return;
      // RTL：向左滑（dx<0）视觉上是「下一跨页」（往故事推进，左移露出左侧后续页）；
      // LTR：向左滑是上一跨页。dir 语义统一为「页序方向」(+1 进 / -1 退)，由 Dart 端
      // 依据已知阅读方向 clamp。这里只报方向：左滑 -> 'next'，右滑 -> 'prev'。
      b.callHandler('onMangaTurn', dx < 0 ? 'next' : 'prev');
    } else if (ax < 20 && ay < 20 && el < 500) {
      _onTap(x, y);
    }
  }
  document.addEventListener('pointerdown', function(e){
    if (e.button !== 0) return;
    if (RESCAN) { rescanStart = {x: e.clientX, y: e.clientY}; return; }
    _start(e.clientX, e.clientY);
  }, {passive: true});
  document.addEventListener('pointerup', function(e){
    if (e.button !== 0) return;
    if (RESCAN) { _rescanFinish(e.clientX, e.clientY); return; }
    _end(e.clientX, e.clientY);
  }, {passive: false});

  // ── 桌面鼠标滚轮翻页（仅 spread，BUG-051）──
  // spread 的 #manga-viewport 是 overflow:hidden，滚轮本就无处可滚（死操作）；
  // 把它复用为翻页——这是桌面端 swipe 的等价物（PC 漫画阅读器惯例）。webtoon 保留
  // WebView 自身的原生竖向滚动，故不在此接线（否则会抢走正常滚动）。一次滚轮事件
  // 流（尤其触控板惯性）可能连发多个 wheel，用 _wheelLock 在 320ms 内合并为一次翻页，
  // 避免一格滚动翻一叠页。
  if (!IS_WEBTOON) {
    var _wheelLock = false;
    document.addEventListener('wheel', function(e){
      e.preventDefault();
      if (RESCAN) return;
      if (_wheelLock) return;
      var d = e.deltaY || e.deltaX || 0;
      if (Math.abs(d) < 2) return;
      var b = _bridge();
      if (!b) return;
      _wheelLock = true;
      setTimeout(function(){ _wheelLock = false; }, 320);
      // 向下/向右滚 = 页序前进（next），向上/向左 = 后退（prev）；Dart 端按阅读
      // 方向已统一 clamp（与 swipe 同口径）。
      b.callHandler('onMangaTurn', d > 0 ? 'next' : 'prev');
    }, {passive: false});
  }
  // ── 抑制原生拖拽残影（BUG-051「秃瓢」）──
  // 即使 user-select/user-drag 已禁，部分 WebView 仍会在拖动时发 dragstart 拉出
  // 残影；显式 preventDefault 兜底，让鼠标拖动只走 swipe 手势路径。
  document.addEventListener('dragstart', function(e){
    e.preventDefault();
  }, {passive: false});

  // ── webtoon 滚动报告（节流）──
  // HIGH-1：报**页内** fraction（视口顶部所在页内的归一化偏移 0..1），与
  // __mangaScrollToSpread 的口径统一——绝不报文档全局 fraction（那会被当页内
  // offset 用，恢复/定位错一整页）。topPage = 视口顶部所在页的 data-spread，
  // fraction 与 topPage 同源（同一页）。
  if (IS_WEBTOON) {
    var _scrollTimer = null;
    window.addEventListener('scroll', function(){
      if (_scrollTimer) return;
      _scrollTimer = setTimeout(function(){
        _scrollTimer = null;
        var b = _bridge();
        if (!b) return;
        var y = window.scrollY;
        // 视口顶部所在页（getBoundingClientRect().bottom>1 的第一页）。
        var topPage = 0;
        var fraction = 0;
        var pages = document.querySelectorAll('.manga-page');
        for (var i = 0; i < pages.length; i++) {
          var r = pages[i].getBoundingClientRect();
          if (r.bottom > 1) {
            topPage = parseInt(pages[i].getAttribute('data-spread'), 10) || 0;
            // 页内归一化：(scrollY - page.offsetTop) / page.offsetHeight。
            var oh = pages[i].offsetHeight;
            if (oh > 0) {
              fraction = Math.min(1, Math.max(0, (y - pages[i].offsetTop) / oh));
            }
            break;
          }
        }
        b.callHandler('onMangaScroll', JSON.stringify({ fraction: fraction, topPage: topPage }));
      }, 120);
    }, {passive: true});
  }
})();
''';
}

/// 百分比格式化：去掉无意义尾零（10% 而非 10.0%），保留必要精度。
String _pct(double value) => '${_num(value)}%';

/// 数字格式化：去掉无意义尾零（1.6 而非 1.6000；10 而非 10.0000）。
String _num(double value) {
  final String s = value.toStringAsFixed(4);
  if (!s.contains('.')) {
    return s;
  }
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}

String _escapeHtml(String input) {
  return input
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
}

String _escapeAttr(String input) {
  return _escapeHtml(input).replaceAll('"', '&quot;');
}
