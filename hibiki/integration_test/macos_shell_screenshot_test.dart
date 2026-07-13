import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons, VerticalDivider;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:macos_ui/macos_ui.dart' show MacosWindow;

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart'
    show hibikiMaterialNavKey;

import 'helpers/focus_driver.dart';

/// macOS-only visual capture of the default-auto MD3 shell. Run via:
///   flutter drive \
///     --driver=test_driver/integration_test_screenshots.dart \
///     --target=integration_test/macos_shell_screenshot_test.dart -d macos
///
/// Captures pixels off the render tree's largest RepaintBoundary (the engine
/// framebuffer), so it works even when the OS window is parked on a non-active
/// Space — which blocks `screencapture`/ScreenCaptureKit on the remote build
/// Mac. (The integration_test `captureScreenshot` channel is unimplemented on
/// macOS, hence the direct RepaintBoundary.toImage path.)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS default auto renders the MD3 home and settings shell',
      (WidgetTester tester) async {
    app.main();

    // Boot can take a while (DB open, dictionary preload). Pump until the
    // Material navigation shell appears, up to 90s.
    bool homeReady = false;
    for (int i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(hibikiMaterialNavKey).evaluate().isNotEmpty) {
        homeReady = true;
        break;
      }
    }
    expect(homeReady, isTrue,
        reason: 'MD3 navigation should render within 90s on macOS.');
    expect(find.byType(MacosWindow), findsNothing,
        reason: 'Default auto must not create the hidden native macOS shell.');
    expect(find.byType(VerticalDivider), findsNothing,
        reason: 'The MD3 navigation rail must flow into the content surface '
            'without the Apple-style sidebar separator.');

    // Let the first frame settle, then capture the home (bookshelf) shell.
    await tester.pump(const Duration(seconds: 1));

    // The integration_test captureScreenshot channel is unimplemented on macOS,
    // so grab pixels directly off the render tree's largest RepaintBoundary
    // (covers the whole window) and write the PNG from Dart. This reads the
    // engine framebuffer, immune to the OS Spaces/TCC screenshot wall.
    // Sandboxed app: a relative path resolves against the app's runtime CWD
    // (not the project), so write into the container's temp dir and print the
    // absolute path for the harness to pull back.
    final String tmp = Directory.systemTemp.path;
    await _captureLargestBoundary(tester, '$tmp/macos_home_shell.png');

    // Navigate through the MD3 rail/bottom bar using the shared focus driver,
    // then capture the Material settings shell.
    final Finder materialNav = find.byKey(hibikiMaterialNavKey);
    final Finder settingsItem = find.descendant(
      of: materialNav,
      matching: find.byIcon(Icons.tune_outlined),
    );
    expect(settingsItem, findsOneWidget,
        reason: 'MD3 settings destination should be present.');
    final FocusDriver driver = FocusDriver(tester);
    expect(await driver.focusWidget(settingsItem), isTrue,
        reason: 'Settings destination should be keyboard reachable.');
    await driver.activate();
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    await _captureLargestBoundary(tester, '$tmp/macos_settings.png');
    debugPrint('[test] captured macos_settings');
  });
}

Future<void> _captureLargestBoundary(WidgetTester tester, String path) async {
  // Pick the boundary that best matches the window viewport. "Largest area"
  // alone is wrong — unconstrained scroll content yields pathological boundaries
  // (e.g. 100000x31). Cap each dimension to a sane window size first, then take
  // the largest remaining area (the full-window boundary wins).
  const double maxDim = 5000;
  RenderRepaintBoundary? best;
  double bestArea = 0;
  for (final Element e in find.byType(RepaintBoundary).evaluate()) {
    final RenderObject? ro = e.renderObject;
    if (ro is RenderRepaintBoundary && ro.hasSize) {
      final Size s = ro.size;
      if (s.width > maxDim || s.height > maxDim || s.height < 100) continue;
      final double area = s.width * s.height;
      if (area > bestArea) {
        bestArea = area;
        best = ro;
      }
    }
  }
  if (best == null) {
    debugPrint('[test] SCREENSHOT_RESULT=no-boundary');
    return;
  }
  final ui.Image image = await best.toImage(pixelRatio: 1.0);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) {
    debugPrint('[test] toByteData returned null');
    return;
  }
  final File f = await File(path).create(recursive: true);
  f.writeAsBytesSync(png.buffer.asUint8List());
  debugPrint('[test] SCREENSHOT_RESULT=ok size=${best.size} path=$path');
}
