import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Source-scan guards for TODO-959 / BUG-476 (迁移重启新进程冷启动黑屏).
///
/// The data-root migration restarts the app: a detached new process is started
/// with `--fushi-restarted` and the old process calls `exit(0)`. Between the
/// old process exiting and the new process drawing its first Flutter frame
/// there used to be a black/undefined window:
///   1. The runner window class had `hbrBackground = 0` (no background brush)
///      yet was created `WS_VISIBLE`, so the empty window painted black.
///   2. The Dart `--fushi-restarted` branch only grabbed foreground, never
///      changing those black pixels.
///
/// The fix is two-pronged and native, so it cannot run on the Dart host:
///   - Direction 1: paint the empty window a non-black splash colour before
///     Flutter's first frame. BUG-1916 moved *where* that colour lives — from
///     `WNDCLASS.hbrBackground` to a per-window `backdrop_brush_` that
///     `WM_ERASEBKGND` paints with — because the class brush also erased the
///     surface underneath the Flutter view on every resize. The invariant here
///     is unchanged (「首帧前不是黑的」); only the mechanism moved, so the
///     assertions below follow the mechanism instead of pinning the old one.
///   - Direction 2: the restarted process creates its window hidden (no
///     WS_VISIBLE) and Dart shows it after the first frame, with a fallback
///     show in catch so it can never stay permanently invisible.
///
/// These guards pin that load-bearing wiring; a refactor that silently drops
/// any of it would re-introduce the cold-start black window.
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

  group('TODO-959 direction 1: non-black splash fill before the first frame',
      () {
    test('the window class no longer uses a bare hbrBackground = 0', () {
      // The classic Flutter runner black-window default. Must be replaced by a
      // solid brush (any whitespace around the 0 still counts as the bug).
      final RegExp bare = RegExp(r'hbrBackground\s*=\s*0\s*;');
      expect(bare.hasMatch(cpp), isFalse,
          reason: 'hbrBackground = 0 leaves the first-frame window black.');
    });

    test('a splash background color constant is defined and painted before the '
        'first Flutter frame', () {
      expect(cpp.contains('kSplashBackgroundColor'), isTrue,
          reason: 'splash brush color must be a named constant.');
      // BUG-1916: the brush moved off the window class onto the window
      // instance. Deliberately do NOT require `window_class.hbrBackground =
      // CreateSolidBrush(...)` any more — `win_resize_backdrop_guard_test.dart`
      // asserts the exact opposite (the class must own no brush, or every
      // resize erases the surface under the Flutter view teal). Two guards
      // demanding opposite things about one line is how BUG-1914 happened.
      expect(
          cpp.contains(
              'backdrop_brush_(CreateSolidBrush(kSplashBackgroundColor))'),
          isTrue,
          reason: 'the per-window backdrop brush must start as the splash '
              'colour, or the pre-first-frame window is undefined/black.');
      // ...and something must actually paint with it. Dropping the class brush
      // is only safe *because* WM_ERASEBKGND paints the instance brush itself:
      // an earlier draft handled the same case with `if (child_content_ !=
      // nullptr) return TRUE; break;`, which with a null class brush falls
      // through to a DefWindowProc that paints nothing — the TODO-959 black
      // window, straight back.
      final int eraseAt = cpp.indexOf('case WM_ERASEBKGND:');
      expect(eraseAt, isNonNegative,
          reason: 'with no class brush, the window must erase itself.');
      final int nextCaseAt = cpp.indexOf('case WM_ACTIVATE:', eraseAt);
      expect(nextCaseAt, greaterThan(eraseAt));
      final String eraseBody = cpp.substring(eraseAt, nextCaseAt);
      expect(eraseBody.contains('PaintBackdrop('), isTrue,
          reason: 'WM_ERASEBKGND must paint the splash/backdrop brush.');
      expect(eraseBody.contains('break;'), isFalse,
          reason: 'falling through to DefWindowProc with no class brush '
              'leaves the cold-start window unpainted (TODO-959).');
    });
  });

  group('TODO-959 direction 2: restarted process creates a hidden window', () {
    test('runner detects the --fushi-restarted marker', () {
      expect(cpp.contains('--fushi-restarted'), isTrue);
      expect(cpp.contains('IsRestartedProcess('), isTrue,
          reason: 'runner must independently detect the restart marker.');
    });

    test('the restarted process omits WS_VISIBLE at create time', () {
      // The restarted-hidden branch must select a style WITHOUT WS_VISIBLE,
      // and CreateWindowEx must use the computed window_style (not a hardcoded
      // WS_OVERLAPPEDWINDOW | WS_VISIBLE).
      expect(cpp.contains('restarted_hidden'), isTrue);
      final int decide = cpp.indexOf('const DWORD window_style =');
      expect(decide, isNonNegative,
          reason: 'window style must be computed from restarted_hidden.');
      final int created = cpp.indexOf('CreateWindowEx(', decide);
      expect(created, isNonNegative);
      final int call = cpp.indexOf('window_style', created);
      expect(call, greaterThan(created),
          reason: 'CreateWindowEx must consume the computed window_style.');
      // The non-restarted style still carries WS_VISIBLE so a normal launch is
      // never stuck invisible.
      expect(cpp.contains('WS_OVERLAPPEDWINDOW | WS_VISIBLE'), isTrue,
          reason: 'normal launch must keep WS_VISIBLE.');
    });

    test('test-hidden mode keeps WS_VISIBLE (only non-test restart hides)', () {
      // restarted_hidden must be gated on !hidden so the integration-test
      // off-screen mode (which relies on WS_VISIBLE to keep rendering) is
      // unaffected.
      expect(cpp.contains('!hidden && IsRestartedProcess()'), isTrue,
          reason: 'only a non-test restarted process hides its window.');
    });
  });

  group('TODO-959 Dart shows the restarted window after the first frame', () {
    test('the restart branch shows + focuses the window', () {
      final int branch =
          mainDart.indexOf('DesktopLifecycleService.restartMarkerArg');
      expect(branch, isNonNegative);
      // Scope to a window after the branch condition.
      final String body = mainDart.substring(branch, branch + 1200);
      expect(body.contains('windowManager.show()'), isTrue,
          reason: 'the restarted (hidden) window must be shown.');
      expect(body.contains('windowManager.focus()'), isTrue);
    });

    test('a catch-side fallback show prevents a permanently invisible window',
        () {
      final int branch =
          mainDart.indexOf('DesktopLifecycleService.restartMarkerArg');
      expect(branch, isNonNegative);
      final String body = mainDart.substring(branch, branch + 1200);
      // There must be a second windowManager.show() inside the catch so a
      // focus() failure cannot leave the hidden window unshown.
      final int firstShow = body.indexOf('windowManager.show()');
      final int catchAt = body.indexOf('catch');
      expect(catchAt, greaterThan(firstShow));
      final int fallbackShow = body.indexOf('windowManager.show()', catchAt);
      expect(fallbackShow, greaterThan(catchAt),
          reason: 'catch must retry show() so the window is never stuck '
              'invisible.');
    });
  });
}
