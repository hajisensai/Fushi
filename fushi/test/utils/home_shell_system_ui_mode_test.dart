import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';

/// TODO-097 / BUG-181 + BUG-2894 守卫：首页外壳的系统 UI 模式。
///
/// Android：`manual` + 只开 bottom——隐藏状态栏（竖屏时挤压右上角动作图标），
/// 保留导航/手势栏；`manual` 同时清掉视频页留下的 IMMERSIVE_STICKY。
/// 其它平台：先显式显示全部 overlay，再 edge-to-edge（3.44 的 edgeToEdge 不清
/// sticky 沉浸）。host runner 上 [Platform.isAndroid] 为 false，故行为测试只覆盖
/// 非 Android 分支；Android 分支的具体模式用源码守卫锁定。
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
      'home-shell helper hides the Android status bar, keeps the nav bar',
      () {
        final String fn = bodyOf(
          utils,
          'Future<void> setHomeShellSystemUiMode()',
        );
        final int androidAt = fn.indexOf('if (Platform.isAndroid) {');
        expect(androidAt, isNonNegative, reason: 'Android branch is required');
        final int returnAt = fn.indexOf('return;', androidAt);
        expect(returnAt, isNonNegative, reason: 'Android branch must return');
        final String android = fn.substring(androidAt, returnAt);
        expect(android, contains('SystemUiMode.manual'));
        expect(
          android,
          contains('overlays: <SystemUiOverlay>[SystemUiOverlay.bottom]'),
        );
        expect(
          android.contains('SystemUiOverlay.top') ||
              android.contains('SystemUiOverlay.values'),
          isFalse,
          reason: 'enabling the top overlay would re-show the status bar',
        );

        final String rest = fn.substring(returnAt);
        expect(rest, contains('overlays: SystemUiOverlay.values'));
        expect(
          rest.indexOf('SystemUiMode.manual'),
          lessThan(rest.indexOf('SystemUiMode.edgeToEdge')),
          reason: 'non-Android must clear sticky immersion before edge-to-edge',
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
