import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:macos_ui/macos_ui.dart' show MacosWindow, MacosIcon;

import 'package:hibiki/main.dart' as app;

/// macOS-only visual capture of the native shell. Run via:
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

  testWidgets('macOS native shell renders MacosWindow + Sidebar',
      (WidgetTester tester) async {
    app.main();

    // Boot can take a while (DB open, dictionary preload). Pump until the
    // native MacosWindow shell appears, up to 90s.
    bool shell = false;
    for (int i = 0; i < 180; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(MacosWindow).evaluate().isNotEmpty) {
        shell = true;
        break;
      }
    }
    expect(shell, isTrue,
        reason: 'MacosWindow should render within 90s on macOS.');

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

    // Navigate to Settings via the sidebar (its item uses Icons.tune_outlined)
    // and capture the native settings controls (MacosSwitch / MacosSlider).
    final Finder settingsItem = find.byWidgetPredicate(
        (Widget w) => w is MacosIcon && w.icon == Icons.tune);
    if (settingsItem.evaluate().isNotEmpty) {
      await tester.tap(settingsItem.first, warnIfMissed: false);
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _captureLargestBoundary(tester, '$tmp/macos_settings.png');
      debugPrint('[test] captured macos_settings');

      // Drill into a settings destination that has toggles ("系统"/System) to
      // capture the native MacosSwitch controls. Locale on the build Mac is zh.
      final Finder systemDest = find.text('系统');
      if (systemDest.evaluate().isNotEmpty) {
        await tester.tap(systemDest.first, warnIfMissed: false);
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
        await _captureLargestBoundary(tester, '$tmp/macos_settings_detail.png');
        debugPrint('[test] captured macos_settings_detail');
      } else {
        debugPrint('[test] 系统 destination not found');
      }
    } else {
      debugPrint('[test] settings sidebar item not found; home-only capture');
    }

    // Navigate to the Dictionary tab (Icons.search_outlined) to capture the
    // native MacosTextField search field.
    final Finder dictItem = find.byWidgetPredicate(
        (Widget w) => w is MacosIcon && w.icon == Icons.search);
    if (dictItem.evaluate().isNotEmpty) {
      await tester.tap(dictItem.first, warnIfMissed: false);
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _captureLargestBoundary(tester, '$tmp/macos_dict.png');
      debugPrint('[test] captured macos_dict');
    }
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
