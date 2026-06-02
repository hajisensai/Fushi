import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

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
}
