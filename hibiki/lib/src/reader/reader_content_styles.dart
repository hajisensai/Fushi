import 'dart:math' as math;

import 'package:fushi/src/reader/reader_settings.dart';

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

/// 本 wave 清理：`_paginatedLayoutCss` / `_vnLayoutCss` / `_continuousLayoutCss` 三个布局
/// CSS 生成器共享的公共参数契约（主题色 / 字体 / 行距 / 边距 + 各子 CSS 片段）。原来三处
/// 生成器签名 + `css()` 里三处调用点各重复一份逐字相同的参数管道样板；抽成单一 record 作
/// 唯一真相源——增删公共参数只改此 record 与用到它的生成器，不再三处手改。纯机械搬运：各
/// 生成器 `return '''...'''` 的 CSS 原始串一字未改，解构出的局部变量名 / 值与旧命名参数完全
/// 一致 → `css()` 输出逐字节不变。
typedef _LayoutCssArgs = ({
  ReaderSettings settings,
  bool isVertical,
  _ThemeColors colors,
  String resolvedFontFamily,
  String textSpacingCss,
  String paddingCss,
  String gridCss,
  String textIndentCss,
  String vertKerningCss,
  String vpalCss,
  String textOrientCss,
  double clampedMarginTop,
  double clampedMarginBottom,
});

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
  // fushiReader.viewportHeight = V（见 reader_pagination_scripts.dart 的
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

  /// TODO-1285：每页多列（pageColumns）的单个子列宽度。给定单列时的 content-box 基准
  /// 表达式 [baseContentBoxCss]（横排=宽、竖排=高，均为 CSS calc/max 串），当
  /// [pageColumns] ≥ 2 时返回 `(content-box − (N−1)·gap)/N`，浏览器据此在 content-box
  /// 里正好排下 N 列（floor((content-box+gap)/(subW+gap)) == N，代数恒等）。[pageColumns]
  /// ≤ 1（含 0=自动/单列）时原样返回 [baseContentBoxCss]，与旧单列几何字节等价。
  ///
  /// 与 JS getScrollContext 的 `pageStep = columnCount·(used column-width + gap)` 成对：
  /// 每列真实周期 subW+gap，一页 N 列 → 页步 = N·(subW+gap) == content-box+gap，翻页网格
  /// 仍落在真实列边界，不引入 TODO-753/792 亚像素漂移。[columnGapPx] 必须与 body 的
  /// `column-gap` 常量（[ReaderLayoutDefaults.columnGapPx]）一致。
  static String columnWidthForColumns({
    required String baseContentBoxCss,
    required int pageColumns,
    required int columnGapPx,
  }) {
    if (pageColumns <= 1) return baseContentBoxCss;
    final int totalGapPx = (pageColumns - 1) * columnGapPx;
    // max(1px, ...) 兜底：坍塌视口 + 大 N 时裸 calc 可能 ≤0（非法列宽），钳到 1px；
    // 正常视口远大于地板，max 取 calc，零行为变化。
    return 'max(1px, calc(($baseContentBoxCss - ${totalGapPx}px) / $pageColumns))';
  }

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
    String? sentenceAudioHighlightColor,
    String? linkColor,
    String? themeOverride,
    bool einkMode = false,
    bool einkDark = false,
  }) {
    return '<style>\n${css(
      settings: settings,
      fontFaces: fontFaces,
      fontFamily: fontFamily,
      customBg: customBg,
      customFg: customFg,
      selectionColor: selectionColor,
      sentenceAudioHighlightColor: sentenceAudioHighlightColor,
      linkColor: linkColor,
      themeOverride: themeOverride,
      einkMode: einkMode,
      einkDark: einkDark,
    )}\n</style>';
  }

  static String css({
    required ReaderSettings settings,
    String? fontFaces,
    String? fontFamily,
    String? customBg,
    String? customFg,
    String? selectionColor,
    String? sentenceAudioHighlightColor,
    String? linkColor,
    String? themeOverride,
    // 墨水屏模式：强制纯黑白正文 + 线式高亮 + 关过渡（叠加在任意主题之上，见
    // 文件末尾 _einkOverrideCss）。einkDark 决定黑底白字还是白底黑字，取自 app
    // 明暗模式（与全局 E-ink 主题一致），不读阅读器自己的 theme key。
    bool einkMode = false,
    bool einkDark = false,
  }) {
    final _ThemeColors themedColors = _themeColors(
        themeOverride ?? settings.theme,
        customBg: customBg,
        customFg: customFg);
    // E-ink 覆盖发生在配色解析之后：正文/滚动条/UA color-scheme 全部吃纯黑白，
    // 高亮的「线式化」由末尾的 _einkOverrideCss 用级联覆盖（同选择器后出现者胜）。
    final _ThemeColors colors = einkMode
        ? _ThemeColors(
            textColor: einkDark ? '#fff' : '#000',
            backgroundColor: einkDark ? '#000' : '#fff',
            selectionColor: einkDark ? '#fff' : '#000',
            sentenceAudioHighlightColor: 'transparent',
            linkColor: einkDark ? '#fff' : '#000',
            colorScheme: einkDark ? 'dark' : 'light',
          )
        : themedColors;

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
    // content-box 单列基准（turn 轴扣 padding，横排=宽、竖排=高）。单列时 column-width
    // 直接用它；每页多列时下面 columnWidthForColumns 把它按 N 均分成子列宽。
    final String baseColumnWidthCss = isVertical
        ? ReaderContentStyles.verticalColumnWidthCss(
            marginTopVh: mt,
            marginBottomVh: mb,
            fontSizePx: settings.fontSize.round(),
          )
        : 'calc(var(--page-width, 100vw) - ${ml}vw - ${mr}vw)';
    // TODO-1285：每页列数（pageColumns）根因修复。旧实现只发 `column-count:N` 却把
    // column-width 钉死在整页 content-box —— CSS multicol 规范下并存时实际列数 =
    // min(N, floor((content-box+gap)/(column-width+gap))) = min(N,1) = 1，N 被整页列宽
    // 压成 1 列，「每页列数」永不生效。正解：column-width 必须 = 单个子列宽 =
    // (content-box − (N−1)·gap)/N，浏览器才在 content-box 里正好排下 N 列。与 JS
    // getScrollContext 的 pageStep = columnCount·(used column-width + gap) 成对（见
    // reader_pagination_scripts.dart）。pageColumns≤1 时返回原整页 content-box，
    // 与旧行为字节等价（零回归，保 TODO-729/753/792 单列几何不变式）。
    final String columnWidthCss = ReaderContentStyles.columnWidthForColumns(
      baseContentBoxCss: baseColumnWidthCss,
      pageColumns: settings.pageColumns,
      columnGapPx: ReaderLayoutDefaults.columnGapPx,
    );

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
    // 三布局生成器共享的公共参数（单一真相源，见 _LayoutCssArgs）。一次构建，按 view-mode 分发。
    final _LayoutCssArgs layoutArgs = (
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
    );
    final String layoutCss = settings.isVnMode
        ? _vnLayoutCss(layoutArgs)
        : settings.isContinuousMode
            ? _continuousLayoutCss(layoutArgs)
            : _paginatedLayoutCss(
                layoutArgs,
                columnGapCss: columnGapCss,
                columnWidthCss: columnWidthCss,
                columnsCss: columnsCss,
                clampedMarginLeft: ml,
                clampedMarginRight: mr,
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
  --hoshi-sentence-audio-text-color: ${colors.textColor};
  --hoshi-sentence-audio-background-color: ${sentenceAudioHighlightColor ?? colors.sentenceAudioHighlightColor};
}
html {
  /* TODO-1308 (BUG): the legacy WebKit property
     `-webkit-line-box-contain: block glyphs replaced` (cargo-ported from Hoshi
     in ec4abf78a) has been REMOVED here. It told the engine to size line boxes
     to glyphs only, i.e. to NOT reserve the extra leading a <ruby>'s <rt>
     annotation needs. Current Blink dropped support for the property entirely
     (CSS.supports('-webkit-line-box-contain', ...) === false on WebView2 /
     recent Android WebView), so it was already a dead no-op for most users. But
     on older Android System WebView that still honours it, the stripped reserve
     means the furigana has nowhere to sit: in vertical-rl the annotation lives
     on the column's cross axis (to the right of the base column), so with the
     reserve gone the <rt> collapses INTO the base-character column — "假名跑到
     文字中间". The overlap re-materialises after a TOC/bookmark/search jump
     because `_applyChapterHighlights` (navigation.part.dart) forces a style
     recalc / incremental relayout on the freshly-scrolled content, re-applying
     the glyph-only line-box constraint. Removing the declaration restores the
     default line-box behaviour (which reserves ruby space) on every engine —
     exactly what current Blink already does correctly (zero regression there),
     and the BUG-108 lesson that Blink WebViews do not add ruby leading unless
     the line box is allowed to grow. */
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
/* TODO-1308 (BUG-611 follow-up): the reader FORCES the writing mode, so it must
   also own the <ruby> formatting context. Real vertical EPUBs (e.g. light novels)
   ship legacy furigana CSS such as `rt { display: inline-block }` /
   `ruby { display: inline-block }` — patterns that rendered under old WebKit's
   ruby model but, under Blink's modern ruby (WebView2 / recent Android WebView),
   drop the <rt> out of its annotation box. In vertical-rl the furigana then
   collapses ~one base glyph DOWN the column: 貫(かん)禄(ろく) renders with かん
   between 貫/禄 and ろく floating to the base's right at the wrong height
   (measured dyRatio≈0.95 vs 0 correct). The reader style tag is injected LAST in
   <head> (webview.part.dart `_buildSanitizedChapterHtmlBytes`), so these
   !important rules win the cascade over the book stylesheet and re-assert the
   correct ruby structure (rt display is owned by _furiganaCss so `hide` mode's
   display:none still wins there). This is engine-agnostic and a no-op for books
   that don't override the ruby display (these ARE the UA defaults).

   BUG-666 (TODO-1308 follow-up): owning writing-mode + display is not enough —
   the reader must ALSO own `ruby-position`. Legacy vertical EPUBs ship
   `ruby { ruby-position: under }` (or the WebKit alias `-webkit-ruby-position:
   after`), which in vertical-rl throws the furigana to the LEFT of the base
   column instead of the correct Japanese side (the right). Blink resolves the
   `-webkit-` alias onto the same `ruby-position` longhand, so this later
   !important declaration wins the cascade over either spelling. `over` maps to
   line-over in horizontal-tb (furigana ABOVE the base) and to the right in
   vertical-rl (furigana RIGHT of the base) — the correct side for Japanese in
   both writing modes. This also keeps the audiobook/selection highlight on the
   base characters: the full-fill background (BUG-716) paints the <ruby> element
   box, and `over` keeps the furigana in its own annotation lane on the correct
   side (the right in vertical-rl) so it stays outside the highlighted base box;
   the book's `under` would throw furigana to the left and back under the base.
   display unchanged, so the 65fd8d03d non-collapse (dyRatio≈0) is preserved.

   TODO-1308 (user re-report): owning ruby/rt display is STILL not enough for
   <rb>/<rtc> markup (W3C ruby extensions / JIS mono-ruby, e.g.
   <ruby><rb>貫</rb><rtc><rt>かん</rt></rtc><rb>禄</rb><rtc><rt>ろく</rt></rtc></ruby>).
   Blink has NO rb/rtc support (CSS.supports('display','ruby-base') and
   ('display','ruby-text-container') are both false on WebView2; the elements
   default to inline), so an <rt> forced to display:ruby-text INSIDE an inline
   <rtc> is wrapped in an ANONYMOUS ruby at its flow position: the annotation
   becomes its own inline character slot in the BASE column (measured on the
   real WebView2 by reader_vertical_ruby_forms_itest.dart: かん occupies a full
   cell between 貫 and 禄, pushing 禄 one cell down; ろく lands below the
   word) — exactly the user screenshot. Fix: the reader owns the layout role of
   EVERY ruby descendant — rb → inline (base content), rtc → ruby-text (ONE
   annotation level; the mode-dependent rtc display is owned by _furiganaCss
   next to rt), rtc > rt → inline (a plain run INSIDE the rtc annotation, so
   it pairs with the preceding base instead of spawning an anonymous ruby
   slot). Interleaved per-base <rtc> regains correct mono pairing; a single
   trailing <rtc> degrades to standard group-ruby rendering (annotation spans
   the word). Both keep every annotation in the lane. */
ruby {
  display: ruby !important;
  ruby-position: over !important;
}
ruby rp {
  display: none !important;
}
ruby rb {
  display: inline !important;
}
ruby rt, ruby rp {
  -webkit-user-select: none;
  user-select: none;
}
/* TODO-1279：书籍里长按拖选正文时，WebView 引擎会把长按拖选翻译成**原生文本选区**
   （蓝色 ::selection），与我们自绘的查词选区高亮（::highlight(hoshi-selection) /
   .hoshi-dict-highlight）叠成「双选区并存」。查词命中不依赖原生选区——它走
   getCharacterAtPoint → caretPositionFromPoint + Range + CSS Highlights API，与
   user-select 无关（user-select 只管用户能否拖选、不影响程序化 Range/caret 与
   ::highlight 绘制）。原生选区在触屏上唯一「消费者」并不存在：Ctrl+C 复制
   （caret.part.dart 的 readerShouldHandleDesktopCopy）与右键「查词/复制/导出」菜单
   （chrome.part.dart 的 _showReaderTextContextMenu）都 isWindowsPlatform / 桌面门控，
   触屏没有任何路径读原生选区。故按指针类型消除这条特殊情况：粗指针（触屏，pointer:
   coarse——手机/平板 WebView 报告的主指针）禁用原生 user-select + iOS 长按 callout，
   长按拖选只留我们的查词高亮；细指针（鼠标，pointer: fine——桌面 WebView2 / WKWebView /
   Linux）不受影响，桌面 Ctrl+C 复制与右键导出所依赖的 window.getSelection() 原生选区
   照旧。这是 CSS 层的根因修复，不再靠 selectstart 的 <400ms 时窗 preventDefault
   （长按天然 >400ms 会逃逸）去追着压制。 */
@media (pointer: coarse) {
  html, body, body * {
    -webkit-user-select: none !important;
    user-select: none !important;
    -webkit-touch-callout: none !important;
  }
}
/* BUG-765 续：移动端选区起止手柄的强调色跟随主题。reader_selection_scripts.dart 里
   自绘的起/止手柄用 var(--hoshi-sel-handle) 引用本变量；主题切换重注入本 CSS 时手柄
   颜色自动更新，无需 JS 感知主题。用主题 linkColor（各主题的饱和强调色）而非查词高亮
   色（0.35 低透明 tint，太淡不适合实心抓手）。 */
:root { --hoshi-sel-handle: ${linkColor ?? colors.linkColor}; }
/* BUG-125：查词高亮用不透明色（见 selectionOpaque 注释）。JS 侧给该 Highlight 设
   priority=1，使其叠在音频(sentenceAudioHighlight, 默认 priority=0)之上 → 重叠处只显示这一层。 */
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
   三条路径共用背景 + underline，和 sentenceAudioHighlight/current sentence 重叠时仍保留收藏语义。
   BUG-716：ruby 高亮回到整句填充（不再走 1em 窄 lane），下同。 */
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
::highlight(hoshi-sentence-audio) {
  color: var(--hoshi-sentence-audio-text-color);
  background-color: var(--hoshi-sentence-audio-background-color);
}
/* BUG-110：sentenceAudioHighlight 跟随高亮里 <ruby> 元素用 class（不走 ::highlight，避免竖排双绘）。 */
ruby.hoshi-sentence-audio-ruby-active {
  color: var(--hoshi-sentence-audio-text-color) !important;
  background-color: var(--hoshi-sentence-audio-background-color) !important;
}
/* BUG-125：同一 <ruby> 同时带查词+音频两个 class 时（元素只渲染一个背景），用双类
   高于单类的特异性让查词不透明色胜出 → 重叠的振假名字也只显示查词层（查词优先）。 */
ruby.hoshi-selection-ruby-active.hoshi-sentence-audio-ruby-active {
  background-color: $selectionOpaque !important;
  color: inherit !important;
}
::highlight(hoshi-search) {
  background-color: rgba(255, 200, 0, 0.45);
}
.hoshi-sentence-audio-cue {
  background-color: transparent;
}
/* BUG-716：sentenceAudioHighlight 逐句跟随高亮回到整句 background-color 填充。narrow-lane
   (旧 _highlightLaneCss 的 1em 窄条 + background-position:left) 在书籍行距≠字号
   或 <ruby> 盒含注音轨时把条画偏（竖排下往基字左侧偏移、有无振假名两种宽度不一），
   用户实机确认有声书与查词的注音高亮都错位。整句填充按元素 class 只刷一遍背景，
   注音轨天然在 ruby 元素背景盒外（BUG-110/643 不回归），横竖排、有无振假名一致。 */
.hoshi-sentence-audio-cue.hoshi-sentence-audio-active {
  color: var(--hoshi-sentence-audio-text-color) !important;
  background-color: var(--hoshi-sentence-audio-background-color) !important;
}
a {
  color: ${linkColor ?? colors.linkColor}$readerStylePriority;
}
${einkMode ? _einkOverrideCss(einkDark: einkDark) : ''}
''';
  }

  /// 墨水屏模式覆盖块（追加在正文 CSS 最末尾，级联优先级最高）。
  ///
  /// 设计对齐 Hoshi-Reader-Android 的 E-ink 适配：
  /// - 高亮全部从「半透明色块背景」改为**线式标记**——色块在墨水屏上是一大片
  ///   抖动灰阶，且每次高亮移动都触发大面积刷新；下划线只刷新贴近文字的一条线。
  ///   查词选区=粗实线、有声书跟随=虚线、搜索命中=双线、收藏句=保留原下划线但
  ///   去掉色块（五色在灰阶屏上不可分，线本身就是收藏语义）。
  /// - `--hoshi-reader-eink-mode: 1` 点亮 JS 侧既有的 isEInkMode() 分支
  ///   （reader_visual_novel_scripts / 连续模式滚动缓动短路）。
  /// - 关掉书籍自带的 transition/animation，慢刷新屏上任何补间都是残影。
  static String _einkOverrideCss({required bool einkDark}) {
    final String fg = einkDark ? '#fff' : '#000';
    return '''
/* ── E-ink 墨水屏模式覆盖（必须保持在生成 CSS 的最末尾） ── */
:root {
  --hoshi-reader-eink-mode: 1;
  --hoshi-sel-handle: $fg;
  --hoshi-sentence-audio-text-color: inherit;
  --hoshi-sentence-audio-background-color: transparent;
}
* {
  transition: none !important;
  animation: none !important;
}
::highlight(hoshi-selection) {
  background-color: transparent;
  color: inherit;
  text-decoration-line: underline;
  text-decoration-color: $fg;
  text-decoration-thickness: 0.14em;
  text-underline-offset: 0.18em;
}
ruby.hoshi-selection-ruby-active {
  background-color: transparent !important;
  color: inherit !important;
  text-decoration-line: underline !important;
  text-decoration-color: $fg !important;
  text-decoration-thickness: 0.14em !important;
  text-underline-offset: 0.18em !important;
}
.hoshi-dict-highlight {
  background-color: transparent !important;
  color: inherit !important;
  text-decoration-line: underline !important;
  text-decoration-color: $fg !important;
  text-decoration-thickness: 0.14em !important;
  text-underline-offset: 0.18em !important;
}
::highlight(hoshi-sentence-audio) {
  background-color: transparent;
  color: inherit;
  text-decoration-line: underline;
  text-decoration-style: dashed;
  text-decoration-color: $fg;
  text-decoration-thickness: 0.10em;
  text-underline-offset: 0.18em;
}
ruby.hoshi-sentence-audio-ruby-active {
  background-color: transparent !important;
  color: inherit !important;
  text-decoration-line: underline !important;
  text-decoration-style: dashed !important;
  text-decoration-color: $fg !important;
  text-decoration-thickness: 0.10em !important;
  text-underline-offset: 0.18em !important;
}
.hoshi-sentence-audio-cue.hoshi-sentence-audio-active {
  background-color: transparent !important;
  color: inherit !important;
  text-decoration-line: underline !important;
  text-decoration-style: dashed !important;
  text-decoration-color: $fg !important;
  text-decoration-thickness: 0.10em !important;
  text-underline-offset: 0.18em !important;
}
/* 查词+有声书重叠：查词的粗实线优先（双类特异性高于单类，语义同 BUG-125）。 */
ruby.hoshi-selection-ruby-active.hoshi-sentence-audio-ruby-active {
  text-decoration-style: solid !important;
  text-decoration-thickness: 0.14em !important;
}
::highlight(hoshi-search) {
  background-color: transparent;
  text-decoration-line: underline;
  text-decoration-style: double;
  text-decoration-color: $fg;
}
::highlight(hoshi-hl-yellow), .hoshi-hl-yellow, ruby.hoshi-hl-yellow-ruby-active,
::highlight(hoshi-hl-green), .hoshi-hl-green, ruby.hoshi-hl-green-ruby-active,
::highlight(hoshi-hl-blue), .hoshi-hl-blue, ruby.hoshi-hl-blue-ruby-active,
::highlight(hoshi-hl-pink), .hoshi-hl-pink, ruby.hoshi-hl-pink-ruby-active,
::highlight(hoshi-hl-purple), .hoshi-hl-purple, ruby.hoshi-hl-purple-ruby-active {
  background-color: transparent;
  text-decoration-color: $fg;
}
a {
  color: $fg !important;
}
''';
  }

  static String _paginatedLayoutCss(
    _LayoutCssArgs a, {
    required String columnGapCss,
    required String columnWidthCss,
    required String columnsCss,
    required double clampedMarginLeft,
    required double clampedMarginRight,
    required String contentClipCss,
  }) {
    // 公共参数解构自 _LayoutCssArgs（局部名 / 值与旧命名参数一致）；isVertical 本生成器不用，
    // 故不解构（避免未使用局部告警）。下方 CSS 原始串一字未改。
    final ReaderSettings settings = a.settings;
    final _ThemeColors colors = a.colors;
    final String resolvedFontFamily = a.resolvedFontFamily;
    final String textSpacingCss = a.textSpacingCss;
    final String paddingCss = a.paddingCss;
    final String gridCss = a.gridCss;
    final String textIndentCss = a.textIndentCss;
    final String vertKerningCss = a.vertKerningCss;
    final String vpalCss = a.vpalCss;
    final String textOrientCss = a.textOrientCss;
    final double clampedMarginTop = a.clampedMarginTop;
    final double clampedMarginBottom = a.clampedMarginBottom;
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
  /* TODO-114: 分页模式翻页本是瞬时跳页（fushiReader.assignPagePosition 直接赋值
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
  /* TODO-1285（每页列数分页·相邻页泄露根因修复其一）：分页多列(pageColumns≥2)是
     固定高度 + 横/竖溢出的 multicol。CSS 默认 column-fill:balance 让引擎在末
     fragmentainer把内容均摊成等高短列；Blink 在受限高度下退化成 auto(实测
     balance==auto)故本机无差，但按规范其它引擎/旧 WebView 可对每个 fragment
     都做均摊 → 列高不齐、列不落在 pageStep 网格 → 翻页时相邻页的列露进本页。
     分页 multicol 必须显式 column-fill:auto(与 ttu 上游、本仓 horizontal_pitch
     harness 一致)：逐列填满再溢出、列周期恒 == pageStep。单列(pageColumns≤1)同样
     受用(1 列无可均摊，零行为变化)。 */
  column-fill: auto !important;
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
}
/* TODO-1285（相邻页/列泄露根因修复其二·overflow 裁剪失效兜底）：分页把整条内容当
   一根 multicol 横/竖向溢出、靠 scrollTop/Left 移动 body 看每页；相邻页的列几何上
   落在 body 的 padding(页边距)带里。body{overflow:hidden} 只在 border-box(=padding-box
   外沿=视口帧)裁剪，**裁不掉 padding 带内**滚过的相邻列——唯一遮住它的是 body 的
   clip-path(paint 期裁剪)。clip-path 是绘制期特性，一旦目标 WebView 不支持/不解析
   `inset(calc(vh+var()) vw ...)`/滚动不重绘，padding 带里的相邻列就露出来；单列时那
   只是相邻页整列的一条细边(不易察觉)，多列时 padding 带能容下一整根窄子列 → 用户看到
   「上一页/下一页内容全露出来」。根因是「只靠 clip-path 这一个 paint 期机制遮 padding
   带泄露」。这里在**未被 body clip-path 裁剪的** html 上加一层 ::before 覆盖条：position:
   fixed 贴视口帧、四边 border 宽 == body 四边 padding(与 contentClipCss/padding 逐项一致)、
   border-color=页背景色 → 用背景色不透明覆盖 padding 泄露带；中间内容盒透明(border 只占
   四边)不挡正文；pointer-events:none 不拦选词/点按；极大 z-index 压在正文之上。clip-path
   仍在(Blink 下它已把 padding 带显示成背景、本覆盖条与其同色零视觉变化、可回归验证)，
   但即使 clip-path 失效，本覆盖条独立(html 无 clip-path)遮住泄露 → 引擎无关的兜底。 */
html::before {
  content: "" !important;
  position: fixed !important;
  top: 0 !important; right: 0 !important; bottom: 0 !important; left: 0 !important;
  box-sizing: border-box !important;
  pointer-events: none !important;
  z-index: 2147483000 !important;
  border-style: solid !important;
  border-color: ${colors.backgroundColor} !important;
  border-top-width: calc(${clampedMarginTop}vh + var(--chrome-top-inset, 0px)) !important;
  border-right-width: ${clampedMarginRight}vw !important;
  border-bottom-width: calc(${clampedMarginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px)) !important;
  border-left-width: ${clampedMarginLeft}vw !important;
}''';
  }

  /// TODO-909: VN (Visual-Novel) stage layout. The chapter is detached by the
  /// VN JS and one Block/sentence screen is rendered onto `hoshi-vn-stage` >
  /// `hoshi-vn-screen` > `hoshi-vn-content`. The stage fills the viewport; the
  /// screen reserves the reader chrome insets (top/bottom) and centres its
  /// content. No multicol columns — text flows naturally within one screen, so
  /// this does NOT reuse the paginated column geometry.
  static String _vnLayoutCss(_LayoutCssArgs a) {
    // 公共参数解构自 _LayoutCssArgs（局部名 / 值与旧命名参数一致）；下方 CSS 原始串一字未改。
    final ReaderSettings settings = a.settings;
    final bool isVertical = a.isVertical;
    final _ThemeColors colors = a.colors;
    final String resolvedFontFamily = a.resolvedFontFamily;
    final String textSpacingCss = a.textSpacingCss;
    final String paddingCss = a.paddingCss;
    final String gridCss = a.gridCss;
    final String textIndentCss = a.textIndentCss;
    final String vertKerningCss = a.vertKerningCss;
    final String vpalCss = a.vpalCss;
    final String textOrientCss = a.textOrientCss;
    final double clampedMarginTop = a.clampedMarginTop;
    final double clampedMarginBottom = a.clampedMarginBottom;
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

  static String _continuousLayoutCss(_LayoutCssArgs a) {
    // 公共参数解构自 _LayoutCssArgs（局部名 / 值与旧命名参数一致）；下方 CSS 原始串一字未改。
    final ReaderSettings settings = a.settings;
    final bool isVertical = a.isVertical;
    final _ThemeColors colors = a.colors;
    final String resolvedFontFamily = a.resolvedFontFamily;
    final String textSpacingCss = a.textSpacingCss;
    final String paddingCss = a.paddingCss;
    final String gridCss = a.gridCss;
    final String textIndentCss = a.textIndentCss;
    final String vertKerningCss = a.vertKerningCss;
    final String vpalCss = a.vpalCss;
    final String textOrientCss = a.textOrientCss;
    final double clampedMarginTop = a.clampedMarginTop;
    final double clampedMarginBottom = a.clampedMarginBottom;
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
    // TODO-1308: when furigana is SHOWN, force `display: ruby-text !important` so
    // a book stylesheet that sets `rt { display: inline-block/inline/block }`
    // cannot pull the annotation out of its ruby box and collapse it into the
    // base column in vertical writing (see the ruby rule in the main CSS). rt
    // display is owned here (not globally) so the `hide` branch's display:none
    // still wins for hidden furigana. The shown modes also own <rtc> (see
    // _rtcAnnotationCss); `hide` hides rtc together with rt so a hidden
    // annotation container cannot keep reserving lane space.
    switch (mode) {
      case 'hide':
        return 'rt, rtc { display: none !important; }';
      case 'partial':
        return '''
rt {
  display: ruby-text !important;
  font-size: 0.45em;
  visibility: hidden;
}
$_rtcAnnotationCss
ruby.show-rt rt {
  visibility: visible;
}''';
      case 'toggle':
        return '''
rt {
  display: ruby-text !important;
  font-size: 0.45em;
  visibility: hidden;
}
$_rtcAnnotationCss
body.show-all-rt rt {
  visibility: visible !important;
}''';
      default:
        return '''
rt { display: ruby-text !important; font-size: 0.45em; }
$_rtcAnnotationCss''';
    }
  }

  /// TODO-1308 (user re-report): Blink has no <rtc> support (`display:
  /// ruby-text-container` unsupported; the element defaults to inline), so a
  /// shown <rtc> is remapped to ONE annotation level (`display: ruby-text`)
  /// and its <rt> children are neutralized back to plain inline runs.
  /// Without this, the bare `rt { display: ruby-text !important }` rule wraps
  /// each rtc-nested <rt> in an anonymous ruby at its flow position, dropping
  /// the annotation into the base column as its own character slot (the
  /// 貫(かん)禄(ろく) screenshot: かん inline between 貫/禄, ろく below the
  /// word). `rtc > rt` is MORE specific than the bare `rt` rule, so it must
  /// only be emitted in shown modes — in `hide` it would defeat
  /// `rt { display: none !important }` and un-hide rtc furigana.
  static const String _rtcAnnotationCss = '''
rtc {
  display: ruby-text !important;
  font-size: 0.45em;
}
rtc > rt {
  display: inline !important;
  font-size: 1em;
}''';

  static _ThemeColors _themeColors(String theme,
      {String? customBg, String? customFg}) {
    switch (theme) {
      case 'ecru-theme':
        return const _ThemeColors(
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#f7f6eb',
          selectionColor: 'rgba(194, 178, 128, 0.35)',
          sentenceAudioHighlightColor: 'rgba(168, 198, 140, 0.40)',
          linkColor: '#7a6232',
        );
      case 'water-theme':
        return const _ThemeColors(
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#dfecf4',
          selectionColor: 'rgba(200, 170, 110, 0.35)',
          sentenceAudioHighlightColor: 'rgba(100, 180, 220, 0.40)',
          linkColor: '#3a5fad',
        );
      case 'eyecare-theme':
        // 护眼：豆沙绿正文底 (#c7edcc) + 深灰字，柔和低蓝光。角色色须与
        // chrome.part.dart `_themeMap['eyecare-theme']` 逐一相等（BUG-396）。
        return const _ThemeColors(
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#c7edcc',
          selectionColor: 'rgba(136, 181, 131, 0.35)',
          sentenceAudioHighlightColor: 'rgba(160, 200, 120, 0.40)',
          linkColor: '#4c7a3e',
        );
      case 'gray-theme':
        return const _ThemeColors(
          textColor: 'rgba(255, 255, 255, 0.87)',
          backgroundColor: '#23272a',
          selectionColor: 'rgba(190, 155, 100, 0.35)',
          sentenceAudioHighlightColor: 'rgba(80, 150, 200, 0.35)',
          linkColor: '#6fa8dc',
          colorScheme: 'dark',
        );
      case 'dark-theme':
        return const _ThemeColors(
          textColor: 'rgba(255, 255, 255, 0.6)',
          backgroundColor: '#121212',
          selectionColor: 'rgba(180, 145, 90, 0.35)',
          sentenceAudioHighlightColor: 'rgba(70, 130, 180, 0.35)',
          linkColor: '#7aacdf',
          colorScheme: 'dark',
        );
      case 'black-theme':
        return const _ThemeColors(
          textColor: 'rgba(255, 255, 255, 0.87)',
          backgroundColor: '#000',
          selectionColor: 'rgba(170, 135, 80, 0.40)',
          sentenceAudioHighlightColor: 'rgba(60, 120, 170, 0.40)',
          linkColor: '#5b9bd5',
          colorScheme: 'dark',
        );
      case 'custom-theme':
        return _ThemeColors(
          textColor: customFg ?? 'rgba(0, 0, 0, 0.87)',
          backgroundColor: customBg ?? '#fff',
          colorScheme: isDarkBackground(customBg) ? 'dark' : 'light',
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
          colorScheme: isDarkBackground(customBg) ? 'dark' : 'light',
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
  ///
  /// G14：这是阅读器背景「深/浅」判定的**单一真相**（Rec.601 luma，阈值 0.5）。
  /// 收藏高亮 JS（`HighlightBridge`）不再自带 Rec.709/0.4 公式，而是由 Dart 用
  /// 本函数算好 bool 经 bridge 注入（`window.__hibikiHighlightBgDark`），保证
  /// 滚动条配色与高亮透明度对同一背景色的深浅判定永远一致。
  static bool isDarkBackground(String? background) {
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
    this.sentenceAudioHighlightColor = 'rgba(135, 206, 235, 0.40)',
    this.linkColor = '#426cf5',
    this.colorScheme = 'light',
  });

  final String textColor;
  final String backgroundColor;
  final String selectionColor;
  final String sentenceAudioHighlightColor;
  final String linkColor;

  /// UA color-scheme bucket ('light' | 'dark') the native (Fluent overlay)
  /// scrollbar follows. Derived from the background, not the OS.
  final String colorScheme;
}
