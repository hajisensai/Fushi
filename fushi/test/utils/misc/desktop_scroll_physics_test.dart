import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/smooth_wheel_scroll.dart';

void main() {
  test('Windows/Linux clamp (no bounce); macOS & mobile keep bounce', () {
    final ScrollPhysics physics = desktopAwareScrollPhysics();
    expect(physics, isA<AlwaysScrollableScrollPhysics>());
    // macOS is a Cupertino platform we intentionally leave untouched, so only
    // Windows/Linux get the MD3 clamping physics.
    if (Platform.isWindows || Platform.isLinux) {
      expect(physics.parent, isA<ClampingScrollPhysics>());
    } else {
      expect(physics.parent, isA<BouncingScrollPhysics>());
    }
  });

  test('粗/细分类只决定要不要补间，不决定距离', () {
    final bool md3Desktop = Platform.isWindows || Platform.isLinux;
    bool coarse(double logical, double dpr) =>
        isCoarseDesktopPointerScrollDelta(logical, devicePixelRatio: dpr);
    expect(coarse(120, 1), isTrue);
    expect(coarse(-120, 1), isTrue);
    // BUG-2867：按物理像素判。Windows 默认一档 100 物理 px，150% / 200% 缩放下
    // 逻辑 delta 只剩 66.7 / 50；每次 1 行时一档 33 物理 px；Linux 一档恒 53 逻辑 px。
    expect(coarse(100 / 1.5, 1.5), isTrue);
    expect(coarse(-50, 2), isTrue);
    expect(coarse(16.5, 2), isTrue);
    expect(coarse(53, 1), isTrue);
    // Windows/Linux：高精度滚轮的小 delta（1/8 档约 12.5 物理 px）走原生同步路径，
    // 不加补间。macOS / 移动端的触控板走 PointerPanZoom，到这里的只有物理滚轮，
    // 一律补间（BUG-2834）。
    expect(coarse(12, 1), !md3Desktop);
    expect(coarse(6.25, 2), !md3Desktop);
    // BUG-2009：这里刻意不存在「把 delta 缩小」的入口。一档走多远是系统「每次
    // 滚动行数」设置说了算，app 只补插值不打折；曾经的
    // refinedDesktopPointerScrollDelta（×0.5、封顶 120px）把滚动速度砍了一半。
    expect(
      File('lib/src/utils/misc/smooth_wheel_scroll.dart').readAsStringSync(),
      isNot(contains('refinedDesktopPointerScrollDelta')),
      reason: '粗滚轮距离折扣不得复活',
    );
  });
}
