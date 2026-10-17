// 复习卡面的设计系统令牌（SrsCardTokens）与它生成的卡面注入变量：MD3 与 Apple 两套各自
// 映射（表面色阶 / 圆角 / 字阶倍率 / 间距），切换设计系统时注入值跟着变。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_card_tokens.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:material_ui/material_ui.dart';

ThemeData _theme({required bool apple}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
  textTheme: FushiTypeScale.buildTextTheme(const TextStyle()),
  designSystem: apple
      ? FushiDesignSystem.cupertino
      : FushiDesignSystem.material,
  glass: FushiGlassMaterial.off,
  glassDesign: apple,
);

String _css(
  ThemeData theme, {
  SrsCardAppearance a = const SrsCardAppearance(),
}) => srsCardAppearanceCss(
  appearance: a,
  appScheme: theme.colorScheme,
  tokens: SrsCardTokens.fromTheme(theme),
  dark: false,
  labels: const SrsCardLabels(allDefinitions: 'a', frequency: 'f', source: 's'),
  fontUrl: (String p) => p,
);

double _var(String css, String name) =>
    double.parse(RegExp('$name:([0-9.]+)').firstMatch(css)!.group(1)!);

String _color(String css, String name) =>
    RegExp('$name:(#[0-9a-f]{6}|rgba\\([^)]*\\))').firstMatch(css)!.group(1)!;

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

void main() {
  test('MD3：M3E 形状 / 字阶 / 表面色阶', () {
    final ThemeData theme = _theme(apple: false);
    final SrsCardTokens t = SrsCardTokens.fromTheme(theme);
    expect(t.apple, isFalse);
    expect(t.radius, FushiM3eShape.card);
    expect(t.radiusSmall, FushiM3eShape.small);
    expect(t.radiusInner, FushiRadii.chipValue);
    expect(t.templateTextRatio, 1);
    expect(t.emphasisLine.fontSize, FushiTypeScale.titleLarge.size);
    final ColorScheme s = theme.colorScheme;
    expect(t.surface1(s), s.surfaceContainer);
    expect(t.surface3(s), t.surfacesFor(s).overlay);

    final String css = _css(theme);
    expect(_var(css, '--fushi-srs-radius'), FushiM3eShape.card);
    expect(_var(css, '--fushi-srs-radius-small'), FushiM3eShape.small);
    expect(_var(css, '--fushi-srs-text-scale'), 1);
    expect(
      _color(css, '--fushi-srs-surface-container'),
      _hex(s.surfaceContainer),
    );
    expect(css, contains(':root .card.card{--fc-gap:16px;--fc-pad:16px;}'));
  });

  test('Apple：inset grouped 圆角 / HIG 字阶 / 分组背景', () {
    final ThemeData theme = _theme(apple: true);
    final SrsCardTokens t = SrsCardTokens.fromTheme(theme);
    expect(t.apple, isTrue);
    expect(t.radius, FushiAppleMetrics.forPlatform(theme.platform).groupRadius);
    expect(t.radiusSmall, 10);
    expect(
      t.templateTextRatio,
      closeTo(
        FushiAppleTypeScale.bodyLarge.size / FushiTypeScale.bodyLarge.size,
        1e-9,
      ),
    );
    final FushiAppleColors apple = theme.extension<FushiAppleColors>()!;
    expect(t.surface1(theme.colorScheme), apple.secondaryGroupedBackground);

    final String css = _css(theme);
    expect(_var(css, '--fushi-srs-radius'), t.radius);
    expect(_var(css, '--fushi-srs-radius-small'), 10);
    expect(
      _var(css, '--fushi-srs-text-scale'),
      closeTo(t.templateTextRatio, 0.001),
    );
    expect(
      _color(css, '--fushi-srs-surface-container'),
      _hex(apple.secondaryGroupedBackground),
    );
  });

  test('切换设计系统：注入的圆角、字阶倍率与表面色都变', () {
    final String md3 = _css(_theme(apple: false));
    final String apple = _css(_theme(apple: true));
    for (final String v in <String>[
      '--fushi-srs-radius-small',
      '--fushi-srs-text-scale',
      '--fushi-srs-term-scale',
    ]) {
      expect(_var(md3, v), isNot(_var(apple, v)), reason: v);
    }
    expect(
      _color(md3, '--fushi-srs-surface-container'),
      isNot(_color(apple, '--fushi-srs-surface-container')),
    );
  });

  test('用户倍率乘在设计系统倍率上；密度档按间距令牌缩放', () {
    final ThemeData theme = _theme(apple: true);
    final SrsCardTokens t = SrsCardTokens.fromTheme(theme);
    final String css = _css(
      theme,
      a: const SrsCardAppearance(
        textScale: 1.2,
        density: SrsCardDensity.compact,
      ),
    );
    expect(
      _var(css, '--fushi-srs-text-scale'),
      closeTo(1.2 * t.templateTextRatio, 0.001),
    );
    expect(
      t.gap(SrsCardDensity.compact),
      lessThan(t.gap(SrsCardDensity.standard)),
    );
    expect(
      css,
      contains(
        '--fc-gap:${t.gap(SrsCardDensity.compact).toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '')}px;',
      ),
    );
  });
}
