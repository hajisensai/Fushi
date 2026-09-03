import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

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
      '../fushi/android/app/src/main/java/app/fushi/reader';
  String readJava(String relative) =>
      File('$androidRoot/$relative').readAsStringSync();

  /// 取 `signature { ... }` 的函数体（花括号配对）。语料已掩注释与串内容，
  /// 注释里的花括号与字符串里的花括号都不会带偏配对。
  String functionBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, isNonNegative, reason: 'missing $signature');
    final int open = source.indexOf('{', start);
    expect(open, isNonNegative, reason: 'no opening brace after $signature');
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  setUpAll(() {
    // 掩注释：BUG-1926 的修复注释在拖动分支里就写着 SetWindowPos / MoveBodyTo，
    // 不掩的话下面的要求型断言可以被注释单独满足。等长掩码，下标语义不变。
    cpp = maskCommentsAndStrings(
        File('windows/runner/floating_lyric_window.cpp').readAsStringSync());
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
      // BUG-1926 起，「移动正文窗」收成了唯一原语 MoveBodyTo（TODO-832 的钳制 +
      // BUG-951 的穿透态顶栏同步都在里面）。此前拖动分支把钳制逻辑抄了第二份，
      // 而那一份漏了收尾的顶栏同步 —— 穿透态顶栏整段拖动都掉队。所以这条守卫跟着
      // 原语走：拖动分支必须委托给它，钳制语义在原语里钉。不变式本身没变。
      final int move = cpp.indexOf('case WM_MOUSEMOVE:');
      expect(move, isNonNegative);
      final int leave = cpp.indexOf('case WM_MOUSELEAVE:', move);
      expect(leave, greaterThan(move));
      expect(cpp.substring(move, leave).contains('MoveBodyTo('), isTrue,
          reason: '拖动必须走 MoveBodyTo 这条唯一原语，不能再自己抄一份钳制。');

      final String primitive = functionBody(
          cpp, 'void FloatingLyricWindow::MoveBodyTo(int x, int y)');
      // Drag must clamp before SetWindowPos, against the monitor under the
      // cursor (so it slides across displays but can't be lost).
      expect(primitive.contains('MonitorFromPoint('), isTrue,
          reason: 'drag clamp must use the cursor monitor.');
      final int clampAt = primitive.indexOf('ClampOriginToWorkArea(');
      final int setPosAt = primitive.indexOf('SetWindowPos(');
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
