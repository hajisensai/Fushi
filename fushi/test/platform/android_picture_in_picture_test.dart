// Android 系统画中画门面的契约测试。
//
// 盯三件事，都是真机上「点了小窗没反应 / 崩了」的直接成因：
//   1. 宽高比必须被钳进 [1/2.39, 2.39]——越界时原生抛 IllegalArgumentException；
//   2. 不支持的机器 / 非 Android 平台上**一个通道调用都不许发**（那边没注册这条
//      通道，发过去只会换来 MissingPluginException，还白花一次往返）；
//   3. 原生回程 onChanged 必须同时驱动 modeChanges 与 isActive——用户从小窗关闭
//      按钮退出时不经过 enter()，只有这条回程能让 Dart 侧知道自己出来了。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/mobile/android_picture_in_picture.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('clampPictureInPictureAspectRatio', () {
    test('区间内的比例原样返回', () {
      expect(clampPictureInPictureAspectRatio(16 / 9), closeTo(16 / 9, 1e-12));
      expect(clampPictureInPictureAspectRatio(9 / 16), closeTo(9 / 16, 1e-12));
      expect(clampPictureInPictureAspectRatio(1), 1);
    });

    test('超宽被钳到 2.39', () {
      expect(clampPictureInPictureAspectRatio(3), 2.39);
      expect(clampPictureInPictureAspectRatio(100), 2.39);
    });

    test('超窄被钳到 1/2.39', () {
      expect(clampPictureInPictureAspectRatio(0.2), closeTo(1 / 2.39, 1e-12));
      expect(clampPictureInPictureAspectRatio(0.001), closeTo(1 / 2.39, 1e-12));
    });

    test('端点值不被改动', () {
      expect(clampPictureInPictureAspectRatio(2.39), 2.39);
      expect(clampPictureInPictureAspectRatio(1 / 2.39), 1 / 2.39);
    });

    test('0 / 负数 / NaN / infinity 一律退回 16:9', () {
      expect(clampPictureInPictureAspectRatio(0), 16 / 9);
      expect(clampPictureInPictureAspectRatio(-1.5), 16 / 9);
      expect(clampPictureInPictureAspectRatio(double.nan), 16 / 9);
      expect(clampPictureInPictureAspectRatio(double.infinity), 16 / 9);
      expect(clampPictureInPictureAspectRatio(double.negativeInfinity), 16 / 9);
    });
  });

  group('AndroidPictureInPicture 通道契约', () {
    late List<MethodCall> calls;

    void installNative({required bool supported, bool enterSucceeds = true}) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.pictureInPicture, (
        MethodCall call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'isSupported':
            return supported;
          case 'enter':
            return enterSucceeds;
          case 'isActive':
            return false;
        }
        return null;
      });
    }

    setUp(() {
      calls = <MethodCall>[];
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidPictureInPicture.resetForTesting();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(FushiChannels.pictureInPicture, null);
      AndroidPictureInPicture.resetForTesting();
      debugDefaultTargetPlatformOverride = null;
    });

    test('原生说不支持时 enter 直接 false，且不发 enter 调用', () async {
      installNative(supported: false);

      expect(await AndroidPictureInPicture.enter(aspectRatio: 16 / 9), isFalse);
      expect(
          calls.map((MethodCall c) => c.method),
          <String>[
            'isSupported',
          ],
          reason: '不支持就该止步于能力探测，不许再发 enter');
    });

    test('支持时 enter 透传钳制后的比例', () async {
      installNative(supported: true);

      expect(await AndroidPictureInPicture.enter(aspectRatio: 3), isTrue);

      final MethodCall enterCall = calls.firstWhere(
        (MethodCall c) => c.method == 'enter',
      );
      final Map<Object?, Object?> args =
          enterCall.arguments as Map<Object?, Object?>;
      // 原生收到的必须是 2.39 而不是原始的 3.0：3.0 会让
      // enterPictureInPictureMode 抛 IllegalArgumentException。
      expect(args['aspectRatio'], 2.39);
    });

    test('比例非法时 enter 送出 16:9 兜底', () async {
      installNative(supported: true);

      await AndroidPictureInPicture.enter(aspectRatio: double.nan);

      final MethodCall enterCall = calls.firstWhere(
        (MethodCall c) => c.method == 'enter',
      );
      final Map<Object?, Object?> args =
          enterCall.arguments as Map<Object?, Object?>;
      expect(args['aspectRatio'], 16 / 9);
    });

    test('能力探测结果被缓存，不会每次 enter 都问一遍', () async {
      installNative(supported: true);

      await AndroidPictureInPicture.enter(aspectRatio: 16 / 9);
      await AndroidPictureInPicture.enter(aspectRatio: 16 / 9);

      expect(
        calls.where((MethodCall c) => c.method == 'isSupported').length,
        1,
      );
    });

    test('enter 成功后 isActive 立刻为真（不等原生回程）', () async {
      installNative(supported: true);

      expect(AndroidPictureInPicture.isActive, isFalse);
      await AndroidPictureInPicture.enter(aspectRatio: 16 / 9);
      expect(AndroidPictureInPicture.isActive, isTrue);
    });

    test('enter 失败时 isActive 保持为假', () async {
      installNative(supported: true, enterSucceeds: false);

      expect(await AndroidPictureInPicture.enter(aspectRatio: 16 / 9), isFalse);
      expect(AndroidPictureInPicture.isActive, isFalse);
    });

    test('非 Android 平台恒不支持，且一个通道调用都不发', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      installNative(supported: true);

      expect(await AndroidPictureInPicture.isSupported(), isFalse);
      expect(await AndroidPictureInPicture.enter(aspectRatio: 16 / 9), isFalse);
      expect(calls, isEmpty);
    });
  });

  group('AndroidPictureInPicture 回程', () {
    setUp(AndroidPictureInPicture.resetForTesting);
    tearDown(AndroidPictureInPicture.resetForTesting);

    test('onChanged 驱动 modeChanges 与 isActive', () async {
      final List<bool> seen = <bool>[];
      final StreamSubscription<bool> sub =
          AndroidPictureInPicture.modeChanges.listen(seen.add);
      addTearDown(sub.cancel);

      AndroidPictureInPicture.debugHandleModeChanged(true);
      await pumpEventQueue();
      expect(AndroidPictureInPicture.isActive, isTrue);

      AndroidPictureInPicture.debugHandleModeChanged(false);
      await pumpEventQueue();
      expect(AndroidPictureInPicture.isActive, isFalse);

      expect(seen, <bool>[true, false]);
    });

    test('重复的同值事件被去抖，不会刷屏', () async {
      final List<bool> seen = <bool>[];
      final StreamSubscription<bool> sub =
          AndroidPictureInPicture.modeChanges.listen(seen.add);
      addTearDown(sub.cancel);

      AndroidPictureInPicture.debugHandleModeChanged(true);
      AndroidPictureInPicture.debugHandleModeChanged(true);
      AndroidPictureInPicture.debugHandleModeChanged(false);
      await pumpEventQueue();

      expect(seen, <bool>[true, false]);
    });

    test('modeChanges 支持多订阅者', () async {
      final List<bool> a = <bool>[];
      final List<bool> b = <bool>[];
      final StreamSubscription<bool> subA =
          AndroidPictureInPicture.modeChanges.listen(a.add);
      final StreamSubscription<bool> subB =
          AndroidPictureInPicture.modeChanges.listen(b.add);
      addTearDown(subA.cancel);
      addTearDown(subB.cancel);

      AndroidPictureInPicture.debugHandleModeChanged(true);
      await pumpEventQueue();

      expect(a, <bool>[true]);
      expect(b, <bool>[true]);
    });
  });
}
