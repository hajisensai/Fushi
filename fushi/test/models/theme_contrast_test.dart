import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';

/// M3E 配色（2026-10-05「图标和配色也统一成 m3e」）的对比度门：
/// 多种子色 × 亮 / 暗 × 关键「容器 / on-色」角色对，全部达到 WCAG AA。
///
/// - 文字类角色对（on-色压在对应底色上）≥ 4.5:1；
/// - 非文字 UI 组件（primary 指示 / 进度压在页面底上）≥ 3:1。
///
/// 种子覆盖：全部内置预设、默认品牌色、以及自定义主题会遇到的极端色——纯白 /
/// 纯黑 / 中灰（走 monochrome + 低彩度强调，HCT 极亮端纯灰也会读出 ~2.8 彩度）、
/// 近白暖色（HCT 极亮端色相漂移坑）、满彩度原色与荧光黄 / 青。
void main() {
  double contrast(Color a, Color b) {
    final double la = a.computeLuminance();
    final double lb = b.computeLuminance();
    final double hi = la > lb ? la : lb;
    final double lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  final Map<String, Color> seeds = <String, Color>{
    for (final MapEntry<String, ThemePreset> e
        in ThemeNotifier.themePresets.entries)
      'preset:${e.key}': e.value.seed,
    'default': kFushiDefaultSeed,
    'white': const Color(0xFFFFFFFF),
    'black': const Color(0xFF000000),
    'gray': const Color(0xFF808080),
    'nearWhiteWarm': const Color(0xFFFFF8E1),
    'paperEcru': const Color(0xFFF5ECD7),
    'red': const Color(0xFFFF0000),
    'blue': const Color(0xFF0000FF),
    'yellow': const Color(0xFFFFFF00),
    'cyan': const Color(0xFF00FFFF),
    'magenta': const Color(0xFFFF00FF),
  };

  List<(String, Color, Color, double)> pairs(ColorScheme cs) =>
      <(String, Color, Color, double)>[
        ('primary/onPrimary', cs.primary, cs.onPrimary, 4.5),
        (
          'primaryContainer/onPrimaryContainer',
          cs.primaryContainer,
          cs.onPrimaryContainer,
          4.5,
        ),
        ('secondary/onSecondary', cs.secondary, cs.onSecondary, 4.5),
        (
          'secondaryContainer/onSecondaryContainer',
          cs.secondaryContainer,
          cs.onSecondaryContainer,
          4.5,
        ),
        ('tertiary/onTertiary', cs.tertiary, cs.onTertiary, 4.5),
        (
          'tertiaryContainer/onTertiaryContainer',
          cs.tertiaryContainer,
          cs.onTertiaryContainer,
          4.5,
        ),
        ('error/onError', cs.error, cs.onError, 4.5),
        (
          'errorContainer/onErrorContainer',
          cs.errorContainer,
          cs.onErrorContainer,
          4.5,
        ),
        ('surface/onSurface', cs.surface, cs.onSurface, 4.5),
        ('surface/onSurfaceVariant', cs.surface, cs.onSurfaceVariant, 4.5),
        (
          'surfaceContainerLowest/onSurface',
          cs.surfaceContainerLowest,
          cs.onSurface,
          4.5,
        ),
        (
          'surfaceContainerLow/onSurface',
          cs.surfaceContainerLow,
          cs.onSurface,
          4.5,
        ),
        (
          'surfaceContainer/onSurface',
          cs.surfaceContainer,
          cs.onSurface,
          4.5,
        ),
        (
          'surfaceContainerHigh/onSurface',
          cs.surfaceContainerHigh,
          cs.onSurface,
          4.5,
        ),
        (
          'surfaceContainerHighest/onSurface',
          cs.surfaceContainerHighest,
          cs.onSurface,
          4.5,
        ),
        (
          'surfaceContainerHighest/onSurfaceVariant',
          cs.surfaceContainerHighest,
          cs.onSurfaceVariant,
          4.5,
        ),
        (
          'inverseSurface/onInverseSurface',
          cs.inverseSurface,
          cs.onInverseSurface,
          4.5,
        ),
        (
          'primaryFixed/onPrimaryFixed',
          cs.primaryFixed,
          cs.onPrimaryFixed,
          4.5,
        ),
        (
          'primaryFixedDim/onPrimaryFixed',
          cs.primaryFixedDim,
          cs.onPrimaryFixed,
          4.5,
        ),
        (
          'secondaryFixed/onSecondaryFixed',
          cs.secondaryFixed,
          cs.onSecondaryFixed,
          4.5,
        ),
        (
          'tertiaryFixed/onTertiaryFixed',
          cs.tertiaryFixed,
          cs.onTertiaryFixed,
          4.5,
        ),
        ('surface/primary (UI 组件)', cs.surface, cs.primary, 3),
      ];

  for (final MapEntry<String, Color> seed in seeds.entries) {
    for (final Brightness b in Brightness.values) {
      test('M3E 默认方案 ${seed.key} ${b.name}：关键角色对达到 WCAG AA', () {
        final ColorScheme cs = buildFushiColorScheme(
          seedColor: seed.value,
          brightness: b,
        );
        final List<String> failures = <String>[
          for (final (String name, Color bg, Color fg, double min) in pairs(cs))
            if (contrast(bg, fg) < min)
              '$name ${contrast(bg, fg).toStringAsFixed(2)} < $min',
        ];
        expect(failures, isEmpty, reason: '${seed.key} ${b.name}');
      });
    }
  }

  test('内置预设（含纯黑真黑阶梯）亮 / 暗都达到 AA', () {
    final List<String> failures = <String>[];
    for (final MapEntry<String, ThemePreset> e
        in ThemeNotifier.themePresets.entries) {
      for (final Brightness b in Brightness.values) {
        final ColorScheme cs = ThemeNotifier.buildPresetColorScheme(e.value, b);
        for (final (String name, Color bg, Color fg, double min) in pairs(cs)) {
          if (contrast(bg, fg) < min) {
            failures.add('${e.key} ${b.name} $name');
          }
        }
      }
    }
    expect(failures, isEmpty);
  });

  test('自定义主题钉死极端主色 / 容器色：on-色取对比度更高的黑或白', () {
    const List<Color> pins = <Color>[
      Color(0xFFFFFF00),
      Color(0xFFFFFFFF),
      Color(0xFF000000),
      Color(0xFF6E6E6E), // 亮度 0.155：旧阈值判「亮」配黑字只有 ~4.1
      Color(0xFF777777),
      Color(0xFF00FF00),
      Color(0xFF0000FF),
    ];
    for (final Brightness b in Brightness.values) {
      for (final Color pin in pins) {
        final ColorScheme cs = buildFushiColorScheme(
          seedColor: kFushiDefaultSeed,
          brightness: b,
          primary: pin,
          secondary: pin,
          tertiary: pin,
          primaryContainer: pin,
        );
        expect(
          contrast(cs.primary, cs.onPrimary),
          greaterThanOrEqualTo(4.5),
          reason: '${b.name} $pin primary',
        );
        expect(
          contrast(cs.primaryContainer, cs.onPrimaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: '${b.name} $pin primaryContainer',
        );
        expect(
          contrast(cs.secondaryContainer, cs.onSecondaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: '${b.name} $pin secondaryContainer',
        );
        expect(
          contrast(cs.tertiaryContainer, cs.onTertiaryContainer),
          greaterThanOrEqualTo(4.5),
          reason: '${b.name} $pin tertiaryContainer',
        );
      }
    }
  });

  test('无彩度 seed 不被 vibrant 拉成鲜艳强调色', () {
    for (final Color seed in <Color>[
      const Color(0xFFFFFFFF),
      const Color(0xFF808080),
      const Color(0xFF000000),
    ]) {
      for (final Brightness b in Brightness.values) {
        final ColorScheme vibrantDefault = buildFushiColorScheme(
          seedColor: seed,
          brightness: b,
        );
        final ColorScheme tonal = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: b,
          dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
        );
        expect(vibrantDefault.primary, tonal.primary, reason: '$seed ${b.name}');
      }
    }
  });
}
