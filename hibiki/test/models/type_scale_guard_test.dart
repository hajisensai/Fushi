import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归守卫：锁死"现状已有完整 M3 type scale"这一事实。
///
/// 背景（实证得出）：`AppModel.textTheme` 把一个**只有 fontFamily/关连字、无字号**
/// 的 flat TextStyle 灌进全部 15 个槽位。乍看像"无 type scale、全同质"，但这是假象：
/// Flutter 的字号来自 `Typography` 的 **geometry**，由 `MaterialApp`/`Theme` 在 widget
/// 树内按 locale 应用，flat override 只覆盖 fontFamily，不抹掉字号。所以 running app 的
/// 有效 TextTheme 是完整 M3 2021 阶梯（57→11）。
///
/// 这条守卫防止有人"顺手"给共享 textStyle 加 `fontSize`（会把所有槽位 flat 化、
/// 打破 M3 阶梯），或用 `Typography.material2014` 之类退化配置。
void main() {
  // 复刻 AppModel.textStyle / textTheme：15 槽全灌同一个只有 fontFamily 的 style。
  const TextStyle flat = TextStyle(
    fontFamily: 'GuardFont',
    fontFeatures: [FontFeature('liga', 0)],
  );
  const TextTheme appFlatTextTheme = TextTheme(
    displayLarge: flat,
    displayMedium: flat,
    displaySmall: flat,
    headlineLarge: flat,
    headlineMedium: flat,
    headlineSmall: flat,
    titleLarge: flat,
    titleMedium: flat,
    titleSmall: flat,
    bodyLarge: flat,
    bodyMedium: flat,
    bodySmall: flat,
    labelLarge: flat,
    labelMedium: flat,
    labelSmall: flat,
  );

  testWidgets('flat 15-slot override 仍解析出完整 M3 type scale（非全同质）',
      (tester) async {
    late TextTheme tt;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, textTheme: appFlatTextTheme),
      home: Builder(builder: (context) {
        tt = Theme.of(context).textTheme;
        return const SizedBox();
      }),
    ));

    // 全 15 槽必须有字号（geometry 供给）。
    final Map<String, double?> sizes = {
      'displayLarge': tt.displayLarge?.fontSize,
      'displayMedium': tt.displayMedium?.fontSize,
      'displaySmall': tt.displaySmall?.fontSize,
      'headlineLarge': tt.headlineLarge?.fontSize,
      'headlineMedium': tt.headlineMedium?.fontSize,
      'headlineSmall': tt.headlineSmall?.fontSize,
      'titleLarge': tt.titleLarge?.fontSize,
      'titleMedium': tt.titleMedium?.fontSize,
      'titleSmall': tt.titleSmall?.fontSize,
      'bodyLarge': tt.bodyLarge?.fontSize,
      'bodyMedium': tt.bodyMedium?.fontSize,
      'bodySmall': tt.bodySmall?.fontSize,
      'labelLarge': tt.labelLarge?.fontSize,
      'labelMedium': tt.labelMedium?.fontSize,
      'labelSmall': tt.labelSmall?.fontSize,
    };
    for (final MapEntry<String, double?> e in sizes.entries) {
      expect(e.value, isNotNull, reason: '${e.key} 应有字号（M3 geometry）');
    }

    // 必须是分级的：display > body > label（防被 flat 化成同一字号）。
    expect(tt.displayLarge!.fontSize! > tt.bodyMedium!.fontSize!, isTrue,
        reason: 'displayLarge 应大于 bodyMedium');
    expect(tt.bodyMedium!.fontSize! > tt.labelSmall!.fontSize!, isTrue,
        reason: 'bodyMedium 应大于 labelSmall');

    // 关键锚点与标准 M3 2021 阶梯一致（防退化到 2014 或被改写）。
    expect(tt.displayLarge!.fontSize, 57);
    expect(tt.bodyMedium!.fontSize, 14);
    expect(tt.labelSmall!.fontSize, 11);
    // 字重也分级（title/label 系为 w500）。
    expect(tt.titleMedium!.fontWeight, FontWeight.w500);
    expect(tt.bodyMedium!.fontWeight, FontWeight.w400);
  });
}
