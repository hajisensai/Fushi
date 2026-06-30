import 'dart:math' as math;

import 'package:hibiki/src/reader/reader_settings.dart';

class ReaderLayoutDefaults {
  ReaderLayoutDefaults._();

  static const int fontSizePx = 22;
  static const int bottomOverlapPx = fontSizePx;
  static const double imageWidthViewportRatio = 0.95;

  // TODO-729：分页列间距固定为常量（对齐安卓 ReaderContentStyles.kt
  // columnGapCss = "calc(0vh + 22px)"）。column-gap 是「列周期 = column-width +
  // column-gap」里恒定的一项，**不得**再把 margin / fontSize / chrome inset 塞进它
  // —— 那些 inset 唯一由 padding 承载（见 css() 的 padding-top/bottom）。gap 固定后，
  // JS getScrollContext 的 pageStep(=content-box + gap) 恒等于浏览器真实列周期，
  // maxScroll = totalSize - pageStep 与对齐量同源，杜绝「翻一半跳章」（pitch≠列周期失配）。
  static const int columnGapPx = fontSizePx;

  // TODO-362（PR#3 响应式页边距）：默认左右各 2vw（= ReaderSettings 默认左右 2%），
  // 上下 0。运行时实际 padding 由 marginTop/Bottom/Left/Right 动态算（见 css()），
  // 此常量是文档化的默认快照。
  static const String pagePaddingCss = '0vh 2vw';
  static const String imageMaxWidthFallbackCss = '95vw';
  static const String imageMaxHeightFallbackCss =
      'calc(var(--page-height, 100vh) - 22px)';
  static const String trailingSpacerHeightCss = 'calc(0vh + 22px)';
  static const String trailingSpacerWidthCss = '0';
}

class ReaderContentStyles {
  ReaderContentStyles._();

  // TODO-734：竖排分页列高（content-box）的唯一真相源，由 CSS 模板、JS 几何与
  // 代数守卫共用，消除「CSS 改一半 / JS 改一半」复活 TODO-729 跳章的风险。
  //
  // 量纲分离（根因修复）：`--page-height`(= V + bottomOverlap=O) 同时被两处消费——
  // 图片 max-height / scrollHeight 需要虚高 V+O（保 TODO-627 图片页），而竖排列高
  // 只该用纯视口高 V。原实现把列高建在含 +O 的 `--page-height` 上 → 列底边落
  // V−cB+(O−F)，字号 F<O(=22) 时漏出 (O−F) 进底栏。这里改用新变量
  // `--reader-viewport-height`(= 纯 V)，与 JS getScrollContext 的 viewportHeight
  // 成对一致：column-width(CSS) == contentBox(JS) == V−F−cT−cB，pageStep==realPitch
  // 保持，列底边 = V−F−cB ≤ V−cB（漏 0，且与 F 无关）。
  //
  // 注意：JS 端必须把 viewportHeight 注入为 `--reader-viewport-height` 且
  // hoshiReader.viewportHeight = V（见 reader_pagination_scripts.dart 的
  // initialize / updatePageSize），否则 CSS 变量为空回退 100vh、列高失配复活跳章。
  //
  // TODO-743（P0 坍塌地板）：当 cT + cB + F ≥ V（横屏短边小 + 大字号）时，上面的
  // calc 算成负值 → 浏览器把 column-width 钳成 0 → 单列容不下一字、几十列横向叠印
  // （正文全错位）。这里包一层 `max(${fontSizePx}px, calc(...))` 地板：正常视口
  // calc 远大于一个字宽，max 取 calc，零行为变化；坍塌区取 fontSizePx 地板，列宽
  // 永不到 0。max() 全平台 WebView（Chromium / WebView2 / WKWebView）均支持。
  // 注意：JS getScrollContext 的 contentBox 必须用同一个 fontSizePx 地板（见
  // reader_pagination_scripts.dart 的 Math.max(parseFloat(cs.fontSize), contentBox)），
  // 否则坍塌区 CSS↔JS 列周期失配复活跳章。
  static String verticalColumnWidthCss({
    required double marginTopVh,
    required double marginBottomVh,
    required int fontSizePx,
  }) =>
      'max(${fontSizePx}px, calc(var(--reader-viewport-height, 100vh) - ${marginTopVh}vh - ${marginBottomVh}vh - ${fontSizePx}px - var(--chrome-top-inset, 0px) - var(--chrome-bottom-inset, 0px)))';

  /// TODO-734：竖排列高 content-box 的纯代数值（px），与 [verticalColumnWidthCss]
  /// 的 `max(F, calc(...))` 逐项同构。仅供代数守卫核算漏出量用，不参与 CSS 生成。
  /// V=视口高，F=字号，mt/mb=上下页边距(px)，cT/cB=chrome 上下 inset(px)。
  ///
  /// TODO-743（P0 坍塌地板）：与 CSS 的 `max(${fontSizePx}px, calc(...))` 成对——当
  /// cT + cB + F ≥ V（横屏短边小 + 大字号）时裸 calc 为负，浏览器把 column-width 钳
  /// 成 0 → 列叠印。这里用 `math.max(fontSizePx, 裸代数)` 夹同一个 fontSizePx 地板，
  /// 正常视口裸值远大于地板（max 取裸值，零行为变化），坍塌区返回 fontSizePx 地板。
  static double verticalColumnContentHeight({
    required double viewportHeightPx,
    required double fontSizePx,
    required double marginTopPx,
    required double marginBottomPx,
    required double chromeTopInsetPx,
    required double chromeBottomInsetPx,
  }) =>
      math.max(
        fontSizePx,
        viewportHeightPx -
            marginTopPx -
            marginBottomPx -
            fontSizePx -
            chromeTopInsetPx -
            chromeBottomInsetPx,
      );

  static String styleTag({
    required ReaderSettings settings,
    String? fontFaces,
    String? fontFamily,
    String? customBg,
    String? customFg,
    String? selectionColor,
    String? sasayakiColor,
    String? linkColor,
    String? themeOverride,
  }) {
    return '<style>\n${css(
      settings: settings,
      fontFaces: fontFaces,
      fontFamily: fontFamily,
      customBg: customBg,
      customFg: customFg,
      selectionColor: selectionColor,
      sasayakiColor: sasayakiColor,
      linkColor: linkColor,
      themeOverride: themeOverride,
    )}\n</style>';
  }

  static String css({
    required ReaderSettings settings,
    String? fontFaces,
    String? fontFamily,
    String? customBg,
    String? customFg,
    String? selectionColor,
    String? sasayakiColor,
    String? linkColor,
    String? themeOverride,
  }) {
    final _ThemeColors colors = _themeColors(themeOverride ?? settings.theme,
        customBg: customBg, customFg: customFg);

    // 查词高亮用「预合成到背景色的不透明色」：在无重叠区与原半透明色像素一致，
    // 但在与音频(sasayaki)高亮重叠区会覆盖其下的灰层 → 单层、查词优先、无双重高亮
    // (BUG-125)。同时去掉旧的 <rt> 不透明遮罩(原 BUG-123)，那个遮罩会连基字右缘一起
    // 抹掉(竖排 jukugo ruby 的振假名盒压在基字右缘上)。
    final String selectionBase = selectionColor ?? colors.selectionColor;
    final String selectionOpaque =
        composeOpaqueColor(selectionBase, colors.backgroundColor);

    final String resolvedFontFaces;
    final String resolvedFontFamily;
    if (fontFaces != null && fontFamily != null) {
      resolvedFontFaces = fontFaces;
      resolvedFontFamily = '$fontFamily, serif';
    } else {
      final ({String fontFamily, String fontFaces}) custom =
          settings.buildCustomFontCss();
      resolvedFontFaces = custom.fontFaces;
      resolvedFontFamily = custom.fontFamily.isNotEmpty
          ? '${custom.fontFamily}, serif'
          : 'serif';
    }

    final bool isVertical = settings.writingMode.startsWith('vertical');
    // CSS padding does not accept negative values; clamp to 0.
    final double mt = math.max(0, settings.marginTop);
    final double mb = math.max(0, settings.marginBottom);
    final double ml = math.max(0, settings.marginLeft);
    final double mr = math.max(0, settings.marginRight);

    final String paddingCss = '${mt}vh ${mr}vw ${mb}vh ${ml}vw';
    // TODO-792 续（相邻页/列露出 bleed 修复）：分页模式视口比单列周期大（viewport > pageStep），
    // 多出的部分在页边缘露出上/下页（竖排）或左/右页（横排）的相邻列。clip-path 以 body 边框盒
    // （固定视口帧，margin/border=0 即视口）为基准、裁到**正文内容盒**（= 全 padding：四边各等于
    // body 实际 padding），把滚进留白区的相邻列裁掉；正文在内容盒内侧不受影响，被裁的留白区显示
    // html/body 背景（同色）= 页边距照常空白。四边都裁：竖排消上下露、横排消左右露。padding 四边
    // 与 body 的 padding-top/right/bottom/left 逐项一致（上=mt vh+chromeTop，下=mb vh+F+chromeBottom，
    // 左右=ml/mr vw），裁边恰在列边缘、不切正文。
    final String contentClipCss =
        'inset(calc(${mt}vh + var(--chrome-top-inset, 0px)) ${mr}vw '
        'calc(${mb}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px)) ${ml}vw)';
    // TODO-729：column-gap 固定为常量（= 安卓 calc(0vh + 22px)）。它只是相邻列之间
    // 的恒定空隙，**不再**承载 margin / fontSize / chrome inset —— 那些 inset 全部由
    // padding 承载（横排在 padding 左右 + perpendicular 的 padding-top/bottom；竖排在
    // padding-top/bottom 的 turn 轴）。固定 gap 让 JS pageStep(=content-box + gap)
    // 恒等于浏览器真实列周期 column-width + column-gap，maxScroll 与对齐量同源，杜绝
    // 「翻一半跳章」（旧实现把 inset 塞进 gap，使列周期随 inset/字号/竖排 notch 漂移，
    // pageStep 与真实列周期失配 → 倒数第二页越界被 clamp 误判 limit 提前跨章）。
    const String columnGapCss = '${ReaderLayoutDefaults.columnGapPx}px';

    // TODO-729 必补(a)：column-width 必须等于 content-box（扣掉 turn 轴方向的 padding），
    // 而非无条件整视口。只有 column-width == content-box 时，浏览器真实列周期
    // (column-width + column-gap) 才恒等于 JS pageStep(content-box + gap)，maxScroll
    // 与对齐量同源。两轴的 content-box 与下方 padding 表达式严格镜像：
    //  - 横排：宽 = page-width − 左右 padding(${ml}vw + ${mr}vw)。perpendicular 的
    //    padding-top/bottom(含 chrome inset)不影响横向列宽。
    //  - 竖排：高 = reader-viewport-height(=纯 V) − 上下 padding(${mt}vh + ${mb}vh +
    //    fontSize + chrome top/bottom inset)，与 padding-top/padding-bottom 逐项对应。
    //    TODO-734：基准必须是纯视口高 V（--reader-viewport-height），不是含
    //    +bottomOverlap 的 --page-height（那是图片虚高用），否则列底边比视口底高
    //    (O−F)，字号 F<22 漏字进底栏。与 JS getScrollContext 的 viewportHeight 成对。
    final String columnWidthCss = isVertical
        ? ReaderContentStyles.verticalColumnWidthCss(
            marginTopVh: mt,
            marginBottomVh: mb,
            fontSizePx: settings.fontSize.round(),
          )
        : 'calc(var(--page-width, 100vw) - ${ml}vw - ${mr}vw)';

    final String textSpacingCss =
        'line-height: ${settings.lineHeight} !important;';

    final String gridCss = settings.enableTextJustification
        ? ''
        : '''
text-align: start !important;
hanging-punctuation: allow-end !important;
line-break: strict !important;''';

    const String pageBreakCss = '''
p {
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
}''';

    // TODO-861①（移植 Hoshi `ebf5423`）：段落间距。>0 时给 `<p>` 注入主轴方向的
    // margin —— 横排走 top/bottom、竖排走 left/right（与 iOS 的 verticalWriting
    // 分支同构，竖排 inline 轴是水平方向）。=0 时不注入（边界，零行为变化）。这是
    // 顶层规则、对 paginated/continuous 两布局都生效（插在主 return 的 `<body>`
    // 规则之后，其 `!important` 压过 UA 默认段距）。
    final double paragraphSpacing = math.max(0, settings.paragraphSpacing);
    final String paragraphSpacingCss = paragraphSpacing > 0
        ? (isVertical
            ? '''
p {
  margin-right: ${paragraphSpacing}em !important;
  margin-left: ${paragraphSpacing}em !important;
}'''
            : '''
p {
  margin-top: ${paragraphSpacing}em !important;
  margin-bottom: ${paragraphSpacing}em !important;
}''')
        : '';

    // TODO-861④（移植 Hoshi `f286108`）：图片防剧透模糊。开启时大图盖 24px 高斯
    // 模糊；JS（reader_pagination_scripts）给这些图加 `blurred` 类，点击揭开。
    // `clip-path: inset(0)` 复刻 Hoshi `55a32cd` 修复（竖排 0 横向 padding 时
    // blur 图被裁切/隐藏）。=false 时不注入（边界，零行为变化）。
    final String blurImagesCss = settings.blurImages
        ? '''
img.block-img.blurred,
svg.block-img.blurred {
  filter: blur(24px) !important;
  clip-path: inset(0) !important;
}'''
        : '';

    final String furiganaCss = _furiganaCss(settings.furiganaMode);

    final String textIndentCss = settings.textIndentation > 0
        ? 'text-indent: ${settings.textIndentation}em !important;'
        : '';

    final String vertKerningCss =
        settings.enableVerticalFontKerning && isVertical
            ? 'font-kerning: normal !important;'
            : '';

    final String vpalCss = settings.enableFontVPAL && isVertical
        ? "font-feature-settings: 'vpal' 1 !important;"
        : '';

    final String textOrientCss = isVertical
        ? 'text-orientation: ${settings.verticalTextOrientation};'
        : '';

    final String columnsCss = settings.pageColumns > 0
        ? 'column-count: ${settings.pageColumns} !important;'
        : '';

    const String imageMaxWidth = ReaderLayoutDefaults.imageMaxWidthFallbackCss;
    const String imageMaxHeight =
        ReaderLayoutDefaults.imageMaxHeightFallbackCss;

    // TODO-909: three-state layout. VN gets its own stage layout (NOT the
    // paginated column geometry — a VN screen is one detached Block rendered on
    // `hoshi-vn-stage`, so reusing column-width/gap geometry would fight the
    // stage). Falling through to the paginated `else` would silently give VN the
    // column model, so VN must be selected explicitly here.
    final String layoutCss = settings.isVnMode
        ? _vnLayoutCss(
            settings: settings,
            isVertical: isVertical,
            colors: colors,
            resolvedFontFamily: resolvedFontFamily,
            textSpacingCss: textSpacingCss,
            paddingCss: paddingCss,
            gridCss: gridCss,
            textIndentCss: textIndentCss,
            vertKerningCss: vertKerningCss,
            vpalCss: vpalCss,
            textOrientCss: textOrientCss,
            clampedMarginTop: mt,
            clampedMarginBottom: mb,
          )
        : settings.isContinuousMode
            ? _continuousLayoutCss(
                settings: settings,
                isVertical: isVertical,
                colors: colors,
                resolvedFontFamily: resolvedFontFamily,
                textSpacingCss: textSpacingCss,
                paddingCss: paddingCss,
                gridCss: gridCss,
                textIndentCss: textIndentCss,
                vertKerningCss: vertKerningCss,
                vpalCss: vpalCss,
                textOrientCss: textOrientCss,
                clampedMarginTop: mt,
                clampedMarginBottom: mb,
              )
            : _paginatedLayoutCss(
                settings: settings,
                isVertical: isVertical,
                colors: colors,
                resolvedFontFamily: resolvedFontFamily,
                textSpacingCss: textSpacingCss,
                paddingCss: paddingCss,
                columnGapCss: columnGapCss,
                columnWidthCss: columnWidthCss,
                gridCss: gridCss,
                textIndentCss: textIndentCss,
                vertKerningCss: vertKerningCss,
                vpalCss: vpalCss,
                textOrientCss: textOrientCss,
                columnsCss: columnsCss,
                clampedMarginTop: mt,
                clampedMarginBottom: mb,
                contentClipCss: contentClipCss,
              );

    final String readerStylePriority =
        settings.prioritizeReaderStyles ? '' : ' !important';

    return '''
$resolvedFontFaces
$pageBreakCss
@media (prefers-color-scheme: light) { :root { --hoshi-system-text-color: #000; } }
@media (prefers-color-scheme: dark) { :root { --hoshi-system-text-color: #fff; } }
:root {
  --hoshi-sasayaki-text-color: ${colors.textColor};
  --hoshi-sasayaki-background-color: ${sasayakiColor ?? colors.sasayakiColor};
}
html {
  /* block-container property: constrain line-box height so ruby/furigana won't expand it */
  -webkit-line-box-contain: block glyphs replaced;
  /* Themed scrollbar: the track stays transparent so it shows the page
     background, and the thumb takes the theme text colour (already alpha<1),
     so dark themes get a light thumb and light themes a dark one. The standard
     props cover Firefox/Chromium 121+; the -webkit pseudo-elements below cover
     Android WebView / Windows WebView2 / macOS WKWebView. */
  scrollbar-width: thin;
  scrollbar-color: ${colors.textColor} transparent;
  /* Pin the UA colour scheme to the reader theme (not the OS). WebView2 uses
     Fluent overlay scrollbars that ignore ::-webkit-scrollbar and follow the
     system light/dark setting; declaring color-scheme makes that native
     scrollbar flip to match the book's background instead of staying dark on a
     light page (or vice versa). */
  color-scheme: ${colors.colorScheme};
}
::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
::-webkit-scrollbar-track {
  background: transparent;
}
::-webkit-scrollbar-thumb {
  /* padding-box clip + transparent border insets the coloured area, giving a
     slim, soft thumb instead of a heavy full-width bar. */
  background-color: ${colors.textColor};
  background-clip: padding-box;
  border: 2px solid transparent;
  border-radius: 8px;
}
::-webkit-scrollbar-corner {
  background: transparent;
}
$layoutCss
$paragraphSpacingCss
img.block-img {
  max-width: var(--hoshi-image-max-width, $imageMaxWidth)$readerStylePriority;
  max-height: var(--hoshi-image-max-height, $imageMaxHeight)$readerStylePriority;
  width: auto$readerStylePriority;
  height: auto$readerStylePriority;
  display: block$readerStylePriority;
  margin: auto$readerStylePriority;
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
  object-fit: contain$readerStylePriority;
  cursor: pointer;
}
.block-img-wrapper {
  display: flex !important;
  justify-content: center !important;
  align-items: center !important;
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
}
img:not(.block-img) {
  max-width: 100%$readerStylePriority;
  max-height: var(--hoshi-image-max-height, $imageMaxHeight)$readerStylePriority;
  object-fit: contain$readerStylePriority;
}
p > img:only-child, div > img:only-child, section > img:only-child, figure > img:only-child {
  display: block;
  margin-left: auto;
  margin-right: auto;
}
svg {
  max-width: var(--hoshi-image-max-width, $imageMaxWidth)$readerStylePriority;
  max-height: var(--hoshi-image-max-height, $imageMaxHeight)$readerStylePriority;
  width: 100%$readerStylePriority;
  height: 100%$readerStylePriority;
  display: block$readerStylePriority;
  margin: auto$readerStylePriority;
  break-inside: avoid !important;
  -webkit-column-break-inside: avoid !important;
}
svg.block-img {
  /* Fixed-layout <svg><image> cover/illustration promoted to a block image by
     _sharedInitImages: give it a definite page-sized box so its inner <image>
     meet-fits + centres (the generic svg width/height:100% above can't resolve
     against an indefinite reflow column, leaving the cover stuck at the edge).
     The .block-img-wrapper then centres the box; cursor matches img.block-img. */
  width: var(--hoshi-image-max-width, $imageMaxWidth)$readerStylePriority;
  height: var(--hoshi-image-max-height, $imageMaxHeight)$readerStylePriority;
  margin: auto$readerStylePriority;
  cursor: pointer;
}
$blurImagesCss
$furiganaCss
ruby > rt, ruby > rp {
  -webkit-user-select: none;
  user-select: none;
}
/* BUG-125：查词高亮用不透明色（见 selectionOpaque 注释）。JS 侧给该 Highlight 设
   priority=1，使其叠在音频(sasayaki, 默认 priority=0)之上 → 重叠处只显示这一层。 */
::highlight(hoshi-selection) {
  background-color: $selectionOpaque;
  color: inherit;
}
/* BUG-110：<ruby> 内的字不走 ::highlight（竖排下会双绘成深色带），改给 ruby 元素
   加 class，背景画在元素上只画一遍。移植自 Hoshi-Reader-Android。 */
ruby.hoshi-selection-ruby-active {
  background-color: $selectionOpaque !important;
  color: inherit;
}
/* 收藏句高亮同时服务 CSS Highlight、旧 WebView span fallback、以及 ruby 分流 class；
   三条路径共用背景 + underline，和 sasayaki/current sentence 重叠时仍保留收藏语义。 */
::highlight(hoshi-hl-yellow),
.hoshi-hl-yellow,
ruby.hoshi-hl-yellow-ruby-active {
  background-color: var(--hoshi-hl-yellow, rgba(255,220,0,0.35));
  text-decoration-line: underline;
  text-decoration-color: var(--hoshi-hl-yellow-mark, rgb(184, 132, 0));
  text-decoration-thickness: 0.12em;
  text-underline-offset: 0.18em;
}
::highlight(hoshi-hl-green),
.hoshi-hl-green,
ruby.hoshi-hl-green-ruby-active {
  background-color: var(--hoshi-hl-green, rgba(0,200,83,0.30));
  text-decoration-line: underline;
  text-decoration-color: var(--hoshi-hl-green-mark, rgb(0, 126, 54));
  text-decoration-thickness: 0.12em;
  text-underline-offset: 0.18em;
}
::highlight(hoshi-hl-blue),
.hoshi-hl-blue,
ruby.hoshi-hl-blue-ruby-active {
  background-color: var(--hoshi-hl-blue, rgba(68,138,255,0.30));
  text-decoration-line: underline;
  text-decoration-color: var(--hoshi-hl-blue-mark, rgb(36, 92, 190));
  text-decoration-thickness: 0.12em;
  text-underline-offset: 0.18em;
}
::highlight(hoshi-hl-pink),
.hoshi-hl-pink,
ruby.hoshi-hl-pink-ruby-active {
  background-color: var(--hoshi-hl-pink, rgba(255,64,129,0.30));
  text-decoration-line: underline;
  text-decoration-color: var(--hoshi-hl-pink-mark, rgb(196, 38, 92));
  text-decoration-thickness: 0.12em;
  text-underline-offset: 0.18em;
}
::highlight(hoshi-hl-purple),
.hoshi-hl-purple,
ruby.hoshi-hl-purple-ruby-active {
  background-color: var(--hoshi-hl-purple, rgba(170,0,255,0.25));
  text-decoration-line: underline;
  text-decoration-color: var(--hoshi-hl-purple-mark, rgb(126, 0, 190));
  text-decoration-thickness: 0.12em;
  text-underline-offset: 0.18em;
}
.hoshi-dict-highlight {
  background-color: $selectionOpaque !important;
  color: inherit;
}
::highlight(hoshi-sasayaki) {
  color: var(--hoshi-sasayaki-text-color);
  background-color: var(--hoshi-sasayaki-background-color);
}
/* BUG-110：sasayaki 跟随高亮里 <ruby> 元素用 class（不走 ::highlight，避免竖排双绘）。 */
ruby.hoshi-sasayaki-ruby-active {
  color: var(--hoshi-sasayaki-text-color) !important;
  background-color: var(--hoshi-sasayaki-background-color) !important;
}
/* BUG-125：同一 <ruby> 同时带查词+音频两个 class 时（元素只渲染一个背景），用双类
   高于单类的特异性让查词不透明色胜出 → 重叠的振假名字也只显示查词层（查词优先）。 */
ruby.hoshi-selection-ruby-active.hoshi-sasayaki-ruby-active {
  background-color: $selectionOpaque !important;
  color: inherit !important;
}
::highlight(hoshi-search) {
  background-color: rgba(255, 200, 0, 0.45);
}
.hoshi-sasayaki-cue {
  background-color: transparent;
}
.hoshi-sasayaki-cue.hoshi-sasayaki-active {
  color: var(--hoshi-sasayaki-text-color) !important;
  background-color: var(--hoshi-sasayaki-background-color) !important;
}
a {
  color: ${linkColor ?? colors.linkColor}$readerStylePriority;
}
''';
  }

  static String _paginatedLayoutCss({
    required ReaderSettings settings,
    required bool isVertical,
    required _ThemeColors colors,
    required String resolvedFontFamily,
    required String textSpacingCss,
    required String paddingCss,
    required String columnGapCss,
    required String columnWidthCss,
    required String gridCss,
    required String textIndentCss,
    required String vertKerningCss,
    required String vpalCss,
    required String textOrientCss,
    required String columnsCss,
    required double clampedMarginTop,
    required double clampedMarginBottom,
    required String contentClipCss,
  }) {
    return '''
html, body {
  overflow: hidden !important;
  height: var(--page-height, 100vh) !important;
  width: var(--page-width, 100vw) !important;
  margin: 0 !important;
  padding: 0 !important;
  background: ${colors.backgroundColor} !important;
  color: ${colors.textColor} !important;
  writing-mode: ${settings.writingMode} !important;
  /* TODO-114: 分页模式翻页本是瞬时跳页（hoshiReader.assignPagePosition 直接赋值
     scrollTop/scrollLeft）。但触摸拖动会让 WebView 把手势当原生 pan，让页面跟手
     位移再被 snap 回弹 —— 那段跟手 + 回弹就是用户看到的「滑动翻页动画」。禁用
     touch-action 后触摸不再被翻译成原生滚动，翻页只由 onSwipe 检测后瞬时跳页，
     动画消失；touch-action 只影响 pan/zoom 手势，不影响长按文本选择。 */
  touch-action: none !important;
}
body {
  font-family: $resolvedFontFamily !important;
  font-size: ${settings.fontSize}px !important;
  -webkit-text-size-adjust: none !important;
  overflow-wrap: anywhere !important;
  $textSpacingCss
  box-sizing: border-box !important;
  /* TODO-792 根因修复：多列容器(body)高度必须用纯视口高 V(--reader-viewport-height)，不是
     含 +bottomOverlap 的 --page-height(V+O)。html 仍 V+O(滚动/图片虚高用)，但 body 作为
     multicol 容器若是 V+O，其 content-box inline 高 = (V+O)−padding 比 column-width 基准
     (纯 V−padding−F = verticalColumnWidthCss) 大一个 O → 浏览器把单列 used 高从 793 拉伸到
     815、相邻列顶差 = 真实列周期 837 > 名义 pageStep 815 → ① 页间翻页累积漂移 ② 页内 column-fill
     在溢出列上沿 inline(竖直)轴逐列下移 = 整体往下/斜的平行四边形。容器高对齐纯 V 后列不再拉伸、
     used 高回 793、realPitch 回 815 = 名义 pageStep，两症同消(故同时 revert getScrollContext 的
     pageStep+=O)。图片用独立 --hoshi-image-max-height(跟 body content-box 走)不受影响、不切图。 */
  height: var(--reader-viewport-height, 100vh) !important;
  column-width: $columnWidthCss !important;
  column-gap: $columnGapCss !important;
  padding: $paddingCss !important;
  padding-top: calc(${clampedMarginTop}vh + var(--chrome-top-inset, 0px)) !important;
  padding-bottom: calc(${clampedMarginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px)) !important;
  /* TODO-810 + TODO-792：clip-path 以 body 边框盒（border-box·margin/border=0 即固定视口帧）为
     基准裁到**正文内容盒**（四边各 = body 实际 padding），一举两用：① 裁掉 notch/状态栏安全带里
     滚入的上一页文字（原 TODO-810 只裁 chrome inset 那一截）；② 裁掉分页模式因 viewport > 单列
     周期而在留白区露出的相邻页/列（竖排上下、横排左右）。正文在内容盒内侧不受影响；被裁的留白区
     显示 html/body 背景（同色）= 页边距照常空白。不动 body 高度/pageStep/column-width/scrollTop
     几何（防 TODO-753/792 回归）。contentClipCss 与上面 padding-top/right/bottom/left 逐项一致。 */
  clip-path: $contentClipCss !important;
  $gridCss
  $textOrientCss
  $textIndentCss
  $vertKerningCss
  $vpalCss
  $columnsCss
}''';
  }

  /// TODO-909: VN (Visual-Novel) stage layout. The chapter is detached by the
  /// VN JS and one Block/sentence screen is rendered onto `hoshi-vn-stage` >
  /// `hoshi-vn-screen` > `hoshi-vn-content`. The stage fills the viewport; the
  /// screen reserves the reader chrome insets (top/bottom) and centres its
  /// content. No multicol columns — text flows naturally within one screen, so
  /// this does NOT reuse the paginated column geometry.
  static String _vnLayoutCss({
    required ReaderSettings settings,
    required bool isVertical,
    required _ThemeColors colors,
    required String resolvedFontFamily,
    required String textSpacingCss,
    required String paddingCss,
    required String gridCss,
    required String textIndentCss,
    required String vertKerningCss,
    required String vpalCss,
    required String textOrientCss,
    required double clampedMarginTop,
    required double clampedMarginBottom,
  }) {
    // TODO-958：VN 居中需区分主轴。flex 容器 `.hoshi-vn-screen` 的物理主轴恒为水平
    // （flex-direction:row），但「沿主轴居中」的语义在两种写排下不同：竖排
    // vertical-rl 文字列沿水平主轴展开，水平居中即左右居中；横排文字行沿垂直交叉轴
    // 堆叠，主轴是水平的单行宽度。两轴都给 content 上界由 flex 居中即可对齐；此处用
    // isVertical 标注主/交叉轴，便于后续真机微调而不回退到硬编码 width:100%。
    final String vnAxisComment = isVertical
        ? '/* VN axis: vertical-rl — main axis = horizontal (left/right centering) */'
        : '/* VN axis: horizontal-tb — main axis = horizontal single-line width */';
    return '''
html, body {
  margin: 0 !important;
  padding: 0 !important;
  background: ${colors.backgroundColor} !important;
  color: ${colors.textColor} !important;
  writing-mode: ${settings.writingMode} !important;
  width: 100vw !important;
  height: 100vh !important;
  overflow: hidden !important;
}
body {
  font-family: $resolvedFontFamily !important;
  font-size: ${settings.fontSize}px !important;
  -webkit-text-size-adjust: none !important;
  overflow-wrap: anywhere !important;
  box-sizing: border-box !important;
  $textSpacingCss
  $gridCss
  $textOrientCss
  $textIndentCss
  $vertKerningCss
  $vpalCss
}
.hoshi-vn-stage {
  position: fixed !important;
  inset: 0 !important;
  box-sizing: border-box !important;
  /* Reserve the reader chrome (top/bottom bars) + the user's vertical margins
     so the screen never sits under the notch or the bottom chrome. */
  padding-top: calc(${clampedMarginTop}vh + var(--chrome-top-inset, 0px)) !important;
  padding-bottom: calc(${clampedMarginBottom}vh + var(--chrome-bottom-inset, 0px)) !important;
}
.hoshi-vn-screen {
  box-sizing: border-box !important;
  width: 100% !important;
  height: 100% !important;
  padding: $paddingCss !important;
  display: flex !important;
  align-items: center !important;
  justify-content: center !important;
  overflow: hidden !important;
}
.hoshi-vn-content {
  $vnAxisComment
  /* TODO-958：内容沿两轴**有上界但不强制占满**，再交给 `.hoshi-vn-screen` 的
     flex 居中（align-items + justify-content 都是 center）把单句台词放到屏幕正
     中。旧代码硬写 `width: 100%`（物理宽度）：竖排 vertical-rl 下文字列从右边缘
     向左排却占满全宽 → 主轴被填满 → justify-content:center 失效 → 台词贴最右。
     改成 `max-*: 100%` 后内容少时沿主轴收缩由 flex 居中；内容多时撑到交叉轴上界
     后向主轴溢出，仍被 fitScreensToViewport 的 scrollWidth/Height ≤ client 判据
     正确捕获并拆屏（盒尺寸测量语义不变）。 */
  max-width: 100% !important;
  max-height: 100% !important;
}
/* The reveal (M1) hides not-yet-typed text by collapsing the trailing span. */
[data-hoshi-visual-novel-unrevealed] {
  visibility: hidden !important;
}
''';
  }

  static String _continuousLayoutCss({
    required ReaderSettings settings,
    required bool isVertical,
    required _ThemeColors colors,
    required String resolvedFontFamily,
    required String textSpacingCss,
    required String paddingCss,
    required String gridCss,
    required String textIndentCss,
    required String vertKerningCss,
    required String vpalCss,
    required String textOrientCss,
    required double clampedMarginTop,
    required double clampedMarginBottom,
  }) {
    // TODO-788：连续模式无 multicol 翻页周期，padding-bottom 只用 marginBottom + chrome-bottom-inset，
    // 不再像分页模式 (_paginatedLayoutCss :507) 那样塞一份独立的 fontSize px 预留项——分页那份 F
    // 是承载几何项（镜像 verticalColumnWidthCss/JS contentBox 维持 pageStep==realPitch 不变式）必须保留，
    // 连续模式那份 F 与几何无关，去掉后「下边距」真正控制底栏上方空白（末行下方仍由 inset 给底栏预留）。
    final String hiddenOverflowAxis = isVertical ? 'overflow-y' : 'overflow-x';
    // TODO-718（真机铁证·2026-06-25）：连续模式隐藏溢出轴 **只放在 html，不放 body**（横竖排
    // 都如此）。给 body 加 overflow:hidden 会触发 CSS「一轴非 visible 则另一可见轴算成 auto」规则，
    // 使 body 另一轴变 auto → **body 自己成为滚动容器**，scrollingElement/root 与真实滚动器错位：
    //  - 横排：window.scrollBy({top}) 滚的是 body、window.scrollY 成幽灵值（真机 winY=667 而
    //    scrollingElement.scrollTop=0）→ 滚轮 moved 判据(读 root.scrollTop)恒 false 误跳章、进度卡 0.34%。
    //  - 竖排：阅读/滚轮用 window.scrollBy({left}) 能滚，但**恢复** scrollToCharOffset 写 root.scrollLeft
    //    （root=scrollingElement=body）是幽灵 → 恢复后视口不动留在章首（真机 718-drift：存 0.0228、
    //    onLoadStop 0.0228 全对，但 actual 在 t+400 塌成 0.0000）。
    // 只放 html 时 html/window/scrollingElement 三者统一为唯一滚动器，阅读与恢复用同一个元素，
    // window.scrollBy / root.scroll* / window.scroll* 全部一致生效。
    final String overflowRule =
        'html {\n  $hiddenOverflowAxis: hidden !important;\n}';
    final String viewportConstraintCss = isVertical
        ? 'height: var(--hoshi-continuous-height, 100vh) !important;'
        : '''
width: 100vw !important;
  min-height: 100vh !important;''';

    return '''
$overflowRule
html, body {
  margin: 0 !important;
  padding: 0 !important;
  background: ${colors.backgroundColor} !important;
  color: ${colors.textColor} !important;
  writing-mode: ${settings.writingMode} !important;
}
body {
  font-family: $resolvedFontFamily !important;
  font-size: ${settings.fontSize}px !important;
  -webkit-text-size-adjust: none !important;
  overflow-wrap: anywhere !important;
  $textSpacingCss
  box-sizing: border-box !important;
  $viewportConstraintCss
  padding: $paddingCss !important;
  padding-top: calc(${clampedMarginTop}vh + var(--chrome-top-inset, 0px)) !important;
  padding-bottom: calc(${clampedMarginBottom}vh + var(--chrome-bottom-inset, 0px)) !important;
  /* TODO-810：连续模式与分页同理：竖排纵向滚动轴与顶部透明 padding 安全带同轴，需在 inset 带硬裁
     防上一屏文字滚入 notch。clip-path 以 body 边框盒（border-box）为基准只裁顶/底 padding 透明带，
     正文不受影响；不动高度/scrollTop 几何。 */
  clip-path: inset(var(--chrome-top-inset, 0px) 0 var(--chrome-bottom-inset, 0px) 0) !important;
  $gridCss
  $textOrientCss
  $textIndentCss
  $vertKerningCss
  $vpalCss
}''';
  }

  static String _furiganaCss(String mode) {
    switch (mode) {
      case 'hide':
        return 'rt { display: none !important; }';
      case 'partial':
        return '''
rt {
  font-size: 0.45em;
  visibility: hidden;
}
ruby.show-rt rt {
  visibility: visible;
}''';
      case 'toggle':
        return '''
rt {
  font-size: 0.45em;
  visibility: hidden;
}
body.show-all-rt rt {
  visibility: visible !important;
}''';
      default:
        return 'rt { font-size: 0.45em; }';
    }
  }

  static _ThemeColors _themeColors(String theme,
      {String? customBg, String? customFg}) {
    switch (theme) {
      case 'ecru-theme':
        return const _ThemeColors(
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#f7f6eb',
          selectionColor: 'rgba(194, 178, 128, 0.35)',
          sasayakiColor: 'rgba(168, 198, 140, 0.40)',
          linkColor: '#7a6232',
        );
      case 'water-theme':
        return const _ThemeColors(
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#dfecf4',
          selectionColor: 'rgba(200, 170, 110, 0.35)',
          sasayakiColor: 'rgba(100, 180, 220, 0.40)',
          linkColor: '#3a5fad',
        );
      case 'gray-theme':
        return const _ThemeColors(
          textColor: 'rgba(255, 255, 255, 0.87)',
          backgroundColor: '#23272a',
          selectionColor: 'rgba(190, 155, 100, 0.35)',
          sasayakiColor: 'rgba(80, 150, 200, 0.35)',
          linkColor: '#6fa8dc',
          colorScheme: 'dark',
        );
      case 'dark-theme':
        return const _ThemeColors(
          textColor: 'rgba(255, 255, 255, 0.6)',
          backgroundColor: '#121212',
          selectionColor: 'rgba(180, 145, 90, 0.35)',
          sasayakiColor: 'rgba(70, 130, 180, 0.35)',
          linkColor: '#7aacdf',
          colorScheme: 'dark',
        );
      case 'black-theme':
        return const _ThemeColors(
          textColor: 'rgba(255, 255, 255, 0.87)',
          backgroundColor: '#000',
          selectionColor: 'rgba(170, 135, 80, 0.40)',
          sasayakiColor: 'rgba(60, 120, 170, 0.40)',
          linkColor: '#5b9bd5',
          colorScheme: 'dark',
        );
      case 'custom-theme':
        return _ThemeColors(
          textColor: customFg ?? 'rgba(0, 0, 0, 0.87)',
          backgroundColor: customBg ?? '#fff',
          colorScheme: _isDarkBackground(customBg) ? 'dark' : 'light',
        );
      default:
        // system-theme（默认主题）/ light-theme / 未来未命中 preset 的 key（TODO-165
        // / BUG-224）：调用方按当前主题的真实 ColorScheme 派生出 customBg/customFg
        // 传进来时，正文 <body> 背景/字色必须吃这套色，而不是硬编码白底 #fff
        // （否则默认主题下「书籍正文背景没吃背景色」）。没传则回退到旧的浅色默认，
        // 保持 ReaderContentStyles.css(settings) 无主题信息时的向后兼容行为。
        if (customBg == null && customFg == null) {
          return const _ThemeColors();
        }
        return _ThemeColors(
          textColor: customFg ?? 'rgba(0, 0, 0, 0.87)',
          backgroundColor: customBg ?? '#fff',
          colorScheme: _isDarkBackground(customBg) ? 'dark' : 'light',
        );
    }
  }

  /// 把半透明前景色 [fg] 按其 alpha 合成到不透明背景色 [bg] 上，返回等效的不透明
  /// `rgb(r, g, b)`。查词高亮用它：无重叠区与原半透明色叠在同一背景上像素一致，
  /// 重叠区则覆盖其下的音频高亮 → 单层、查词优先（BUG-125）。
  ///
  /// [fg] 已不透明、或任一颜色无法解析时原样返回 [fg]（回退到旧的半透明行为）。
  /// 解析支持 `#rgb`/`#rgba`/`#rrggbb`/`#rrggbbaa` 与 `rgb()`/`rgba()`；命名色不解析。
  static String composeOpaqueColor(String fg, String bg) {
    final _Rgba? f = _parseColor(fg);
    final _Rgba? b = _parseColor(bg);
    if (f == null || b == null || f.a >= 1.0) return fg;
    int blend(int fc, int bc) =>
        (f.a * fc + (1 - f.a) * bc).round().clamp(0, 255);
    return 'rgb(${blend(f.r, b.r)}, ${blend(f.g, b.g)}, ${blend(f.b, b.b)})';
  }

  /// 解析 `#hex` 或 `rgb()/rgba()` 到 [_Rgba]；解析不了返回 null。
  static _Rgba? _parseColor(String input) {
    final String s = input.trim().toLowerCase();
    if (s.startsWith('#')) {
      final String h = s.substring(1);
      int? hx(int start, int len) => int.tryParse(
            len == 1 ? '${h[start]}${h[start]}' : h.substring(start, start + 2),
            radix: 16,
          );
      if (h.length == 3 || h.length == 4) {
        final int? r = hx(0, 1), g = hx(1, 1), b = hx(2, 1);
        if (r == null || g == null || b == null) return null;
        final double a = h.length == 4 ? (hx(3, 1)! / 255.0) : 1.0;
        return _Rgba(r, g, b, a);
      }
      if (h.length == 6 || h.length == 8) {
        final int? r = hx(0, 2), g = hx(2, 2), b = hx(4, 2);
        if (r == null || g == null || b == null) return null;
        final double a = h.length == 8 ? (hx(6, 2)! / 255.0) : 1.0;
        return _Rgba(r, g, b, a);
      }
      return null;
    }
    final RegExpMatch? m = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(s);
    if (m == null) return null;
    final List<String> parts =
        m.group(1)!.split(',').map((String e) => e.trim()).toList();
    if (parts.length < 3) return null;
    final int? r = int.tryParse(parts[0]);
    final int? g = int.tryParse(parts[1]);
    final int? b = int.tryParse(parts[2]);
    if (r == null || g == null || b == null) return null;
    final double a =
        parts.length >= 4 ? (double.tryParse(parts[3]) ?? 1.0) : 1.0;
    return _Rgba(r, g, b, a);
  }

  /// Best-effort luminance check for a custom background so the native scrollbar
  /// picks the matching light/dark bucket. Only `#rgb` / `#rrggbb` are parsed;
  /// anything else (named colours, rgba()) falls back to 'light'.
  static bool _isDarkBackground(String? background) {
    if (background == null) return false;
    final String hex = background.trim();
    if (!hex.startsWith('#')) return false;
    final String body = hex.substring(1);
    int? r;
    int? g;
    int? b;
    if (body.length == 3) {
      r = int.tryParse('${body[0]}${body[0]}', radix: 16);
      g = int.tryParse('${body[1]}${body[1]}', radix: 16);
      b = int.tryParse('${body[2]}${body[2]}', radix: 16);
    } else if (body.length == 6) {
      r = int.tryParse(body.substring(0, 2), radix: 16);
      g = int.tryParse(body.substring(2, 4), radix: 16);
      b = int.tryParse(body.substring(4, 6), radix: 16);
    }
    if (r == null || g == null || b == null) return false;
    // Rec. 601 relative luminance; < 0.5 of full range reads as dark.
    final double luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
    return luminance < 0.5;
  }
}

/// 解析后的 RGBA 颜色分量（[r]/[g]/[b] 为 0-255 整数，[a] 为 0-1 浮点）。
class _Rgba {
  const _Rgba(this.r, this.g, this.b, this.a);
  final int r;
  final int g;
  final int b;
  final double a;
}

class _ThemeColors {
  const _ThemeColors({
    this.textColor = 'rgba(0, 0, 0, 0.87)',
    this.backgroundColor = '#fff',
    this.selectionColor = 'rgba(160, 160, 160, 0.40)',
    this.sasayakiColor = 'rgba(135, 206, 235, 0.40)',
    this.linkColor = '#426cf5',
    this.colorScheme = 'light',
  });

  final String textColor;
  final String backgroundColor;
  final String selectionColor;
  final String sasayakiColor;
  final String linkColor;

  /// UA color-scheme bucket ('light' | 'dark') the native (Fluent overlay)
  /// scrollbar follows. Derived from the background, not the OS.
  final String colorScheme;
}
