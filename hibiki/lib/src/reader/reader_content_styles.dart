import 'package:hibiki/src/reader/reader_settings.dart';

class ReaderLayoutDefaults {
  ReaderLayoutDefaults._();

  static const int fontSizePx = 20;
  static const int bottomOverlapPx = fontSizePx;
  static const double imageWidthViewportRatio = 0.95;

  static const String columnGapCss = 'calc(0vh + 20px)';
  static const String pagePaddingCss = '0vh 2.5vw';
  static const String bottomPaddingCss = 'calc(0vh + 20px)';
  static const String imageMaxWidthFallbackCss = '95vw';
  static const String imageMaxHeightFallbackCss =
      'calc(var(--page-height, 100vh) - 20px)';
  static const String trailingSpacerHeightCss = 'calc(0vh + 20px)';
  static const String trailingSpacerWidthCss = '0';
}

class ReaderContentStyles {
  ReaderContentStyles._();

  static String styleTag({
    required ReaderSettings settings,
    String? fontFaces,
    String? fontFamily,
  }) {
    return '<style>\n${css(
      settings: settings,
      fontFaces: fontFaces,
      fontFamily: fontFamily,
    )}\n</style>';
  }

  static String css({
    required ReaderSettings settings,
    String? fontFaces,
    String? fontFamily,
  }) {
    final ({String textColor, String backgroundColor}) colors =
        _themeColors(settings.theme);

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
    final double firstMargin = settings.firstDimensionMargin;
    final double secondMargin = settings.secondDimensionMargin;

    final String paddingCss = isVertical
        ? '${secondMargin}vh ${firstMargin}vw'
        : '${firstMargin}vh ${secondMargin}vw';
    final String columnGapCss = isVertical
        ? 'calc(${secondMargin}vh + ${settings.fontSize.round()}px)'
        : 'calc(${secondMargin}vw + ${settings.fontSize.round()}px)';
    final String bottomPaddingCss = isVertical
        ? 'calc(${secondMargin}vh + ${settings.fontSize.round()}px)'
        : 'calc(${firstMargin}vh + ${settings.fontSize.round()}px)';

    final String textSpacingCss = 'line-height: ${settings.lineHeight} !important;';

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

    final String vertKerningCss = settings.enableVerticalFontKerning && isVertical
        ? 'font-kerning: normal !important;'
        : '';

    final String vpalCss = settings.enableFontVPAL && isVertical
        ? "font-feature-settings: 'vpal' 1 !important;"
        : '';

    final String textOrientCss = isVertical
        ? 'text-orientation: ${settings.verticalTextOrientation};'
        : '';

    final String maxValueCss = settings.secondDimensionMaxValue > 0
        ? (isVertical
            ? 'max-height: ${settings.secondDimensionMaxValue}px !important;'
            : 'max-width: ${settings.secondDimensionMaxValue}px !important;')
        : '';

    final String columnsCss = settings.pageColumns > 0
        ? 'column-count: ${settings.pageColumns} !important;'
        : '';

    final String imageMaxWidth = settings.secondDimensionMaxValue > 0
        ? '${(settings.secondDimensionMaxValue * ReaderLayoutDefaults.imageWidthViewportRatio).round()}px'
        : ReaderLayoutDefaults.imageMaxWidthFallbackCss;
    const String imageMaxHeight = ReaderLayoutDefaults.imageMaxHeightFallbackCss;

    final String layoutCss = settings.isContinuousMode
        ? _continuousLayoutCss(
            settings: settings,
            isVertical: isVertical,
            colors: colors,
            resolvedFontFamily: resolvedFontFamily,
            textSpacingCss: textSpacingCss,
            paddingCss: paddingCss,
            bottomPaddingCss: bottomPaddingCss,
            gridCss: gridCss,
            textIndentCss: textIndentCss,
            vertKerningCss: vertKerningCss,
            vpalCss: vpalCss,
            textOrientCss: textOrientCss,
            maxValueCss: maxValueCss,
          )
        : _paginatedLayoutCss(
            settings: settings,
            isVertical: isVertical,
            colors: colors,
            resolvedFontFamily: resolvedFontFamily,
            textSpacingCss: textSpacingCss,
            paddingCss: paddingCss,
            bottomPaddingCss: bottomPaddingCss,
            columnGapCss: columnGapCss,
            gridCss: gridCss,
            textIndentCss: textIndentCss,
            vertKerningCss: vertKerningCss,
            vpalCss: vpalCss,
            textOrientCss: textOrientCss,
            maxValueCss: maxValueCss,
            columnsCss: columnsCss,
          );

    final String readerStylePriority =
        settings.prioritizeReaderStyles ? '' : ' !important';

    return '''
$resolvedFontFaces
$pageBreakCss
@media (prefers-color-scheme: light) { :root { --hoshi-system-text-color: #000; } }
@media (prefers-color-scheme: dark) { :root { --hoshi-system-text-color: #fff; } }
:root {
  --hoshi-sasayaki-text-color: #000;
  --hoshi-sasayaki-background-color: rgba(135, 206, 235, 0.4);
}
html {
  -webkit-line-box-contain: block glyphs replaced;
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
}
img:not(.block-img) {
  max-width: 100%$readerStylePriority;
  max-height: var(--hoshi-image-max-height, $imageMaxHeight)$readerStylePriority;
  object-fit: contain$readerStylePriority;
}
p > img:only-child, div > img:only-child, section > img:only-child {
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
$furiganaCss
ruby > rt, ruby > rp {
  -webkit-user-select: none;
  user-select: none;
}
::highlight(hoshi-selection) {
  background-color: rgba(160, 160, 160, 0.4) !important;
  color: inherit;
}
.hoshi-sasayaki-cue.hoshi-sasayaki-active {
  color: var(--hoshi-sasayaki-text-color) !important;
  background-color: var(--hoshi-sasayaki-background-color) !important;
}
a {
  color: rgba(66, 108, 245, 1)$readerStylePriority;
}
''';
  }

  static String _paginatedLayoutCss({
    required ReaderSettings settings,
    required bool isVertical,
    required ({String textColor, String backgroundColor}) colors,
    required String resolvedFontFamily,
    required String textSpacingCss,
    required String paddingCss,
    required String bottomPaddingCss,
    required String columnGapCss,
    required String gridCss,
    required String textIndentCss,
    required String vertKerningCss,
    required String vpalCss,
    required String textOrientCss,
    required String maxValueCss,
    required String columnsCss,
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
  $textSpacingCss
  box-sizing: border-box !important;
  column-width: var(--page-width, 100vw) !important;
  column-gap: $columnGapCss;
  padding: $paddingCss !important;
  padding-bottom: $bottomPaddingCss !important;
  $gridCss
  $textOrientCss
  $textIndentCss
  $vertKerningCss
  $vpalCss
  $maxValueCss
  $columnsCss
}''';
  }

  static String _continuousLayoutCss({
    required ReaderSettings settings,
    required bool isVertical,
    required ({String textColor, String backgroundColor}) colors,
    required String resolvedFontFamily,
    required String textSpacingCss,
    required String paddingCss,
    required String bottomPaddingCss,
    required String gridCss,
    required String textIndentCss,
    required String vertKerningCss,
    required String vpalCss,
    required String textOrientCss,
    required String maxValueCss,
  }) {
    final String hiddenOverflowAxis =
        isVertical ? 'overflow-y' : 'overflow-x';
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
  $textSpacingCss
  box-sizing: border-box !important;
  $viewportConstraintCss
  padding: $paddingCss !important;
  padding-bottom: $bottomPaddingCss !important;
  $gridCss
  $textOrientCss
  $textIndentCss
  $vertKerningCss
  $vpalCss
  $maxValueCss
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
ruby:hover rt, ruby:active rt, ruby.show-rt rt {
  visibility: visible;
}''';
      case 'toggle':
        return '''
rt {
  font-size: 0.45em;
  visibility: hidden;
}
ruby.show-rt rt {
  visibility: visible;
}''';
      default:
        return 'rt { font-size: 0.45em; }';
    }
  }

  static ({String textColor, String backgroundColor}) _themeColors(
      String theme) {
    switch (theme) {
      case 'ecru-theme':
        return (
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#f7f6eb',
        );
      case 'water-theme':
        return (
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#dfecf4',
        );
      case 'gray-theme':
        return (
          textColor: 'rgba(255, 255, 255, 0.87)',
          backgroundColor: '#23272a',
        );
      case 'dark-theme':
        return (
          textColor: 'rgba(255, 255, 255, 0.6)',
          backgroundColor: '#121212',
        );
      case 'black-theme':
        return (
          textColor: 'rgba(255, 255, 255, 0.87)',
          backgroundColor: '#000',
        );
      default:
        return (
          textColor: 'rgba(0, 0, 0, 0.87)',
          backgroundColor: '#fff',
        );
    }
  }
}
