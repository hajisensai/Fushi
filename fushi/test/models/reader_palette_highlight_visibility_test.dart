import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/fushi_reader_palette.dart';
import 'package:material_ui/material_ui.dart';

/// 反馈 lIWk_4rGA4：粉色系「跟随主题」浅色下，查词选区高亮和纸色几乎分不开。
/// 旧派生只设了上限（合成后正文 ≥ 4.5:1），没有「高亮与纸色至少差多少」的下限：
/// 亮色 primaryContainer tone 90 @0.75 合成到 neutral 98 的纸上只剩 ~1.15:1。
/// 不变式：查词 / 当前句高亮合成到纸色上后与纸色对比 ≥
/// [kFushiReaderHighlightMinVisibility]，正文仍 ≥ 4.5:1。
void main() {
  const List<Color> seeds = <Color>[
    Color(0xFFE91E63), // 粉
    Color(0xFFF8BBD0), // 浅粉（低彩度）
    Color(0xFFFFEB3B), // 黄
    Color(0xFFFFF9C4), // 浅黄（低彩度）
    Color(0xFF1F4959), // 默认青
    Color(0xFF6750A4), // M3 基准紫
    Color(0xFF9E9E9E), // 灰（几乎无彩度）
  ];
  const List<DynamicSchemeVariant> variants = <DynamicSchemeVariant>[
    DynamicSchemeVariant.tonalSpot,
    DynamicSchemeVariant.vibrant,
    DynamicSchemeVariant.content,
    DynamicSchemeVariant.fidelity,
  ];

  for (final Brightness brightness in Brightness.values) {
    test('${brightness.name}: highlights stand off the paper and keep the '
        'text readable', () {
      for (final Color seed in seeds) {
        for (final DynamicSchemeVariant variant in variants) {
          final ColorScheme scheme = ColorScheme.fromSeed(
            seedColor: seed,
            brightness: brightness,
            dynamicSchemeVariant: variant,
          );
          final FushiReaderPalette p = fushiReaderPaletteFor(
            scheme,
            brightness,
          );
          for (final (String role, Color highlight) in <(String, Color)>[
            ('lookup', p.lookupHighlight),
            ('sentence', p.sentenceHighlight),
          ]) {
            final Color composed = Color.alphaBlend(highlight, p.background);
            final String why =
                '$role seed=${seed.toARGB32().toRadixString(16)} '
                '${variant.name}';
            expect(
              fushiContrastRatio(composed, p.background),
              greaterThanOrEqualTo(kFushiReaderHighlightMinVisibility),
              reason: '$why: highlight vs paper',
            );
            expect(
              fushiContrastRatio(p.text, composed),
              greaterThanOrEqualTo(4.5),
              reason: '$why: text on highlight',
            );
          }
        }
      }
    });
  }
}
