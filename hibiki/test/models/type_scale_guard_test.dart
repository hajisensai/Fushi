import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 回归守卫：锁死应用的 editorial type scale（[HibikiTypeScale]）真正渲染出来，
/// 而不是被 Flutter 的 geometry 盖回 M3 默认。
///
/// 背景（实证得出）：Flutter 的字号来自 Typography 的 geometry，由 MaterialApp/Theme
/// 在 widget 树内按 locale 应用。若 TextTheme 槽位**无**显式字号，geometry 会供给
/// M3 默认字号；但只要给了**显式**字号（[HibikiTypeScale] 就是这么做的），显式值会
/// 穿过 geometry 合并保留下来。这条守卫防止：
///  1. 有人把显式字号去掉（退回 flat）→ 渲染出 M3 默认而非 editorial 阶梯；
///  2. 有人误改 [HibikiTypeScale] 的锚点值。
void main() {
  // 复刻 AppModel.textStyle：locale-aware、只带 fontFamily/关连字、无字号。
  const TextStyle base = TextStyle(fontFamily: 'GuardFont');

  testWidgets('editorial type scale 真正穿过 geometry 渲染出来', (tester) async {
    late TextTheme tt;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        textTheme: HibikiTypeScale.buildTextTheme(base),
      ),
      home: Builder(builder: (context) {
        tt = Theme.of(context).textTheme;
        return const SizedBox();
      }),
    ));

    // 锚点字号 = editorial B 阶梯（非 M3 默认 57/16/14/16/11）。
    expect(tt.displayLarge?.fontSize, 40, reason: 'editorial display，非 M3 57');
    expect(tt.displayMedium?.fontSize, 33);
    expect(tt.displaySmall?.fontSize, 28);
    expect(tt.headlineLarge?.fontSize, 24);
    expect(tt.titleLarge?.fontSize, 18);
    expect(tt.titleMedium?.fontSize, 16);
    expect(tt.bodyLarge?.fontSize, 17, reason: 'editorial body 更大更好读');
    expect(tt.bodyMedium?.fontSize, 15);
    expect(tt.bodySmall?.fontSize, 13);
    expect(tt.labelSmall?.fontSize, 11);

    // 字重分级：headline/title w600 强层级，body w400，label w500。
    expect(tt.headlineMedium?.fontWeight, FontWeight.w600);
    expect(tt.titleMedium?.fontWeight, FontWeight.w600);
    expect(tt.bodyMedium?.fontWeight, FontWeight.w400);
    expect(tt.labelMedium?.fontWeight, FontWeight.w500);

    // 仍是分级的（display > body > label），且 locale 字体保留。
    expect(tt.displayLarge!.fontSize! > tt.bodyMedium!.fontSize!, isTrue);
    expect(tt.bodyMedium!.fontSize! > tt.labelSmall!.fontSize!, isTrue);
    expect(tt.bodyMedium?.fontFamily, 'GuardFont', reason: 'locale 字体注入应保留');
  });
}
