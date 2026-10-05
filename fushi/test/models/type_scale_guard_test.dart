import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// 回归守卫：锁死应用的 M3 Expressive type scale（[FushiTypeScale]）真正渲染
/// 出来，而不是被 Flutter 的 geometry 盖回默认；以及 Emphasized 变体、CJK 适配、
/// Apple 设计系统的 HIG 映射。
///
/// 背景（实证得出）：Flutter 的字号来自 Typography 的 geometry，由 MaterialApp/Theme
/// 在 widget 树内按 locale 应用。若 TextTheme 槽位**无**显式字号，geometry 会供给
/// 默认字号；但只要给了**显式**字号（[FushiTypeScale] 就是这么做的），显式值会
/// 穿过 geometry 合并保留下来。
void main() {
  // 复刻 AppModel.textStyle：locale-aware、只带 fontFamily、无字号。
  const TextStyle latin = TextStyle(fontFamily: 'GuardFont');
  const TextStyle cjk = TextStyle(
    fontFamily: 'GuardFont',
    locale: Locale('zh', 'CN'),
    textBaseline: TextBaseline.ideographic,
  );

  testWidgets('M3E type scale 真正穿过 geometry 渲染出来', (tester) async {
    late TextTheme tt;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        textTheme: FushiTypeScale.buildTextTheme(latin),
      ),
      home: Builder(builder: (context) {
        tt = Theme.of(context).textTheme;
        return const SizedBox();
      }),
    ));

    // M3 baseline 字号（material-components-android typography tokens）。
    expect(tt.displayLarge?.fontSize, 57);
    expect(tt.displayMedium?.fontSize, 45);
    expect(tt.displaySmall?.fontSize, 36);
    expect(tt.headlineLarge?.fontSize, 32);
    expect(tt.headlineMedium?.fontSize, 28);
    expect(tt.headlineSmall?.fontSize, 24);
    expect(tt.titleLarge?.fontSize, 22);
    expect(tt.titleMedium?.fontSize, 16);
    expect(tt.titleSmall?.fontSize, 14);
    expect(tt.bodyLarge?.fontSize, 16);
    expect(tt.bodyMedium?.fontSize, 14);
    expect(tt.bodySmall?.fontSize, 12);
    expect(tt.labelLarge?.fontSize, 14);
    expect(tt.labelMedium?.fontSize, 12);
    expect(tt.labelSmall?.fontSize, 11);

    // 行高 = 行高 token / 字号。
    expect(tt.bodyLarge!.height! * 16, closeTo(24, 1e-9));
    expect(tt.titleLarge!.height! * 22, closeTo(28, 1e-9));
    expect(tt.labelSmall!.height! * 11, closeTo(16, 1e-9));

    // 拉丁 tracking 照规范。
    expect(tt.bodyLarge?.letterSpacing, 0.5);
    expect(tt.labelMedium?.letterSpacing, 0.5);
    expect(tt.displayLarge?.letterSpacing, -0.25);

    // 字重：M3 基础（测试平台 android：w500 不取整）。
    expect(tt.headlineMedium?.fontWeight, FontWeight.w400);
    expect(tt.titleMedium?.fontWeight, FontWeight.w500);
    expect(tt.bodyMedium?.fontWeight, FontWeight.w400);
    expect(tt.labelMedium?.fontWeight, FontWeight.w500);

    expect(tt.bodyMedium?.fontFamily, 'GuardFont', reason: 'locale 字体注入应保留');
  });

  test('Emphasized 字重表与 Compose TypeScaleTokens 一致', () {
    const Map<String, FontWeight> expected = <String, FontWeight>{
      'displayLarge': FontWeight.w500,
      'displayMedium': FontWeight.w500,
      'displaySmall': FontWeight.w500,
      'headlineLarge': FontWeight.w500,
      'headlineMedium': FontWeight.w500,
      'headlineSmall': FontWeight.w500,
      'titleLarge': FontWeight.w500,
      'titleMedium': FontWeight.w700,
      'titleSmall': FontWeight.w700,
      'bodyLarge': FontWeight.w500,
      'bodyMedium': FontWeight.w500,
      'bodySmall': FontWeight.w500,
      'labelLarge': FontWeight.w700,
      'labelMedium': FontWeight.w700,
      'labelSmall': FontWeight.w700,
    };
    final List<FontWeight> actual = <FontWeight>[
      for (final FushiTypeSpec s in FushiTypeScale.roles) s.emphasizedWeight,
    ];
    expect(actual, expected.values.toList());
  });

  test('CJK：去 tracking、小字号行高不低于 1.4，大字号保持规范', () {
    final TextTheme tt = FushiTypeScale.buildTextTheme(cjk);
    expect(tt.bodyLarge?.letterSpacing, 0);
    expect(tt.labelMedium?.letterSpacing, 0);
    expect(tt.bodySmall?.height, kFushiCjkMinLineHeight);
    expect(tt.labelMedium?.height, kFushiCjkMinLineHeight);
    expect(tt.bodyLarge?.height, 1.5, reason: '1.5 本就高于下限');
    expect(tt.displayLarge?.height, closeTo(64 / 57, 1e-9));
    expect(tt.headlineSmall?.height, closeTo(32 / 24, 1e-9));
    expect(tt.bodyMedium?.locale, const Locale('zh', 'CN'));
  });

  test('Windows / Linux：w500 取整到 w600（系统 UI 字体无 Medium 字面）', () {
    for (final TargetPlatform p in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = p;
      try {
        final TextTheme tt = FushiTypeScale.buildTextTheme(latin);
        expect(tt.titleMedium?.fontWeight, FontWeight.w600, reason: '$p');
        expect(tt.labelLarge?.fontWeight, FontWeight.w600, reason: '$p');
        expect(tt.bodyMedium?.fontWeight, FontWeight.w400, reason: '$p');
        expect(
          FushiTypeScale.bodyMedium.applyEmphasizedTo(latin).fontWeight,
          FontWeight.w600,
          reason: '$p emphasized Medium 也取整',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }
  });

  testWidgets('context.fushiType：基础角色 = 主题槽位，Emphasized 只加重字重', (tester) async {
    late FushiTypography type;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(textTheme: FushiTypeScale.buildTextTheme(latin)),
      home: Builder(builder: (context) {
        type = context.fushiType;
        return const SizedBox();
      }),
    ));
    expect(type.apple, isFalse);
    expect(type.titleLarge.fontSize, 22);
    expect(type.titleLargeEmphasized.fontSize, 22);
    expect(type.titleLargeEmphasized.height, type.titleLarge.height);
    expect(type.titleLargeEmphasized.fontWeight, FontWeight.w500);
    expect(type.labelLargeEmphasized.fontWeight, FontWeight.w700);
    expect(type.displaySmallEmphasized.fontFamily, 'GuardFont');
  });

  testWidgets('Apple 设计系统：同一 API 映射到 HIG 字阶', (tester) async {
    late FushiTypography type;
    final TextTheme apple =
        appleTextTheme(FushiTypeScale.buildTextTheme(latin));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        textTheme: apple,
        extensions: <ThemeExtension<dynamic>>[
          FushiAppleColors.of(Brightness.light, const Color(0xFF007AFF)),
        ],
      ),
      home: Builder(builder: (context) {
        type = context.fushiType;
        return const SizedBox();
      }),
    ));
    expect(type.apple, isTrue);
    expect(type.bodyLarge.fontSize, 17, reason: 'HIG Body');
    expect(type.titleLarge.fontSize, 17, reason: 'HIG Headline');
    expect(type.titleLarge.fontWeight, FontWeight.w600);
    expect(type.displaySmall.fontSize, 34, reason: 'HIG Large Title');
    expect(type.displaySmall.fontWeight, FontWeight.w700);
    expect(type.bodyLargeEmphasized.fontWeight, FontWeight.w600);
    expect(type.bodyLarge.fontFamily, 'GuardFont');
  });

  test('tabular：加 tnum、保留已有 feature、去掉 pnum', () {
    const TextStyle base = TextStyle(
      fontFeatures: <FontFeature>[
        FontFeature('liga', 0),
        FontFeature.proportionalFigures(),
      ],
    );
    final List<FontFeature> features = base.tabular.fontFeatures!;
    expect(features, contains(const FontFeature('liga', 0)));
    expect(features, contains(const FontFeature.tabularFigures()));
    expect(features, isNot(contains(const FontFeature.proportionalFigures())));
    expect(base.tabular.tabular.fontFeatures!.length, features.length);
  });
}
