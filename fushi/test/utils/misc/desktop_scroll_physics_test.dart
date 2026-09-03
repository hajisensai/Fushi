import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

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
    expect(isCoarseDesktopPointerScrollDelta(120), md3Desktop);
    expect(isCoarseDesktopPointerScrollDelta(-120), md3Desktop);
    expect(isCoarseDesktopPointerScrollDelta(12), isFalse,
        reason: '触控板/高精度滚轮的小 delta 走原生同步路径，不加补间');
    // BUG-2009：这里刻意不存在「把 delta 缩小」的入口。一档走多远是系统「每次
    // 滚动行数」设置说了算，app 只补插值不打折；曾经的
    // refinedDesktopPointerScrollDelta（×0.5、封顶 120px）把滚动速度砍了一半。
    expect(
      File('lib/src/utils/misc/platform_utils.dart').readAsStringSync(),
      isNot(contains('refinedDesktopPointerScrollDelta')),
      reason: '粗滚轮距离折扣不得复活',
    );
  });
}
