import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（TODO-1232 / BUG-597）：Android 渲染后端默认由 native
/// `MainActivity.getFlutterShellArgs` 在**引擎启动那一刻**（Dart 尚不存在）决定，是权威
/// 决策点，无法用 flutter test 直接驱动引擎后端。故用源码扫描锁死这层不变式，并保证它与
/// Dart 侧镜像 `RenderBackendService.resolveImpellerDisabled` 同默认。
///
/// 当前不变式：**未设置态默认保持 Impeller（raw==null → false）**，多数机型保住 Impeller
/// 性能；少数 Mali-G76/Android 11 类黑屏机型（BUG-597）改由播放器设置面板可发现的一键
/// 「切 Skia 并重启」入口显式降级，而非全局默认翻 Skia。此守卫防有人把默认改回
/// `: true`（=又把全体 Android 用户翻到 Skia，牺牲多数人性能）。
void main() {
  final File mainActivity = File(
    'android/app/src/main/java/app/hibiki/reader/MainActivity.java',
  );

  late final String src;

  setUpAll(() {
    expect(mainActivity.existsSync(), isTrue,
        reason: 'MainActivity.java 应存在: ${mainActivity.path}');
    src = mainActivity.readAsStringSync();
  });

  group('TODO-1232 Android 默认保持 Impeller（黑屏机型走一键切 Skia 入口）', () {
    test('getFlutterShellArgs 命中时追加 --enable-impeller=false shell arg', () {
      expect(
          src.contains('public FlutterShellArgs getFlutterShellArgs()'), isTrue,
          reason: '须重写 getFlutterShellArgs 在引擎启动前注入渲染后端选择');
      expect(src.contains('FlutterShellArgs.ARG_DISABLE_IMPELLER'), isTrue,
          reason: '关 Impeller 靠追加 ARG_DISABLE_IMPELLER（命令行值优先于 manifest 默认）');
      expect(src.contains('if (isImpellerDisabledPref())'), isTrue,
          reason: 'shell arg 是否追加由 isImpellerDisabledPref() 这个权威决策点门控');
    });

    test('isImpellerDisabledPref 未设置态回落到 false（Impeller），不是 true（Skia）', () {
      // 未被用户显式设置时保持引擎默认 Impeller（多数机型性能优先）；黑屏机型改由
      // 播放器设置面板可发现的一键「切 Skia 并重启」入口显式降级。
      expect(src.contains('return raw != null ? raw : false;'), isTrue,
          reason: '未设置（raw==null）必须回落到 false=保持 Impeller；'
              '若改回 : true 则又把全体 Android 用户翻到 Skia、牺牲多数人性能');
      // 反向守卫：绝不能再出现「未设置默认 true（全局 Skia）」的旧形状。
      expect(src.contains('return raw != null ? raw : true;'), isFalse,
          reason: '旧的全局默认 Skia 形状不得复现（会牺牲多数机型 Impeller 性能）');
    });

    test('getImpellerDisabledRawPref 用 contains() 判「未设置」返回 null（三态）', () {
      expect(
          src.contains('private Boolean getImpellerDisabledRawPref()'), isTrue,
          reason: 'raw 读取须为可空 Boolean 以表达三态（未设置/true/false）');
      expect(
          src.contains(
              'if (!prefs.contains(PreferenceKeys.RENDER_IMPELLER_DISABLED)) {'),
          isTrue,
          reason: '用 contains() 区分「未设置」与「显式设为 false」——显式选择须能压过默认');
    });

    test('render channel 把 raw 三态交给 Dart 解析（非在 native 提前定死默认）', () {
      expect(
          src.contains('result.success(getImpellerDisabledRawPref());'), isTrue,
          reason:
              'isImpellerDisabled channel 须返回 raw 三态，让 Dart 侧 helper 兜底平台默认，'
              '与 getFlutterShellArgs 的默认保持同源');
    });
  });
}
