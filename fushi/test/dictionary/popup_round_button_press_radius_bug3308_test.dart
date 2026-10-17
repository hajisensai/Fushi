import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-3308：点查词弹窗的「+」制卡按钮时，按钮后面闪出一个完全直角的方块。
///
/// 根因：M3E 圆形图标按钮按下时 border-radius 从静息值过渡到 corner-medium /
/// corner-small，曲线是会过冲的弹簧 `spring-fast-spatial`
/// （cubic-bezier y1 = 1.67）。静息值原先是 corner-full 的哨兵值 999px，插值
/// `999 + (12 - 999) · p` 在 p 过冲到约 1.013 以上就成负数、被钳成 0px：每次按下
/// 约有 120ms 是直角方块（Edge 无头逐帧采样 119–237ms 恒为 0px，真 Windows
/// WebView2 桌面截屏也抓到这一帧）。M3E 的按压形变本身是设计，保留；修的是插值
/// 起点：这些按钮都是正方形，静息写 50%，从真实几何半径起插，过冲后仍是正半径。
///
/// 守卫做的是数值层面的检查，不只比对字面量：从 popup.css 读出弹簧曲线、按压目标
/// 半径与静息半径，算出曲线的最大过冲，断言过冲那一帧的半径仍 > 0。另外用
/// 999px 跑同一条公式，确认它确实 ≤ 0（反向对照，防止判据本身是空的）。
void main() {
  final String css = maskCssComments(
    File('assets/popup/popup.css').readAsStringSync(),
  );

  String token(String name) {
    final RegExpMatch? m = RegExp(
      '${RegExp.escape(name)}\\s*:\\s*([^;]+);',
    ).firstMatch(css);
    expect(m, isNotNull, reason: '缺少令牌 $name');
    return m!.group(1)!.trim();
  }

  String ruleBody(String selector) {
    final RegExpMatch? m = RegExp(
      '(?:^|\\n)${RegExp.escape(selector)}\\s*\\{([^}]*)\\}',
    ).firstMatch(css);
    expect(m, isNotNull, reason: '缺少规则 `$selector`');
    return m!.group(1)!;
  }

  String radiusOf(String body) {
    final RegExpMatch? m = RegExp(
      r'border-radius\s*:\s*([^;]+);',
    ).firstMatch(body);
    expect(m, isNotNull, reason: '规则里没有 border-radius');
    return m!.group(1)!.trim();
  }

  double px(String value) {
    final String v = value.startsWith('var(')
        ? token(value.substring(4, value.length - 1).trim())
        : value;
    expect(v, endsWith('px'), reason: '期望 px 值，实际 $v');
    return double.parse(v.substring(0, v.length - 2));
  }

  /// 弹簧曲线 y(t) 的最大值（cubic-bezier 的进度过冲峰值）。
  double maxProgress() {
    final RegExpMatch m = RegExp(
      r'cubic-bezier\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\)',
    ).firstMatch(token('--md-sys-motion-spring-fast-spatial'))!;
    final double y1 = double.parse(m.group(2)!);
    final double y2 = double.parse(m.group(4)!);
    double best = 0;
    for (int i = 0; i <= 2000; i++) {
      final double t = i / 2000;
      final double y =
          3 * math.pow(1 - t, 2) * t * y1 +
          3 * (1 - t) * t * t * y2 +
          math.pow(t, 3);
      best = math.max(best, y);
    }
    return best;
  }

  /// 静息半径 [rest] → 按压半径 [pressed] 在进度 [p] 处的计算值（box 边长 [size]）。
  double radiusAt(String rest, double pressed, double p, double size) {
    final double from = rest.endsWith('%')
        ? size * double.parse(rest.substring(0, rest.length - 1)) / 100
        : px(rest);
    return from + (pressed - from) * p;
  }

  late final double peak = maxProgress();

  // (静息规则, 按压规则, 盒子最小边长)：头部按钮 clamp(32px, …, 40px) 取 32；
  // 句子上下文步进按钮 16px 正方形。
  final List<(String, String, double)> cases = <(String, String, double)>[
    (
      'html.fushi-m3e .header-buttons > .inline-action-button',
      'html.fushi-m3e .header-buttons > .inline-action-button:where(:not(:disabled)):active',
      32,
    ),
    (
      'html.fushi-m3e .inline-action-button',
      'html.fushi-m3e .inline-action-button:where(:not(:disabled)):where(:not(.header-buttons > *)):active',
      16,
    ),
  ];

  test('弹簧曲线确实会过冲（前提成立，否则本守卫无意义）', () {
    expect(peak, greaterThan(1.01));
  });

  for (final (String rest, String active, double size) in cases) {
    test('`$rest` 按下过冲时半径仍为正，不会钳成 0px 直角', () {
      final String restRadius = radiusOf(ruleBody(rest));
      final double pressed = px(radiusOf(ruleBody(active)));
      final double atPeak = radiusAt(restRadius, pressed, peak, size);
      expect(
        atPeak,
        greaterThan(0),
        reason:
            '静息 $restRadius → 按下 ${pressed}px，过冲峰值 p=$peak 时半径 '
            '$atPeak px ≤ 0，会被钳成直角方块（BUG-3308）',
      );
      // 反向对照：999px 哨兵值在同一条公式下必然被钳成 0。
      expect(radiusAt('999px', pressed, peak, size), lessThanOrEqualTo(0));
    });
  }

  test('步进按钮静息半径同样不用 999px 哨兵值', () {
    expect(
      radiusOf(
        ruleBody(
          'html.fushi-m3e .sentence-context-picker .context-stepper-btn',
        ),
      ),
      '50%',
    );
  });
}
