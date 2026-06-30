import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-scan guards for TODO-959 / BUG-476 (迁移重启新进程冷启动黑屏).
///
/// The data-root migration restarts the app: a detached new process is started
/// with `--hibiki-restarted` and the old process calls `exit(0)`. Between the
/// old process exiting and the new process drawing its first Flutter frame
/// there used to be a black/undefined window:
///   1. The runner window class had `hbrBackground = 0` (no background brush)
///      yet was created `WS_VISIBLE`, so the empty window painted black.
///   2. The Dart `--hibiki-restarted` branch only grabbed foreground, never
///      changing those black pixels.
///
/// The fix is two-pronged and native, so it cannot run on the Dart host:
///   - Direction 1: give the window class a non-black splash brush.
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
    cpp = File('windows/runner/win32_window.cpp').readAsStringSync();
    mainDart = File('lib/main.dart').readAsStringSync();
  });

  group('TODO-959 direction 1: non-black window-class background brush', () {
    test('the window class no longer uses a bare hbrBackground = 0', () {
      // The classic Flutter runner black-window default. Must be replaced by a
      // solid brush (any whitespace around the 0 still counts as the bug).
      final RegExp bare = RegExp(r'hbrBackground\s*=\s*0\s*;');
      expect(bare.hasMatch(cpp), isFalse,
          reason: 'hbrBackground = 0 leaves the first-frame window black.');
    });

    test('a splash background color constant is defined and used as the brush',
        () {
      expect(cpp.contains('kSplashBackgroundColor'), isTrue,
          reason: 'splash brush color must be a named constant.');
      // Direction 1: the window class brush must be a CreateSolidBrush of that
      // color, not 0.
      expect(
          cpp.contains(
              'window_class.hbrBackground = CreateSolidBrush(kSplashBackgroundColor)'),
          isTrue,
          reason: 'window class must paint a non-black splash brush.');
    });
  });

  group('TODO-959 direction 2: restarted process creates a hidden window', () {
    test('runner detects the --hibiki-restarted marker', () {
      expect(cpp.contains('--hibiki-restarted'), isTrue);
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
