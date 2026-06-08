import 'dart:math' as math;

import 'package:hibiki/src/reader/reader_settings.dart';

class ReaderLayoutDefaults {
  ReaderLayoutDefaults._();

  static const int fontSizePx = 22;
  static const int bottomOverlapPx = fontSizePx;
  static const double imageWidthViewportRatio = 0.95;

  static const String pagePaddingCss = '0vh 2.5vw';
  static const String imageMaxWidthFallbackCss = '95vw';
  static const String imageMaxHeightFallbackCss =
      'calc(var(--page-height, 100vh) - 22px)';
  static const String trailingSpacerHeightCss = 'calc(0vh + 22px)';
  static const String trailingSpacerWidthCss = '0';
}

class ReaderContentStyles {
  ReaderContentStyles._();

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
    // The column-gap is the inter-page period along the page-turn axis. In
    // vertical writing mode pages turn along scrollTop, so the gap must reserve
    // the chrome insets (notch top + chrome bottom) on top of the margins/font;
    // otherwise the column pitch (pageSize + gap = pageHeight - chromeTop -
    // chromeBottom) falls short of the full viewport height and the previous
    // page's tail bleeds into the current page's top notch strip. Including the
    // insets makes pitch == pageHeight so consecutive pages tile exactly.
    // Horizontal mode turns along scrollLeft, where the chrome insets live in
    // padding-top/bottom (perpendicular to the turn axis) and must stay out of
    // the gap.
    final String columnGapCss = isVertical
        ? 'calc(${mt}vh + ${mb}vh + ${settings.fontSize.round()}px + var(--chrome-top-inset, 0px) + var(--chrome-bottom-inset, 0px))'
        : 'calc(${ml}vw + ${mr}vw + ${settings.fontSize.round()}px)';

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

    final String layoutCss = settings.isContinuousMode
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
            gridCss: gridCss,
            textIndentCss: textIndentCss,
            vertKerningCss: vertKerningCss,
            vpalCss: vpalCss,
            textOrientCss: textOrientCss,
            columnsCss: columnsCss,
            clampedMarginTop: mt,
            clampedMarginBottom: mb,
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
::highlight(hoshi-hl-yellow) {
  background-color: var(--hoshi-hl-yellow, rgba(255,220,0,0.35));
}
::highlight(hoshi-hl-green) {
  background-color: var(--hoshi-hl-green, rgba(0,200,83,0.30));
}
::highlight(hoshi-hl-blue) {
  background-color: var(--hoshi-hl-blue, rgba(68,138,255,0.30));
}
::highlight(hoshi-hl-pink) {
  background-color: var(--hoshi-hl-pink, rgba(255,64,129,0.30));
}
::highlight(hoshi-hl-purple) {
  background-color: var(--hoshi-hl-purple, rgba(170,0,255,0.25));
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
    required String gridCss,
    required String textIndentCss,
    required String vertKerningCss,
    required String vpalCss,
    required String textOrientCss,
    required String columnsCss,
    required double clampedMarginTop,
    required double clampedMarginBottom,
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
}
body {
  font-family: $resolvedFontFamily !important;
  font-size: ${settings.fontSize}px !important;
  -webkit-text-size-adjust: none !important;
  overflow-wrap: anywhere !important;
  $textSpacingCss
  box-sizing: border-box !important;
  column-width: var(--page-width, 100vw) !important;
  column-gap: $columnGapCss !important;
  padding: $paddingCss !important;
  padding-top: calc(${clampedMarginTop}vh + var(--chrome-top-inset, 0px)) !important;
  padding-bottom: calc(${clampedMarginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px)) !important;
  $gridCss
  $textOrientCss
  $textIndentCss
  $vertKerningCss
  $vpalCss
  $columnsCss
}''';
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
    final String hiddenOverflowAxis = isVertical ? 'overflow-y' : 'overflow-x';
    final String viewportConstraintCss = isVertical
        ? 'height: var(--hoshi-continuous-height, 100vh) !important;'
        : '''
width: 100vw !important;
  min-height: 100vh !important;''';

    return '''
html, body {
  $hiddenOverflowAxis: hidden !important;
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
  padding-bottom: calc(${clampedMarginBottom}vh + ${settings.fontSize.round()}px + var(--chrome-bottom-inset, 0px)) !important;
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
        return const _ThemeColors();
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
