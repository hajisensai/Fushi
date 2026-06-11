import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-195: Samsung OneUI 6.5 draws a system default focus rectangle on the
/// FlutterView host (API 26+ `defaultFocusHighlightEnabled` defaults to true),
/// double-overlapping Hibiki's own focus ring. MainActivity must disable the
/// Android system default focus highlight on the decorView, guarded by an
/// API 26+ (Build.VERSION_CODES.O) version gate, while leaving the Flutter
/// self-drawn focus ring untouched. Reverting any part turns this test red.
void main() {
  test('MainActivity disables Android system default focus highlight', () {
    final String src = File(
      'android/app/src/main/java/app/hibiki/reader/MainActivity.java',
    ).readAsStringSync();

    // Core fix: disable the system default focus highlight on a real View.
    expect(
      src,
      contains('setDefaultFocusHighlightEnabled(false)'),
      reason: 'Must disable the Android system default focus highlight to stop '
          'the double focus ring on Samsung OneUI.',
    );

    // Version gate: setDefaultFocusHighlightEnabled exists only on API 26+.
    expect(
      src,
      contains('Build.VERSION_CODES.O'),
      reason: 'setDefaultFocusHighlightEnabled is API 26+; the call must be '
          'gated by Build.VERSION.SDK_INT >= Build.VERSION_CODES.O.',
    );
    expect(src, contains('Build.VERSION.SDK_INT'));

    // Target the window/decor view hierarchy that hosts FlutterView.
    expect(
      src,
      contains('getWindow().getDecorView()'),
      reason: 'The highlight must be cleared on the decorView that hosts the '
          'programmatically-created FlutterSurfaceView.',
    );

    // The helper must be both defined AND actually wired into onCreate. The
    // call site is appended right after super.onCreate so the decorView is
    // already attached. Asserting the exact wiring sequence makes removing the
    // call (leaving only a dead helper) turn this test red.
    expect(
      src,
      contains('super.onCreate(savedInstanceState);\n\n'
          '        disableSystemFocusHighlight();'),
      reason: 'disableSystemFocusHighlight() must be invoked from onCreate '
          'right after super.onCreate, not merely defined.',
    );
    expect(
      src,
      contains('private void disableSystemFocusHighlight()'),
      reason: 'The disable logic must live in a dedicated helper method.',
    );
  });
}
