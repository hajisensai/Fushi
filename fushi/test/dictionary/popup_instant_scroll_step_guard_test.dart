// 查词弹窗「瞬时滚动」步长可调（lookup.popup_instant_scroll_{wheel,touch}_step）。
//
// BUG-2284 / BUG-2415 把滚轮 / 触摸的瞬跳步长写死成视口 × 0.5 / × 0.25。墨水屏尺寸与
// 刷新特性差异大，本轮改成两个用户旋钮（滚轮一格跳多少 / 手指滑满多少跳一步），并让
// 开关与旋钮一起经 ReaderPlacement 出现在阅读器快捷设置的查词段。
//
// 两层：
//   ① 行为级——Node 真执行 popup.js 的 wheel 监听器与 popupEinkTouchStep（见同名 .js），
//      断言 scrollBy 实际距离随步长变化、非法值回退、越界夹紧、冷却不变。无 node 时 skip。
//   ② 源码级——「偏好 → 注入 / theme 下发 → 三份 popup.js 读取」每一环的接线，以及设置
//      项的 ReaderPlacement / visible 门（单测层没有真 WebView，接线只能钉存在性）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const List<String> popupCopies = <String>[
    'assets/popup/popup.js', // in-app 渲染器（真源）
    'assets/browser_extension/vendor/popup.js', // 扩展 bundle 镜像
    '../tools/browser-extension/vendor/popup.js', // 扩展 tools 镜像
  ];

  test('popup instant-scroll step (executes popup.js via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final File jsTest =
        File('test/dictionary/popup_instant_scroll_step_test.js');
    expect(jsTest.existsSync(), isTrue,
        reason: 'behavior harness ${jsTest.path} must exist');
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );
    expect(
      result.exitCode,
      0,
      reason: 'popup instant-scroll step JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  group('popup instant-scroll step wiring guard', () {
    for (final String path in popupCopies) {
      test('[$path] 滚轮 / 触摸两条瞬时分支都读用户步长并回退常量', () {
        final String src = File(path).readAsStringSync();
        expect(src, contains('function popupEinkStepFraction('));

        // 滚轮：瞬时分支内用 popupEinkStepFraction 解析步长，常量只作回退。
        final int instantAt =
            src.indexOf('if (window.__fushiPopupInstantScroll)');
        final int factorAt = src.indexOf('const factor = (coarseMouseNotch');
        expect(instantAt, greaterThanOrEqualTo(0));
        expect(factorAt, greaterThan(instantAt));
        final String wheelBranch = src.substring(instantAt, factorAt);
        expect(
          wheelBranch,
          contains('popupEinkStepFraction(\n'
              '            window.__fushiPopupInstantScrollWheelStep, '
              'POPUP_EINK_WHEEL_VIEWPORT_FRACTION)'),
          reason: '滚轮步长必须来自用户全局、缺省回退原常量',
        );
        expect(
          wheelBranch,
          contains('extent * wheelFraction * wheelSpeed'),
          reason: '用户步长仍乘滚轮速度倍率（同一个「滚轮速度」旋钮缩放两种模式）',
        );
        expect(
          wheelBranch,
          contains('Math.min(extent, extent * wheelFraction * wheelSpeed)'),
          reason: '仍封顶一屏——永不一步跳过整屏内容',
        );

        // 触摸：popupEinkTouchStep 同法。
        final int touchAt = src.indexOf('function popupEinkTouchStep(');
        expect(touchAt, greaterThanOrEqualTo(0));
        final String touchFn = src.substring(
          touchAt,
          src.indexOf('\n}\n', touchAt),
        );
        expect(
          touchFn,
          contains('popupEinkStepFraction(\n'
              '        window.__fushiPopupInstantScrollTouchStep, '
              'POPUP_EINK_TOUCH_VIEWPORT_FRACTION)'),
        );
        expect(touchFn, contains('Math.min(extent, extent * touchFraction)'));
        expect(
          touchFn.contains('wheelSpeed'),
          isFalse,
          reason: '触摸是量化的 1:1 跟手，不吃滚轮速度',
        );
      });
    }

    test('in-app 注入面下发两个步长并进静态段 memo 命中判据', () {
      final String dart = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(
        dart,
        contains(r'window.__fushiPopupInstantScrollWheelStep = '
            r'${appModel.popupInstantScrollWheelStep};'),
      );
      expect(
        dart,
        contains(r'window.__fushiPopupInstantScrollTouchStep = '
            r'${appModel.popupInstantScrollTouchStep};'),
      );
      // BUG-717 ③：静态段有 memo，改设置必须让缓存失效，否则拖完滑杆弹窗不跟。
      expect(
        dart,
        contains('cached.popupInstantScrollWheelStep ==\n'
            '          appModel.popupInstantScrollWheelStep &&'),
      );
      expect(
        dart,
        contains('cached.popupInstantScrollTouchStep ==\n'
            '          appModel.popupInstantScrollTouchStep &&'),
      );
    });

    test('扩展 theme 通道下发滚轮步长，content.js / side-panel.js 设同名全局', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(
        appModel,
        contains("'--fushi-instant-scroll-wheel-step':\n"
            '          popupInstantScrollWheelStep.toStringAsFixed(3),'),
        reason: '扩展弹窗只有 theme 这一条下发通道（与 --fushi-instant-scroll 同法）',
      );
      for (final String path in <String>[
        '../tools/browser-extension/content.js',
        'assets/browser_extension/content.js',
        '../tools/browser-extension/side-panel.js',
        'assets/browser_extension/side-panel.js',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(src, contains("theme['--fushi-instant-scroll-wheel-step']"),
            reason: '$path 必须读 theme 下发的滚轮步长');
        expect(src, contains('window.__fushiPopupInstantScrollWheelStep ='),
            reason: '$path 必须设 popup.js 读的同名全局');
      }
    });

    test('偏好层：两个 key 登记、clamp 到 [0.1, 1]、默认与原常量一致', () {
      final String keys =
          File('lib/src/models/preference_keys.dart').readAsStringSync();
      expect(keys, contains("'popup_instant_scroll_wheel_step',"));
      expect(keys, contains("'popup_instant_scroll_touch_step',"));
      final String repo =
          File('lib/src/models/preferences_repository.dart').readAsStringSync();
      expect(repo, contains('kPopupInstantScrollWheelStepDefault = 0.5;'));
      expect(repo, contains('kPopupInstantScrollTouchStepDefault = 0.25;'));
      expect(repo, contains('kPopupInstantScrollStepMin = 0.1;'));
      expect(repo, contains('kPopupInstantScrollStepMax = 1.0;'));
    });

    test('设置项：开关 + 两滑杆都进阅读器快捷设置查词段，滑杆仅开关开启时可见', () {
      final String src = File(
        'lib/src/settings/settings_schema_lookup.dart',
      ).readAsStringSync();
      final int switchAt = src.indexOf("id: 'lookup.popup_instant_scroll',");
      final int wheelAt =
          src.indexOf("id: 'lookup.popup_instant_scroll_wheel_step',");
      final int touchAt =
          src.indexOf("id: 'lookup.popup_instant_scroll_touch_step',");
      expect(switchAt, greaterThanOrEqualTo(0));
      expect(wheelAt, greaterThan(switchAt));
      expect(touchAt, greaterThan(wheelAt));
      final String switchBody = src.substring(switchAt, wheelAt);
      final String wheelBody = src.substring(wheelAt, touchAt);
      final int afterAt =
          src.indexOf("id: 'lookup.popup_bottom_docked',", touchAt);
      expect(afterAt, greaterThan(touchAt));
      final String touchBody = src.substring(touchAt, afterAt);
      for (final String body in <String>[switchBody, wheelBody, touchBody]) {
        expect(
          body,
          contains('reader: const ReaderPlacement(group: ReaderGroup.lookup,'),
          reason: '用户在书里查词时才发现步长不合手，不该退出阅读器去翻全局设置',
        );
      }
      for (final String body in <String>[wheelBody, touchBody]) {
        expect(
          body,
          contains('visible: (SettingsContext settingsContext) =>\n'
              '                settingsContext.appModel.popupInstantScroll,'),
          reason: '开关关着时步长无意义，不展示',
        );
        expect(body,
            contains('min: PreferencesRepository.kPopupInstantScrollStepMin'));
        expect(body,
            contains('max: PreferencesRepository.kPopupInstantScrollStepMax'));
      }
      expect(wheelBody, contains('setPopupInstantScrollWheelStep(value)'));
      expect(touchBody, contains('setPopupInstantScrollTouchStep(value)'));
    });
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // try next candidate
    }
  }
  return null;
}
