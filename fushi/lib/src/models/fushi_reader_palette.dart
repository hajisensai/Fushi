import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'package:fushi/src/models/theme_notifier.dart' show hctToneKeepingHue;

/// 「跟随主题」时阅读器（小说 / 漫画 / VN / 有声书歌词 / 编辑页预览）的配色。
///
/// 2026-10-06 用户：「默认主题的阅读器和 M3E 色很不搭配」。旧的跟随分支直接拿
/// `scheme.surface` / `onSurface` / `primary@α` / `tertiary@α`：纸色是 app 页面底
/// （tone 99.5 近纯白 / tone 5），正文 onSurface 是 tone 10 / 90 的界面字色，查词与
/// 跟读高亮是饱和主色叠半透明——界面上的「饱和 container 色块」语言没进到书里，
/// 高亮像荧光笔。这里按 M3E 的色调板重新派生一套**专为长时间阅读**的角色，
/// 随用户主题色（seed / 系统取色 / 自定义钉色）变化：
///
/// | 角色 | 亮色 tone | 暗色 tone |
/// |---|---|---|
/// | 页面底 [background]（VN 底板同） | neutral 98 | neutral 6 |
/// | 正文 [text] | neutral 12 | neutral 90 |
/// | 链接 [link] | primary 40 | primary 80 |
/// | 查词高亮 [lookupHighlight] | primaryContainer 90 @0.75 | primaryContainer 30 @0.70 |
/// | 当前句 [sentenceHighlight] | tertiaryContainer 90 @0.65 | tertiaryContainer 30 @0.60 |
/// | 原生选区 [nativeSelection] | primary 40 @0.25 | primary 80 @0.25 |
/// | 注音 [rubyText] | neutralVariant 40 | neutralVariant 70 |
/// | 浮动工具栏 / 侧板 [chromeContainer] | neutral 92 | neutral 17 |
/// | 漫画底 [mangaBackground] | neutral 95 | neutral 4 |
///
/// neutral 的色相 / 彩度锚定 `scheme.surfaceContainer`（与
/// [applyFushiSurfaceLadder] 同一个锚点，所以和 app 页面底是同一家族），彩度封顶
/// [_kNeutralChromaCap]：vibrant 的中性色彩度 ~10，整页铺满时偏色明显，书页只留
/// 「极轻的主题色调」（默认青色 seed：亮 #F6FAFD / 暗 #0F1417；米色 seed：亮
/// #FFF8F4 / 暗 #18120B）。对比度不变式：正文 ≥ 7:1（WCAG AAA）、注音 ≥ 4.5:1、
/// 高亮合成到纸色上之后正文仍 ≥ 4.5:1；某个 seed 达不到就自动挪 tone / 降 α。
@immutable
class FushiReaderPalette {
  const FushiReaderPalette({
    required this.brightness,
    required this.background,
    required this.text,
    required this.link,
    required this.lookupHighlight,
    required this.sentenceHighlight,
    required this.nativeSelection,
    required this.rubyText,
    required this.chromeContainer,
    required this.mangaBackground,
  });

  final Brightness brightness;

  /// 正文页面底；分页 / 滚动 / VN 三种模式的 `<body>` 与 Scaffold 同源。
  final Color background;

  /// 正文字色（不透明）。
  final Color text;

  final Color link;

  /// 查词命中高亮（半透明，CSS 侧会预合成到 [background] 上）。
  final Color lookupHighlight;

  /// 有声书 / 跟读当前句高亮（半透明）。
  final Color sentenceHighlight;

  /// 桌面鼠标拖选的原生 `::selection`。
  final Color nativeSelection;

  /// 振假名 `<rt>` 字色。
  final Color rubyText;

  /// 阅读器浮动工具栏 / 侧板底色（surfaceContainerHigh 一族）。
  final Color chromeContainer;

  /// 漫画阅读器「跟随主题」底色。
  final Color mangaBackground;

  bool get dark => brightness == Brightness.dark;

  /// VN 模式底板：与正文纸色同一张底（VN 布局 CSS 读的就是正文背景）。
  Color get vnBackdrop => background;
}

/// 中性色彩度上限：整页铺满的纸色只保留极轻的主题色调。
const double _kNeutralChromaCap = 6;

/// neutralVariant（注音）彩度上限，同理。
const double _kNeutralVariantChromaCap = 16;

const double _kBodyContrast = 7.0;
const double _kSecondaryContrast = 4.5;

/// [scheme] 是当前生效的 app ColorScheme（系统取色 / 预设 / 自定义都行，色相与
/// 彩度从它的角色色反推），[brightness] 决定取亮档还是暗档。纯函数，阅读器、
/// 漫画、VN、有声书歌词、自定义主题编辑页预览共用这一份。
FushiReaderPalette fushiReaderPaletteFor(
  ColorScheme scheme,
  Brightness brightness,
) {
  // 阅读器的角色 getter 在一次 build 里会被调很多次（正文色 / 纸色 / 工具栏…），
  // 每次都解十几次 HCT 不划算；入参 → 结果是纯映射，按用到的角色色做键缓存。
  final _ReaderPaletteKey key = (
    scheme.surfaceContainer.toARGB32(),
    scheme.outline.toARGB32(),
    scheme.primary.toARGB32(),
    scheme.primaryContainer.toARGB32(),
    scheme.tertiaryContainer.toARGB32(),
    brightness,
  );
  final FushiReaderPalette? cached = _paletteCache[key];
  if (cached != null) return cached;
  if (_paletteCache.length >= _kPaletteCacheLimit) {
    _paletteCache.remove(_paletteCache.keys.first);
  }
  return _paletteCache[key] = _buildReaderPalette(scheme, brightness);
}

typedef _ReaderPaletteKey = (int, int, int, int, int, Brightness);
final Map<_ReaderPaletteKey, FushiReaderPalette> _paletteCache =
    <_ReaderPaletteKey, FushiReaderPalette>{};
const int _kPaletteCacheLimit = 32;

FushiReaderPalette _buildReaderPalette(
  ColorScheme scheme,
  Brightness brightness,
) {
  final bool dark = brightness == Brightness.dark;

  final Hct neutralAnchor = Hct.fromInt(scheme.surfaceContainer.toARGB32());
  final double neutralChroma =
      math.min(neutralAnchor.chroma, _kNeutralChromaCap);
  Color neutral(double tone) =>
      hctToneKeepingHue(neutralAnchor.hue, neutralChroma, tone);

  final Hct variantAnchor = Hct.fromInt(scheme.outline.toARGB32());
  final double variantChroma =
      math.min(variantAnchor.chroma, _kNeutralVariantChromaCap);
  Color neutralVariant(double tone) =>
      hctToneKeepingHue(variantAnchor.hue, variantChroma, tone);

  final TonalPalette primary = _paletteOf(scheme.primary);
  final TonalPalette primaryContainer = _paletteOf(scheme.primaryContainer);
  final TonalPalette tertiaryContainer = _paletteOf(scheme.tertiaryContainer);

  final Color background = neutral(dark ? 6 : 98);
  final Color text = _ensureContrast(
    neutral,
    startTone: dark ? 90 : 12,
    background: background,
    dark: dark,
    minContrast: _kBodyContrast,
  );
  final Color link = _ensureContrast(
    (double t) => Color(primary.get(t.round())),
    startTone: dark ? 80 : 40,
    background: background,
    dark: dark,
    minContrast: _kSecondaryContrast,
  );
  final Color rubyText = _ensureContrast(
    neutralVariant,
    startTone: dark ? 70 : 40,
    background: background,
    dark: dark,
    minContrast: _kSecondaryContrast,
  );

  return FushiReaderPalette(
    brightness: brightness,
    background: background,
    text: text,
    link: link,
    lookupHighlight: _readableHighlight(
      Color(primaryContainer.get(dark ? 30 : 90)),
      alpha: dark ? 0.70 : 0.75,
      text: text,
      background: background,
    ),
    sentenceHighlight: _readableHighlight(
      Color(tertiaryContainer.get(dark ? 30 : 90)),
      alpha: dark ? 0.60 : 0.65,
      text: text,
      background: background,
    ),
    nativeSelection: _readableHighlight(
      Color(primary.get(dark ? 80 : 40)),
      alpha: 0.25,
      text: text,
      background: background,
    ),
    rubyText: rubyText,
    chromeContainer: neutral(dark ? 17 : 92),
    mangaBackground: neutral(dark ? 4 : 95),
  );
}

TonalPalette _paletteOf(Color color) {
  final Hct hct = Hct.fromInt(color.toARGB32());
  return TonalPalette.of(hct.hue, hct.chroma);
}

/// 两个不透明色的 WCAG 对比度。
double fushiContrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = math.max(la, lb);
  final double lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 从 [startTone] 起往远离 [background] 的方向挪 tone，直到对比度够 [minContrast]。
Color _ensureContrast(
  Color Function(double tone) at, {
  required double startTone,
  required Color background,
  required bool dark,
  required double minContrast,
}) {
  double tone = startTone;
  Color color = at(tone);
  while (fushiContrastRatio(color, background) < minContrast &&
      (dark ? tone < 100 : tone > 0)) {
    tone = (dark ? tone + 2 : tone - 2).clamp(0, 100).toDouble();
    color = at(tone);
  }
  return color;
}

/// 半透明高亮：合成到纸色上之后正文仍须 ≥ 4.5:1，不够就逐级降 α（下限 0.2）。
Color _readableHighlight(
  Color base, {
  required double alpha,
  required Color text,
  required Color background,
}) {
  double a = alpha;
  Color tinted = base.withValues(alpha: a);
  while (a > 0.2 &&
      fushiContrastRatio(text, Color.alphaBlend(tinted, background)) <
          _kSecondaryContrast) {
    a -= 0.05;
    tinted = base.withValues(alpha: a);
  }
  return tinted;
}
