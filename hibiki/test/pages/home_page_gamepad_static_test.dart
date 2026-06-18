import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HomePage gives focused gamepad actions priority over arrow fallback',
      () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    final int focusedActionIndex = source.indexOf(
      'dispatchNativeGamepadButtonIntent(event)',
    );
    final int arrowFallbackIndex =
        source.indexOf('arrowTraversalDirection(event.logicalKey)');

    expect(focusedActionIndex, isNonNegative);
    expect(arrowFallbackIndex, isNonNegative);
    expect(
      focusedActionIndex,
      lessThan(arrowFallbackIndex),
      reason: 'Native D-pad/gameButton events must reach the focused widget '
          'before HomePage converts arrows into page-level focus movement.',
    );
  });

  test('HomePage gamepad fallback is source-aware', () {
    final String source = File(
      'lib/src/pages/implementations/home_page.dart',
    ).readAsStringSync();

    expect(source, contains('GamepadButton.fromKeyEvent(event)'));
    expect(
      source,
      isNot(contains('GamepadButton.fromLogicalKey(event.logicalKey)')),
      reason:
          'Keyboard arrows share logical keys with D-pad; HomePage must not '
          'resolve them as gamepad bindings without checking event.deviceType.',
    );
  });
}
