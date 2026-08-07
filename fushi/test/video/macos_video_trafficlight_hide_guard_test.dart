import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the BUG-973 fix: on macOS the app enables a transparent titlebar +
/// full-size content view (`main.dart`), so the red/yellow/green traffic light
/// buttons float over the top-left of the Flutter content. The video page draws
/// its exit/back button (top bar `topLeft` slot) and left-corner OSD toasts in
/// that same region, and macOS does NOT report the traffic lights as
/// `MediaQuery.padding`, so they overlap. Unlike the home shell (BUG-869, which
/// reserves `kMacTitleBarHeight` via `SafeArea.minimum`), the video page is a
/// full-page route that owns its own chrome, so the fix hides the traffic
/// lights for the whole video session and restores them on exit.
///
/// A source guard is the strongest feasible landing layer: the behaviour is
/// gated on `dart:io`'s `Platform.isMacOS` (which, unlike
/// `debugDefaultTargetPlatformOverride`, can't be faked in a widget test on the
/// Linux/Windows CI host) and drives native `NSWindow.standardWindowButton`
/// visibility through a method channel, neither of which exists under
/// `flutter test`. So we pin the wiring instead: the helper must gate on macOS
/// and toggle all three buttons, and the video lifecycle must hide on enter /
/// restore on exit / re-assert after leaving native fullscreen.
void main() {
  test(
      'setMacOSTrafficLightsHidden gates on macOS and toggles all three '
      'traffic-light buttons (BUG-973)', () {
    final String source =
        File('lib/src/platform/desktop/macos_traffic_lights.dart')
            .readAsStringSync();

    expect(
      RegExp(r'if\s*\(\s*!\s*Platform\.isMacOS\s*\)').hasMatch(source),
      isTrue,
      reason: 'The helper must early-return on non-macOS so it is a no-op on '
          'Windows/Linux/mobile (no traffic lights there).',
    );

    for (final String call in <String>[
      'hideCloseButton',
      'hideMiniaturizeButton',
      'hideZoomButton',
      'showCloseButton',
      'showMiniaturizeButton',
      'showZoomButton',
    ]) {
      expect(
        source.contains('WindowManipulator.$call'),
        isTrue,
        reason: 'The helper must call WindowManipulator.$call so every traffic '
            'light is hidden/restored (a partial hide still leaves overlap).',
      );
    }
  });

  test(
      'video page hides traffic lights on enter and restores on exit '
      '(BUG-973)', () {
    final String source =
        File('lib/src/pages/implementations/video_fushi_page.dart')
            .readAsStringSync();

    final int initState = source.indexOf('void initState()');
    final int dispose = source.indexOf('void dispose()');
    expect(initState, greaterThanOrEqualTo(0));
    expect(dispose, greaterThan(initState),
        reason:
            'dispose() is expected to follow initState() in the state class.');

    final String initBody = source.substring(initState, dispose);
    expect(
      initBody.contains('setMacOSTrafficLightsHidden(true)'),
      isTrue,
      reason:
          'initState must hide the macOS traffic lights when the video page '
          'mounts, or the exit button / OSD stay under them (BUG-973).',
    );

    // Bound dispose to the next member so we do not accidentally read a later
    // method. dispose() is large; scan a generous window from its start.
    final String disposeBody = source.substring(dispose);
    expect(
      disposeBody.contains('setMacOSTrafficLightsHidden(false)'),
      isTrue,
      reason: 'dispose must restore the traffic lights on exit (symmetry with '
          'the initState hide), so the home shell gets them back (BUG-973).',
    );
  });

  test('exiting native fullscreen re-asserts the traffic-light hide (BUG-973)',
      () {
    final String source = File(
      'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
    ).readAsStringSync();

    final int exitFs = source.indexOf('_exitVideoNativeFullscreen()');
    expect(exitFs, greaterThanOrEqualTo(0));
    // Scan the method body: from its declaration to the next method.
    final int nextMethod = source.indexOf('\n  Future<', exitFs + 1);
    final int nextAny = source.indexOf('\n  Widget ', exitFs + 1);
    int end = source.length;
    if (nextMethod > exitFs) end = nextMethod;
    if (nextAny > exitFs && nextAny < end) end = nextAny;
    final String body = source.substring(exitFs, end);

    // AppKit's toggleFullScreen can reset standardWindowButton.isHidden when it
    // rebuilds the titlebar; the desktop branch must re-hide AFTER exiting.
    final int defaultExit = body.indexOf('defaultExitNativeFullscreen()');
    final int reHide = body.indexOf('setMacOSTrafficLightsHidden(true)');
    expect(defaultExit, greaterThanOrEqualTo(0),
        reason: 'desktop branch still exits native fullscreen via media_kit.');
    expect(reHide, greaterThan(defaultExit),
        reason:
            'The desktop branch must re-assert the traffic-light hide after '
            'defaultExitNativeFullscreen(), because AppKit can reset the '
            'button visibility when leaving fullscreen (BUG-973).');
  });
}
