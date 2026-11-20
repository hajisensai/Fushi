import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/fushi_reader_palette.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4931 / 反馈 gTKeeq9mXp：开「纯黑深色背景」（OLED）后 app 外壳是真黑，
/// 阅读器「跟随主题」的纸色却固定取 neutral tone 6（≈ rgb(15,20,23)），漫画底
/// tone 4。阅读配色必须从同一个 ColorScheme 认出纯黑：页面底 / 漫画底 = #000，
/// 正文 / 注音 / 高亮的对比度不变式照旧成立；非纯黑深色与亮色不变。
void main() {
  const List<Color> seeds = <Color>[
    Color(0xFF1F4959), // 默认青
    Color(0xFFE91E63), // 粉
    Color(0xFFFFEB3B), // 黄
    Color(0xFF6750A4), // M3 基准紫
  ];
  const Color black = Color(0xFF000000);

  for (final Color seed in seeds) {
    test('pure black dark: reader paper and manga backdrop are #000 '
        '(seed ${seed.toARGB32().toRadixString(16)})', () {
      final ColorScheme scheme = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.dark,
        pureBlack: true,
      );
      expect(fushiReaderSchemeIsPureBlack(scheme), isTrue);
      final FushiReaderPalette p = fushiReaderPaletteFor(
        scheme,
        Brightness.dark,
      );
      expect(p.background, black);
      expect(p.vnBackdrop, black);
      expect(p.mangaBackground, black);
      expect(fushiContrastRatio(p.text, p.background), greaterThanOrEqualTo(7));
      expect(
        fushiContrastRatio(p.rubyText, p.background),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        fushiContrastRatio(p.text, Color.alphaBlend(p.lookupHighlight, black)),
        greaterThanOrEqualTo(4.5),
      );

      // 阅读器真正读的入口（resolveReaderThemeColors，跟随主题分支）也是黑底。
      final ReaderThemeColors colors = resolveReaderThemeColors(
        themeKey: 'system-theme',
        presetMap: const <String, ReaderThemeColors>{},
        scheme: scheme,
      );
      expect(colors.bg, black);
    });

    test('regular dark / light keep the tinted paper '
        '(seed ${seed.toARGB32().toRadixString(16)})', () {
      for (final Brightness b in Brightness.values) {
        final ColorScheme scheme = buildFushiColorScheme(
          seedColor: seed,
          brightness: b,
        );
        expect(fushiReaderSchemeIsPureBlack(scheme), isFalse);
        final FushiReaderPalette p = fushiReaderPaletteFor(scheme, b);
        expect(p.background, isNot(black));
        expect(p.mangaBackground, isNot(black));
      }
      // 纯黑开关只作用于深色：亮色下同一开关不改纸色。
      final ColorScheme light = buildFushiColorScheme(
        seedColor: seed,
        brightness: Brightness.light,
        pureBlack: true,
      );
      expect(
        fushiReaderPaletteFor(light, Brightness.light).background,
        isNot(black),
      );
    });
  }
}
