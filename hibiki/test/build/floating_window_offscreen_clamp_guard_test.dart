import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for TODO-832 (悬浮字幕/词典浮层拖动越界 clamp). The native
/// Win32 (cpp) and Android (java) drag paths cannot run on the Dart host, so
/// these guards pin the load-bearing wiring that keeps a floating overlay from
/// being dragged or restored fully off-screen. A refactor that silently drops
/// any of these would re-introduce the "拖丢拿不回来" bug.
///
/// The algorithm itself is tested as a truth table in
/// test/platform/floating_window_bounds_test.dart (clampFloatingWindowOrigin).
void main() {
  late String cpp;
  late String header;

  const String androidRoot =
      '../hibiki/android/app/src/main/java/app/hibiki/reader';
  String readJava(String relative) =>
      File('$androidRoot/$relative').readAsStringSync();

  setUpAll(() {
    cpp = File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
    header = File('windows/runner/floating_lyric_window.h').readAsStringSync();
  });

  group('TODO-832 Windows strip off-screen clamp', () {
    test('header declares the 48dp min-visible margin + clamp helpers', () {
      expect(header.contains('kMinVisibleMarginDip = 48'), isTrue,
          reason: 'min-visible margin must be a single 48dp constant.');
      expect(header.contains('POINT ClampOriginToWorkArea('), isTrue);
      expect(
          header.contains('void ClampCurrentPositionToWindowMonitor('), isTrue);
    });

    test('the drag (WM_MOUSEMOVE) path clamps against the cursor monitor', () {
      final int move = cpp.indexOf('case WM_MOUSEMOVE:');
      expect(move, isNonNegative);
      final int leave = cpp.indexOf('case WM_MOUSELEAVE:', move);
      expect(leave, greaterThan(move));
      final String body = cpp.substring(move, leave);

      // Drag must clamp before SetWindowPos, against the monitor under the
      // cursor (so it slides across displays but can't be lost).
      expect(body.contains('MonitorFromPoint('), isTrue,
          reason: 'drag clamp must use the cursor monitor.');
      expect(body.contains('ClampOriginToWorkArea('), isTrue);
      final int clampAt = body.indexOf('ClampOriginToWorkArea(');
      final int setPosAt = body.indexOf('SetWindowPos(');
      expect(clampAt, isNonNegative);
      expect(setPosAt, greaterThan(clampAt),
          reason: 'clamp must run before the move is committed.');
    });

    test('display / DPI change fallback clamps against the WINDOW monitor', () {
      // These fire when the cursor is not necessarily over the strip, so they
      // must clamp against MonitorFromWindow, not the cursor.
      final int dpi = cpp.indexOf('case WM_DPICHANGED:');
      expect(dpi, isNonNegative);
      final int dpiEnd = cpp.indexOf('case WM_DISPLAYCHANGE:', dpi);
      expect(dpiEnd, greaterThan(dpi));
      expect(
          cpp
              .substring(dpi, dpiEnd)
              .contains('ClampCurrentPositionToWindowMonitor()'),
          isTrue,
          reason: 'WM_DPICHANGED must pull the strip back on-screen.');

      final int disp = cpp.indexOf('case WM_DISPLAYCHANGE:');
      final int dispEnd = cpp.indexOf('default:', disp);
      expect(dispEnd, greaterThan(disp));
      expect(
          cpp
              .substring(disp, dispEnd)
              .contains('ClampCurrentPositionToWindowMonitor()'),
          isTrue,
          reason: 'WM_DISPLAYCHANGE must pull the strip back on-screen.');
    });

    test('the window-monitor clamp helper uses MonitorFromWindow', () {
      final int impl = cpp.indexOf(
          'void FloatingLyricWindow::ClampCurrentPositionToWindowMonitor()');
      expect(impl, isNonNegative);
      final int end = cpp.indexOf('\n}', impl);
      expect(end, greaterThan(impl));
      final String body = cpp.substring(impl, end);
      expect(body.contains('MonitorFromWindow(hwnd_'), isTrue);
      expect(body.contains('ClampOriginToWorkArea('), isTrue);
    });
  });

  group('TODO-832 Android overlay off-screen clamp', () {
    test('BaseFloatingService declares the 48dp margin + clampToScreen', () {
      final String base = readJava('BaseFloatingService.java');
      expect(base.contains('MIN_VISIBLE_DP = 48'), isTrue,
          reason: 'min-visible margin must be a single 48dp constant.');
      expect(base.contains('protected void clampToScreen()'), isTrue);
    });

    test('ACTION_MOVE clamps before updateViewLayout', () {
      final String base = readJava('BaseFloatingService.java');
      final int move = base.indexOf('case MotionEvent.ACTION_MOVE:');
      expect(move, isNonNegative);
      final int up = base.indexOf('case MotionEvent.ACTION_UP:', move);
      expect(up, greaterThan(move));
      final String body = base.substring(move, up);

      final int clampAt = body.indexOf('clampToScreen()');
      final int updateAt = body.indexOf('updateViewLayout(');
      expect(clampAt, isNonNegative,
          reason: 'drag must clamp the new position.');
      expect(updateAt, greaterThan(clampAt),
          reason: 'clamp must run before the move is committed.');
    });

    test('setupOverlay re-clamps the restored saved position', () {
      final String base = readJava('BaseFloatingService.java');
      final int setup = base.indexOf('protected void setupOverlay()');
      expect(setup, isNonNegative);
      final int next = base.indexOf('protected WindowManager.LayoutParams '
          'createLayoutParams()');
      expect(next, greaterThan(setup));
      final String body = base.substring(setup, next);
      // Restored (possibly historically out-of-bounds) position must be clamped
      // after the first layout pass so measured dimensions are available.
      expect(body.contains('clampToScreen()'), isTrue,
          reason:
              'a saved off-screen position must be pulled back on restore.');
      expect(body.contains('rootView.post('), isTrue,
          reason: 'clamp must wait for the first layout (WRAP_CONTENT size).');
    });

    test('clampToScreen uses WindowMetrics/DisplayMetrics + fixed-width source',
        () {
      final String base = readJava('BaseFloatingService.java');
      final int impl = base.indexOf('protected void clampToScreen()');
      expect(impl, isNonNegative);
      // Slice up to dpToPx (the next method after the helpers) to scope.
      final int end = base.indexOf('protected int dpToPx(', impl);
      expect(end, greaterThan(impl));
      final String body = base.substring(impl, end);

      expect(body.contains('getCurrentWindowMetrics()'), isTrue,
          reason: 'API30+ screen bounds source.');
      expect(body.contains('getRealMetrics('), isTrue,
          reason: 'pre-API30 screen bounds fallback.');
      // Fixed-size FREE overlays (dict 300x400) take their width from
      // layoutParams immediately — a 0 first-frame measured width must not dash
      // them off-screen.
      expect(body.contains('layoutParams.width > 0'), isTrue,
          reason: 'fixed layoutParams.width is authoritative, not view '
              'measurement (Important #1).');
      // FREE clamps X, both modes clamp Y.
      expect(body.contains('DragMode.FREE'), isTrue);
    });
  });
}
