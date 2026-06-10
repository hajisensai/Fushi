import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/utils.dart';

/// TODO-097 守卫：手机竖屏时常驻系统状态栏挤压 Hibiki 右上角动作图标。
///
/// 修复策略：home/menu 外壳（书架/视频/查词/设置）的系统 UI 模式从纯
/// `edgeToEdge`（状态栏可见）改为 [setHomeShellSystemUiMode]——Android 隐藏状态栏、
/// 保留导航/手势栏；iOS/桌面保持 edge-to-edge。打开书/视频仍走 immersiveSticky，
/// 退出经 AppModel.closeMedia 调回本 helper。
///
/// 真机断言无法在 host 跑（[Platform.isAndroid] 在 Windows/Linux test runner 为
/// false），故：① 行为测试只验非 Android 分支真的发了一次
/// `SystemChrome.setEnabledSystemUIMode`（platform channel 拦截）；② Android 隐藏
/// 状态栏的具体模式 + 两个调用点用源码扫描守卫锁定（任一退回 → 红）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('setHomeShellSystemUiMode emits a single setEnabledSystemUIMode call',
      () async {
    final List<MethodCall> calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (MethodCall call) async {
      calls.add(call);
      return null;
    });

    await setHomeShellSystemUiMode();

    final List<MethodCall> modeCalls = calls
        .where(
            (MethodCall c) => c.method == 'SystemChrome.setEnabledSystemUIMode')
        .toList();
    expect(modeCalls, hasLength(1),
        reason: 'helper must drive exactly one system-UI mode change');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('source guards', () {
    final String utils =
        File('lib/src/utils/misc/platform_utils.dart').readAsStringSync();
    final String main = File('lib/main.dart').readAsStringSync();
    final String appModel =
        File('lib/src/models/app_model.dart').readAsStringSync();

    // Returns the `{ ... }` body of a function/method. Anchors on the first
    // `{` that starts a *block* after the signature: for a multi-line named-
    // parameter list (`closeMedia({ required ... }) async {`) we skip the
    // parameter brace and use the `async {` block, so the captured span is the
    // real body, not the parameter list.
    String bodyOf(String src, String signature) {
      final int start = src.indexOf(signature);
      expect(start, isNonNegative, reason: 'missing $signature');
      // Prefer the `async {` block when present (covers async methods whose
      // signature may carry a `{ ... }` named-parameter list first).
      final int asyncAt = src.indexOf(') async {', start);
      final int open =
          asyncAt >= 0 ? src.indexOf('{', asyncAt) : src.indexOf('{', start);
      int depth = 0;
      for (int i = open; i < src.length; i++) {
        if (src[i] == '{') depth++;
        if (src[i] == '}') {
          depth--;
          if (depth == 0) return src.substring(open, i + 1);
        }
      }
      fail('unbalanced braces after $signature');
    }

    test('home-shell helper hides the Android status bar, keeps the nav bar',
        () {
      final String fn =
          bodyOf(utils, 'Future<void> setHomeShellSystemUiMode()');
      // Android branch: manual mode with ONLY the bottom (nav/gesture) overlay.
      expect(fn, contains('Platform.isAndroid'));
      expect(fn, contains('SystemUiMode.manual'));
      expect(fn, contains('SystemUiOverlay.bottom'));
      // The status bar (top overlay) must NOT be re-enabled in the Android path.
      expect(fn.contains('SystemUiOverlay.top'), isFalse,
          reason: 'keeping the top overlay would re-show the status bar');
      // Non-Android fallback stays edge-to-edge.
      expect(fn, contains('SystemUiMode.edgeToEdge'));
    });

    test('app startup uses the home-shell helper, not bare edgeToEdge', () {
      expect(main, contains('setHomeShellSystemUiMode()'),
          reason: 'startup must route the home default through the helper');
      // The old bare `edgeToEdge` mobile-startup call must be gone so the home
      // shell does not re-show the status bar at launch.
      expect(
        main.contains(
            'SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)'),
        isFalse,
        reason: 'startup should call setHomeShellSystemUiMode, not edgeToEdge',
      );
    });

    test('closeMedia returns to the home-shell mode, not bare edgeToEdge', () {
      final String fn = bodyOf(appModel, 'Future<void> closeMedia(');
      expect(fn, contains('setHomeShellSystemUiMode()'),
          reason:
              'exiting media must restore the status-bar-hidden home shell');
      expect(
        fn.contains(
            'SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)'),
        isFalse,
        reason: 'closeMedia should call the helper, not bare edgeToEdge',
      );
    });
  });
}
