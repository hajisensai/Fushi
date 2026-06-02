import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';

void main() {
  test('desktop gets clamping (no bounce) physics, mobile keeps bounce', () {
    final ScrollPhysics physics = desktopAwareScrollPhysics();
    expect(physics, isA<AlwaysScrollableScrollPhysics>());
    if (isDesktopPlatform) {
      expect(physics.parent, isA<ClampingScrollPhysics>());
    } else {
      expect(physics.parent, isA<BouncingScrollPhysics>());
    }
  });
}
