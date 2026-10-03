import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

/// TODO-097 / BUG-181 + BUG-2925 守卫：首页外壳的系统 UI 模式。
///
/// 所有平台（含 Android，用户 2026-10-04 反转 TODO-097：Android 首页显示状态栏）
/// 走同一条路径：先 `manual` 显式显示全部 overlay（清掉视频页留下的
/// IMMERSIVE_STICKY，3.44 的 edgeToEdge 不清），再 edge-to-edge。host runner 上
/// [Platform.isAndroid] 为 false，所以「没有平台分支」用源码守卫锁定，保证
/// 行为测试覆盖的就是 Android 真机走的那条路径。
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
      'home-shell helper has no per-platform branch (TODO-097 reversed)',
      () {
        final String fn = bodyOf(
          utils,
          'Future<void> setHomeShellSystemUiMode()',
        );
        expect(
          fn.contains('Platform.'),
          isFalse,
          reason:
              'a platform branch would let Android diverge from the path the '
              'behaviour tests above cover (e.g. hiding the status bar again)',
        );
        expect(fn, contains('overlays: SystemUiOverlay.values'));
        expect(
          fn.indexOf('SystemUiMode.manual'),
          lessThan(fn.indexOf('SystemUiMode.edgeToEdge')),
          reason: 'must clear sticky immersion before edge-to-edge',
        );
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
        reason: 'exiting media must restore the home-shell system UI mode',
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
