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

  test('粗滚轮减半并封顶，小 delta 与非 MD3 桌面保持原样', () {
    final bool refined = Platform.isWindows || Platform.isLinux;
    expect(refinedDesktopPointerScrollDelta(120), refined ? 60 : 120);
    expect(refinedDesktopPointerScrollDelta(-120), refined ? -60 : -120);
    expect(refinedDesktopPointerScrollDelta(400), refined ? 120 : 400);
    expect(refinedDesktopPointerScrollDelta(12), 12,
        reason: '触控板/高精度滚轮的小 delta 必须保持 1:1');
    expect(isCoarseDesktopPointerScrollDelta(120), refined);
    expect(isCoarseDesktopPointerScrollDelta(12), isFalse);
  });
}
