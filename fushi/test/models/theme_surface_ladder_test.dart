import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// 表面层级阶梯（[applyFushiSurfaceLadder]）的不变式。
///
/// 背景：M3 baseline 的六级容器色相邻只差 2 tone（对比度 ≈ 1.05），本意是让
/// elevation 阴影与 surfaceTint 叠层承担层次。Hibiki 是「扁平 + 描边」的语言，
/// 全局 `elevation: 0` 且 surfaceTint 一律透明，于是层次只剩这 1.05 的色差；
/// 而 token 映射（page=surface / group=surfaceContainerLow / card=
/// surfaceContainer）恰好落在阶梯最挤的一段，三层总跨度只有 1.11——设置页、
/// 书架、媒体库里页面底、导航窗格、卡片就糊成一片。
///
/// 这里钉的是**关系**不是色值：单调、相邻可辨、页面↔卡片够开，同时不能为了拉
/// 开层级把选中态和描边挤掉（亮色下 tone 90 是 `*Container` 角色的地盘，卡片
/// 压过头 secondaryContainer 就贴上来了）。色值本身随主题走，不该钉死。
void main() {
  double contrast(Color a, Color b) {
    final double la = a.computeLuminance(), lb = b.computeLuminance();
    final double hi = la > lb ? la : lb;
    final double lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 由低层级到高层级（M3 语义：越"高"离内容越近）。
  List<Color> ladder(ColorScheme s) => <Color>[
        s.surfaceContainerLowest,
        s.surface,
        s.surfaceContainerLow,
        s.surfaceContainer,
        s.surfaceContainerHigh,
        s.surfaceContainerHighest,
      ];

  const List<String> ladderNames = <String>[
    'surfaceContainerLowest',
    'surface',
    'surfaceContainerLow',
    'surfaceContainer',
    'surfaceContainerHigh',
    'surfaceContainerHighest',
  ];

  /// 全部内置预设 × 亮暗，外加一个中性派生（monochrome）方案。
  Map<String, ColorScheme> allSchemes() {
    final Map<String, ColorScheme> out = <String, ColorScheme>{};
    ThemeNotifier.themePresets.forEach((
      String key,
      ({Color seed, Brightness brightness, DynamicSchemeVariant variant}) v,
    ) {
      for (final Brightness b in Brightness.values) {
        out['$key/${b.name}'] = buildFushiColorScheme(
          seedColor: v.seed,
          brightness: b,
          variant: v.variant,
        );
      }
    });
    for (final Brightness b in Brightness.values) {
      out['neutral-derived/${b.name}'] = buildFushiColorScheme(
        seedColor: const Color(0xFF0B57D0),
        brightness: b,
        neutralDerived: true,
      );
      // 系统取色（桌面走 accent seed 这条）也必须过同一道阶梯。
      out['system-accent/${b.name}'] = applyFushiSurfaceLadder(
        buildSystemThemeColorScheme(
          brightness: b,
          fallbackSeed: const Color(0xFF1F4959),
          accent: const Color(0xFF7A4EAB),
        ),
      );
    }
    return out;
  }

  test('六级严格单调：亮色逐级变深，深色逐级变亮', () {
    allSchemes().forEach((String name, ColorScheme s) {
      final List<Color> l = ladder(s);
      final bool light = s.brightness == Brightness.light;
      for (int i = 1; i < l.length; i++) {
        final double prev = l[i - 1].computeLuminance();
        final double cur = l[i].computeLuminance();
        expect(
          light ? cur < prev : cur > prev,
          isTrue,
          reason: '$name: ${ladderNames[i]} 没有比 ${ladderNames[i - 1]} 更'
              '${light ? '深' : '亮'}（$prev → $cur）',
        );
      }
    });
  });

  test('相邻层可辨：surface 之上每一级 ≥ 1.07', () {
    allSchemes().forEach((String name, ColorScheme s) {
      final List<Color> l = ladder(s);
      // 从 index 1(surface) 起算：Lowest↔surface 在亮色下是纯白与近纯白，
      // 本来就该几乎无差（它是"比页面还远"的那一层，极少与页面同屏相邻）。
      for (int i = 2; i < l.length; i++) {
        expect(
          contrast(l[i], l[i - 1]),
          greaterThanOrEqualTo(1.07),
          reason: '$name: ${ladderNames[i]} 对 ${ladderNames[i - 1]} 只有 '
              '${contrast(l[i], l[i - 1]).toStringAsFixed(3)}',
        );
      }
    });
  });

  test('页面底↔卡片 ≥ 1.14（改前 M3 baseline 只有 1.11）', () {
    allSchemes().forEach((String name, ColorScheme s) {
      expect(
        contrast(s.surface, s.surfaceContainer),
        greaterThanOrEqualTo(1.14),
        reason: '$name: page↔card 只有 '
            '${contrast(s.surface, s.surfaceContainer).toStringAsFixed(3)}',
      );
    });
  });

  test('拉开层级不能挤掉选中态与描边', () {
    allSchemes().forEach((String name, ColorScheme s) {
      // 亮色下 tone 90 是 secondaryContainer 的地盘：卡片再往下压，列表选中项
      // 就贴上卡片底色糊掉（实测压到 tone 92.5 时掉到 1.069）。
      expect(
        contrast(s.secondaryContainer, s.surfaceContainer),
        greaterThanOrEqualTo(1.085),
        reason: '$name: 选中态对卡片只有 '
            '${contrast(s.secondaryContainer, s.surfaceContainer).toStringAsFixed(3)}',
      );
      // 扁平 + 描边的语言里，卡片边界靠 outlineVariant 承担。
      expect(
        contrast(s.outlineVariant, s.surfaceContainer),
        greaterThanOrEqualTo(1.35),
        reason: '$name: 卡片描边对卡片只有 '
            '${contrast(s.outlineVariant, s.surfaceContainer).toStringAsFixed(3)}',
      );
    });
  });

  test('阶梯只改 tone：色相与彩度沿用原方案', () {
    const Color seed = Color(0xFF8B7355);
    for (final Brightness b in Brightness.values) {
      final ColorScheme base = ColorScheme.fromSeed(
        seedColor: seed,
        brightness: b,
      );
      final ColorScheme out = applyFushiSurfaceLadder(base);
      final Hct anchor = Hct.fromInt(base.surfaceContainer.toARGB32());
      for (final Color c in ladder(out)) {
        final Hct h = Hct.fromInt(c.toARGB32());
        // 阶梯两端贴近纯白 / 纯黑，sRGB 装不下那点彩度，HCT 往回量化时 chroma
        // 会掉、hue 随之失去意义（同 isAchromaticSeed 的道理）。这些格子只要求
        // 彩度不高于锚点，不比色相。
        if (h.chroma < anchor.chroma - 1.5) {
          expect(h.tone, anyOf(greaterThan(96.0), lessThan(6.0)));
          continue;
        }
        // 中性表面的彩度只有 4 上下，sRGB 在这一带能落的点很稀，HCT 往返量化
        // 漂几度是常态。这里要抓的是「阶梯把暖色主题算成冷色」这类真回归，
        // 不是量化噪声，所以容差给到 12°。
        final double d = (h.hue - anchor.hue).abs();
        expect(
          d > 180 ? 360 - d : d,
          lessThan(12.0),
          reason: '色相漂了：${anchor.hue} → ${h.hue}（tone ${h.tone}）',
        );
        expect(h.chroma, closeTo(anchor.chroma, 1.5));
      }
      // 主题色角色一个都不碰。
      expect(out.primary, base.primary);
      expect(out.secondaryContainer, base.secondaryContainer);
      expect(out.outlineVariant, base.outlineVariant);
      expect(out.onSurface, base.onSurface);
    }
  });

  test('dim / bright 仍是页面底的暗 / 亮变体', () {
    // surfaceDim / surfaceBright 是页面底自己的两个变体（不是容器阶梯的端点）：
    // dim 永远比 surface 暗、bright 永远不比它暗，两种亮度模式下都如此。亮色把
    // highest 压到 tone 87 之后，M3 baseline 的 dim(87) 会不再比 highest 暗，
    // 所以这两个必须跟着阶梯一起调。
    allSchemes().forEach((String name, ColorScheme s) {
      expect(
        s.surfaceDim.computeLuminance(),
        lessThan(s.surface.computeLuminance()),
        reason: '$name: surfaceDim 没比页面底暗',
      );
      expect(
        s.surfaceBright.computeLuminance(),
        greaterThanOrEqualTo(s.surface.computeLuminance()),
        reason: '$name: surfaceBright 比页面底还暗',
      );
      expect(
        s.surfaceDim.computeLuminance(),
        lessThan(s.surfaceContainerHighest.computeLuminance()),
        reason: '$name: surfaceDim 没落在容器阶梯的暗端之外',
      );
    });
  });

  test('墨水屏不过阶梯：表面仍全塌成纯黑白', () {
    for (final Brightness b in Brightness.values) {
      final ColorScheme s = buildEinkColorScheme(b);
      for (final Color c in ladder(s)) {
        expect(c, s.surface, reason: 'eink 的表面必须全等于底色');
      }
    }
  });

  test('钉死底色的梯度与统一阶梯同量级（不会前后一跳）', () {
    for (final Color pinned in <Color>[Colors.white, Colors.black]) {
      final SurfaceRoles r = deriveSurfaceRolesFrom(pinned);
      final List<Color> l = <Color>[
        r.surface,
        r.surfaceContainerLow,
        r.surfaceContainer,
        r.surfaceContainerHigh,
        r.surfaceContainerHighest,
      ];
      for (int i = 1; i < l.length; i++) {
        expect(
          contrast(l[i], l[i - 1]),
          greaterThanOrEqualTo(1.07),
          reason: '钉死 $pinned：第 $i 级只有 ${contrast(l[i], l[i - 1])}',
        );
      }
      expect(
        contrast(r.surface, r.surfaceContainer),
        greaterThanOrEqualTo(1.14),
      );
    }
  });

  test('三条主题路径出口都过阶梯（源码守卫）', () {
    final String src = File(
      'lib/src/models/theme_notifier.dart',
    ).readAsStringSync();
    // system-theme 分支：Android 壁纸调色板与桌面 accent seed 推出的阶梯间距
    // 本来就不同，不收口这里两端观感不一致。
    expect(
      RegExp(
        r'applyFushiSurfaceLadder\(\s*buildSystemThemeColorScheme\(',
      ).hasMatch(src),
      isTrue,
      reason: 'system-theme 分支必须过 applyFushiSurfaceLadder',
    );
    // 预设 / 自定义分支：未钉死 surface 时的出口。
    expect(
      src.contains('_hibikiSchemeCache[key] = applyFushiSurfaceLadder('),
      isTrue,
      reason: 'buildFushiColorScheme 未钉死 surface 的出口必须过阶梯',
    );
  });
}
