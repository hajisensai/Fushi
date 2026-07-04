import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_theme.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// 守卫：iOS 的 Cupertino chrome 文字派生自 editorial [HibikiTypeScale]，
/// 而不是回到硬编码的 iOS 点数（17/17/34）。若有人把 adaptive_theme 改回写死字号，
/// 或 editorial 阶梯变了而 Cupertino 没跟随，这条会红。
void main() {
  final CupertinoThemeData theme = hibikiCupertinoTheme(
    ColorScheme.fromSeed(seedColor: const Color(0xFF1F4959)),
  );
  final CupertinoTextThemeData tt = theme.textTheme;

  test('Cupertino textStyle 派生自 editorial bodyLarge', () {
    expect(tt.textStyle.fontSize, HibikiTypeScale.bodyLarge.size); // 17
    expect(tt.textStyle.fontWeight, HibikiTypeScale.bodyLarge.weight); // w400
    // 丢弃旧 iOS Latin tracking（-0.41），对齐阶梯的 CJK 安全 0/null。
    expect(tt.textStyle.letterSpacing, isNull);
  });

  test('Cupertino navTitle 派生自 editorial titleLarge', () {
    expect(tt.navTitleTextStyle.fontSize, HibikiTypeScale.titleLarge.size); // 18
    expect(tt.navTitleTextStyle.fontWeight, FontWeight.w600);
  });

  test('Cupertino navLargeTitle 派生自 editorial displaySmall（大标题保持 w600）', () {
    expect(
        tt.navLargeTitleTextStyle.fontSize, HibikiTypeScale.displaySmall.size); // 28
    expect(tt.navLargeTitleTextStyle.fontWeight, FontWeight.w600);
    // 不再是旧的写死 34。
    expect(tt.navLargeTitleTextStyle.fontSize, isNot(34));
  });

  test('Cupertino 字号仍分级（body < navTitle < navLargeTitle）', () {
    expect(tt.textStyle.fontSize! < tt.navTitleTextStyle.fontSize!, isTrue);
    expect(
        tt.navTitleTextStyle.fontSize! < tt.navLargeTitleTextStyle.fontSize!,
        isTrue);
  });
}
