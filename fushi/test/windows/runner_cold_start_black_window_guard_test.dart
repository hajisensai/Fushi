import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Guards the native backdrop and first-frame startup presentation contract.
void main() {
  late String cpp;
  late String mainDart;

  setUpAll(() {
    // Comments masked (blanked in place, offsets preserved): the runner's own
    // comments quote the code shapes these guards look for — the WM_ERASEBKGND
    // comment literally spells out the superseded `return TRUE; break;` form,
    // which an unmasked `contains('break;')` happily matches.
    cpp = maskComments(
      File('windows/runner/win32_window.cpp').readAsStringSync(),
    );
    mainDart = maskComments(File('lib/main.dart').readAsStringSync());
  });

  group('TODO-959 direction 1: non-black splash fill before the first frame', () {
    test('the window class no longer uses a bare hbrBackground = 0', () {
      // The classic Flutter runner black-window default. Must be replaced by a
      // solid brush (any whitespace around the 0 still counts as the bug).
      final RegExp bare = RegExp(r'hbrBackground\s*=\s*0\s*;');
      expect(
        bare.hasMatch(cpp),
        isFalse,
        reason: 'hbrBackground = 0 leaves the first-frame window black.',
      );
    });

    test('a splash background color constant is defined and painted before the '
        'first Flutter frame', () {
      expect(
        cpp.contains('kInitialBackdropColor'),
        isTrue,
        reason: 'splash brush color must be a named constant.',
      );
      // BUG-1916: the brush moved off the window class onto the window
      // instance. Deliberately do NOT require `window_class.hbrBackground =
      // CreateSolidBrush(...)` any more — `win_resize_backdrop_guard_test.dart`
      // asserts the exact opposite (the class must own no brush, or every
      // resize erases the surface under the Flutter view teal). Two guards
      // demanding opposite things about one line is how BUG-1914 happened.
      expect(
        cpp.contains(
          'backdrop_brush_(CreateSolidBrush(kInitialBackdropColor))',
        ),
        isTrue,
        reason:
            'the per-window backdrop brush must start as the splash '
            'colour, or the pre-first-frame window is undefined/black.',
      );
      // ...and something must actually paint with it. Dropping the class brush
      // is only safe *because* WM_ERASEBKGND paints the instance brush itself:
      // an earlier draft handled the same case with `if (child_content_ !=
      // nullptr) return TRUE; break;`, which with a null class brush falls
      // through to a DefWindowProc that paints nothing — the TODO-959 black
      // window, straight back.
      final int eraseAt = cpp.indexOf('case WM_ERASEBKGND:');
      expect(
        eraseAt,
        isNonNegative,
        reason: 'with no class brush, the window must erase itself.',
      );
      final int nextCaseAt = cpp.indexOf('case WM_ACTIVATE:', eraseAt);
      expect(nextCaseAt, greaterThan(eraseAt));
      final String eraseBody = cpp.substring(eraseAt, nextCaseAt);
      expect(
        eraseBody.contains('PaintBackdrop('),
        isTrue,
        reason: 'WM_ERASEBKGND must paint the splash/backdrop brush.',
      );
      expect(
        eraseBody.contains('break;'),
        isFalse,
        reason:
            'falling through to DefWindowProc with no class brush '
            'leaves the cold-start window unpainted (TODO-959).',
      );
    });
  });

  group('startup window stays hidden until a usable frame is rasterized', () {
    test('normal launches omit WS_VISIBLE while test windows keep rendering', () {
      final int decide = cpp.indexOf('const DWORD window_style =');
      final int created = cpp.indexOf('CreateWindowEx(', decide);
      expect(decide, isNonNegative);
      expect(created, greaterThan(decide));
      final String style = cpp.substring(decide, created);
      expect(
        style,
        contains(
          '(hidden ? (WS_OVERLAPPEDWINDOW | WS_VISIBLE) : WS_OVERLAPPEDWINDOW)',
        ),
      );
      expect(cpp.indexOf('window_style', created), greaterThan(created));
    });

    test('Dart reveals and focuses only after the first usable frame', () {
      final int start = mainDart.indexOf('void _scheduleStartupFrameRelease()');
      final int end = mainDart.indexOf(
        'void _scheduleInitialThemeAnimationRestore()',
        start,
      );
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final String body = mainDart.substring(start, end);
      final int allow = body.indexOf('binding.allowFirstFrame()');
      final int raster = body.indexOf(
        'await binding.waitUntilFirstFrameRasterized',
      );
      final int show = body.indexOf('await windowManager.show()');
      final int focus = body.indexOf('await windowManager.focus()');
      expect(allow, isNonNegative);
      expect(raster, greaterThan(allow));
      expect(show, greaterThan(raster));
      expect(focus, greaterThan(show));
      expect(
        body.indexOf('try {', show),
        lessThan(focus),
        reason: 'focus failure must be isolated after show succeeds',
      );
      expect(mainDart, contains('binding.deferFirstFrame()'));
      expect(mainDart, contains('appModel.initError != null'));
      expect(mainDart, contains('_loadingTimedOut'));
    });

    test('a failed release still allows the frame once and shows the window',
        () {
      final int start = mainDart.indexOf('Future<void> _releaseStartupFrame()');
      final int end = mainDart.indexOf(
        'Future<void> _revealStartupWindow()',
        start,
      );
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final String body = mainDart.substring(start, end);
      final int catchAt = body.indexOf('} catch (e) {');
      expect(catchAt, isNonNegative);
      final String catchBody = body.substring(catchAt);
      // allowFirstFrame() may be called once per deferFirstFrame(); the catch
      // only re-allows when the try never got that far.
      expect(catchBody, contains('if (!firstFrameAllowed)'));
      expect(catchBody, contains('binding.allowFirstFrame()'));
      // Without this the hidden window could stay invisible forever.
      expect(catchBody, contains('await _revealStartupWindowFallback()'),
          reason: 'catch must still reveal so the window is never stuck '
              'invisible');
      final int fbStart =
          mainDart.indexOf('Future<void> _revealStartupWindowFallback()');
      expect(fbStart, isNonNegative);
      final String fb = mainDart.substring(fbStart, fbStart + 400);
      expect(fb, contains('await _revealStartupWindow()'));
      expect(fb, contains('catch'));
    });

    test('startup placement batches intermediate child sizes', () {
      expect(
        cpp,
        contains('child_content_ == nullptr || startup_window_preparation_'),
      );
      final int start = cpp.indexOf(
        'void Win32Window::EndStartupWindowPreparation()',
      );
      final int end = cpp.indexOf(
        'void Win32Window::ArmStuckDeferralWatchdog()',
        start,
      );
      final String body = cpp.substring(start, end);
      expect(
        body.indexOf('startup_window_preparation_ = false'),
        lessThan(body.indexOf('SyncChildToClientArea()')),
      );
      expect(
        mainDart,
        contains('WindowCaptionChannel.beginStartupWindowPreparation()'),
      );
      expect(mainDart, contains('finally {'));
      expect(
        mainDart,
        contains('WindowCaptionChannel.endStartupWindowPreparation()'),
      );
    });
  });
}
