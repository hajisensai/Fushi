import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';

/// ASS Fontname（GDI 全名）字重后缀解析纯函数守卫。
/// 存在性探测在测试环境恒判缺失（FlutterTest 所有家族同字体），解析器返回 null →
/// 既有回退路径像素不变，由既有字号/样式断言隐式守卫。
void main() {
  test('assFontWeightFromSuffix maps foundry suffixes', () {
    expect(assFontWeightFromSuffix('B'), FontWeight.w700);
    expect(assFontWeightFromSuffix('Bold'), FontWeight.w700);
    expect(assFontWeightFromSuffix('DB'), FontWeight.w600);
    expect(assFontWeightFromSuffix('EB'), FontWeight.w800);
    expect(assFontWeightFromSuffix('L'), FontWeight.w300);
    expect(assFontWeightFromSuffix('UL'), FontWeight.w200);
    expect(assFontWeightFromSuffix('M'), FontWeight.w500);
    expect(assFontWeightFromSuffix('R'), FontWeight.w400);
    expect(assFontWeightFromSuffix('W3'), FontWeight.w300);
    expect(assFontWeightFromSuffix('W6'), FontWeight.w600);
    expect(assFontWeightFromSuffix('W8'), FontWeight.w800);
    // 非字重后缀：家族名成分不得被误剥。
    expect(assFontWeightFromSuffix('ProN'), isNull);
    expect(assFontWeightFromSuffix('Std'), isNull);
    expect(assFontWeightFromSuffix('75S'), isNull);
    expect(assFontWeightFromSuffix('W20'), isNull);
    expect(assFontWeightFromSuffix('Mincho'), isNull);
  });
}
