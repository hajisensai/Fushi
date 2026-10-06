import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_theme.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 守卫：iOS 的 Cupertino chrome 文字派生自 Apple 设计系统字阶
/// [FushiAppleTypeScale]（HIG 文字样式），而不是写死点数或误用 Material 字阶。
void main() {
  final CupertinoThemeData theme = fushiCupertinoTheme(
    ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
  );
  final CupertinoTextThemeData tt = theme.textTheme;

  test('Cupertino textStyle = HIG Body（Apple bodyLarge）', () {
    expect(tt.textStyle.fontSize, FushiAppleTypeScale.bodyLarge.size); // 17
    expect(tt.textStyle.fontWeight, FushiAppleTypeScale.bodyLarge.weight);
    // 测试平台不是 Apple：SF tracking 不套给非 SF 系统字体。
    expect(tt.textStyle.letterSpacing, 0);
  });

  test('Cupertino navTitle = HIG Headline（17 semibold）', () {
    expect(tt.navTitleTextStyle.fontSize, FushiAppleTypeScale.titleLarge.size);
    expect(tt.navTitleTextStyle.fontWeight, FontWeight.w600);
  });

  test('Cupertino navLargeTitle = HIG Large Title（34 bold）', () {
    expect(tt.navLargeTitleTextStyle.fontSize,
        FushiAppleTypeScale.displaySmall.size);
    expect(tt.navLargeTitleTextStyle.fontSize, 34);
    expect(tt.navLargeTitleTextStyle.fontWeight, FontWeight.w700);
  });

  test('Cupertino 字号仍分级（body ≤ navTitle < navLargeTitle）', () {
    expect(tt.textStyle.fontSize! <= tt.navTitleTextStyle.fontSize!, isTrue);
    expect(tt.navTitleTextStyle.fontSize! < tt.navLargeTitleTextStyle.fontSize!,
        isTrue);
  });
}
