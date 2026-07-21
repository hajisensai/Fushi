import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/theme_notifier.dart';

/// BUG-969：阅读设置抽屉的主题选择器每次 rebuild 对每张色卡各调一次
/// [buildHibikiColorScheme]（系统 + 预设 7 + 自定义 N），拖字号 slider 时每个
/// tick 全表 setState = 每 tick 一场 `ColorScheme.fromSeed` HCT 风暴。修复是
/// 按参数键 memo；本测试钉死「同参返回同一实例（缓存命中）、异参各自独立」。
void main() {
  group('buildHibikiColorScheme memo (BUG-969)', () {
    test('同参两次调用返回同一实例（identical，缓存命中）', () {
      final ColorScheme a = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      final ColorScheme b = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      expect(identical(a, b), isTrue,
          reason: '纯函数 memo：同参必须命中缓存，否则主题选择器每次 rebuild '
              '重跑全部 HCT 色调板生成');
    });

    test('明暗 / 种子 / 角色覆写不同 → 各自独立结果', () {
      final ColorScheme light = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
      );
      final ColorScheme dark = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.dark,
      );
      expect(identical(light, dark), isFalse);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);

      final ColorScheme overridden = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
        primary: const Color(0xFFAA3366),
      );
      expect(identical(light, overridden), isFalse);
      expect(overridden.primary, const Color(0xFFAA3366));
      // 覆写参数组合同样被缓存。
      final ColorScheme overriddenAgain = buildHibikiColorScheme(
        seedColor: const Color(0xFF1F4959),
        brightness: Brightness.light,
        primary: const Color(0xFFAA3366),
      );
      expect(identical(overridden, overriddenAgain), isTrue);
    });
  });
}
