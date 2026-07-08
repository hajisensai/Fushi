import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（TODO-1232 / BUG-597）：Android 视频黑屏的根治手段是「默认关 Impeller
/// 走 Skia」——该默认由 native `MainActivity.getFlutterShellArgs` 在**引擎启动那一刻**
/// （Dart 尚不存在）决定，是权威决策点，无法用 flutter test 直接驱动引擎后端。故用源码
/// 扫描锁死这层不变式，防有人把 Android 默认悄悄翻回 Impeller（=视频又全黑），并保证它
/// 与 Dart 侧镜像 `RenderBackendService.resolveImpellerDisabled` 同默认。
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

  group('TODO-1232 Android 默认走 Skia（关 Impeller）', () {
    test('getFlutterShellArgs 命中时追加 --enable-impeller=false shell arg', () {
      expect(
          src.contains('public FlutterShellArgs getFlutterShellArgs()'), isTrue,
          reason: '须重写 getFlutterShellArgs 在引擎启动前注入渲染后端选择');
      expect(src.contains('FlutterShellArgs.ARG_DISABLE_IMPELLER'), isTrue,
          reason: '关 Impeller 靠追加 ARG_DISABLE_IMPELLER（命令行值优先于 manifest 默认）');
      expect(src.contains('if (isImpellerDisabledPref())'), isTrue,
          reason: 'shell arg 是否追加由 isImpellerDisabledPref() 这个权威决策点门控');
    });

    test('isImpellerDisabledPref 未设置态回落到 true（Skia），不是 false（Impeller）', () {
      // 这是「装新包即好」的根：pref 未被用户显式设置时，Android 默认关 Impeller。
      expect(src.contains('return raw != null ? raw : true;'), isTrue,
          reason: '未设置（raw==null）必须回落到 true=关 Impeller 走 Skia；'
              '若改成 : false 则 Android 视频又全黑（BUG-597 复发）');
      // 反向守卫：绝不能出现「未设置默认 false」的旧形状（会让默认跑 Impeller）。
      expect(
          src.contains(
              'getBoolean(PreferenceKeys.RENDER_IMPELLER_DISABLED, false)\n'
              '                .getBoolean'),
          isFalse);
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
