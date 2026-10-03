import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

/// 首页与媒体退页统一恢复 edge-to-edge：状态栏和导航栏保持可见。
/// 平台通道验证实际发出的模式；源码守卫验证启动与阅读器退出接线。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test(
    'home mode explicitly shows both bars before restoring edge-to-edge layout',
    () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            calls.add(call);
            return null;
          });

      await setHomeShellSystemUiMode();

      final List<MethodCall> modeCalls = calls
          .where(
            (MethodCall c) => c.method == 'SystemChrome.setEnabledSystemUIMode',
          )
          .toList();
      expect(
        modeCalls,
        hasLength(1),
        reason: 'helper must drive exactly one system-UI mode change',
      );
      expect(modeCalls.single.arguments, SystemUiMode.edgeToEdge.toString());
      expect(calls, hasLength(2));
      expect(calls.first.method, 'SystemChrome.setEnabledSystemUIOverlays');
      expect(calls.first.arguments, <String>[
        SystemUiOverlay.top.toString(),
        SystemUiOverlay.bottom.toString(),
      ]);
      expect(calls.last, same(modeCalls.single));
    },
  );

  test(
    'home mode replaces sticky video immersion with visible system bars',
    () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            calls.add(call);
            return null;
          });

      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await setHomeShellSystemUiMode();

      expect(calls.map((MethodCall call) => call.arguments), <Object>[
        SystemUiMode.immersiveSticky.toString(),
        <String>[
          SystemUiOverlay.top.toString(),
          SystemUiOverlay.bottom.toString(),
        ],
        SystemUiMode.edgeToEdge.toString(),
      ]);
    },
  );

  group('source guards', () {
    final String utils = File(
      'lib/src/utils/misc/platform_utils.dart',
    ).readAsStringSync();
    final String main = File('lib/main.dart').readAsStringSync();
    final String appModel = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();

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
      final int open = asyncAt >= 0
          ? src.indexOf('{', asyncAt)
          : src.indexOf('{', start);
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

    test(
      'home-shell helper keeps both system bars visible on every platform',
      () {
        final String fn = bodyOf(
          utils,
          'Future<void> setHomeShellSystemUiMode()',
        );
        expect(fn, contains('SystemUiMode.edgeToEdge'));
        expect(fn, contains('overlays: SystemUiOverlay.values'));
        expect(
          fn.indexOf('SystemUiMode.manual'),
          lessThan(fn.indexOf('SystemUiMode.edgeToEdge')),
        );
        expect(fn, isNot(contains('Platform.isAndroid')));
      },
    );

    test('app startup uses the home-shell helper, not bare edgeToEdge', () {
      expect(
        main,
        contains('setHomeShellSystemUiMode()'),
        reason: 'startup must route the home default through the helper',
      );
      // 启动统一从 helper 获取首页模式。
      expect(
        main.contains(
          'SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)',
        ),
        isFalse,
        reason: 'startup should call setHomeShellSystemUiMode, not edgeToEdge',
      );
    });

    test('closeMedia returns to the home-shell mode, not bare edgeToEdge', () {
      final String fn = bodyOf(appModel, 'Future<void> closeMedia(');
      expect(
        fn,
        contains('setHomeShellSystemUiMode()'),
        reason: 'exiting media must restore the visible home system bars',
      );
      expect(
        fn.contains(
          'SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)',
        ),
        isFalse,
        reason: 'closeMedia should call the helper, not bare edgeToEdge',
      );
    });
  });
}
