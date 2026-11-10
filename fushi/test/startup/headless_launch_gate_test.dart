/// BUG-4072 方案 C：入口路由（精简入口 vs 完整初始化）单测。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/headless_launch_gate.dart';
import 'package:fushi_launch_presence/fushi_launch_presence.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('test/launch_presence_gate');

  const LaunchPresence headless = LaunchPresence(
    hasUi: false,
    detail: 'activity=none importance=125',
  );
  // iOS 后台拉起的原生取证（反馈 wlUi86UBfd 原文形状）。
  const LaunchPresence iosHeadless = LaunchPresence(
    hasUi: false,
    detail: 'applicationState=background scenes=1 foregroundScene=false',
  );
  const LaunchPresence withUi = LaunchPresence(
    hasUi: true,
    detail: 'activity=MainActivity importance=100',
  );

  void answer(LaunchPresence? p) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      p == null
          ? null
          : (MethodCall call) async {
              expect(call.method, kLaunchPresenceQueryMethod);
              return <String, Object?>{
                kLaunchPresenceHasUiKey: p.hasUi,
                kLaunchPresenceDetailKey: p.detail,
              };
            },
    );
  }

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  group('chooseLaunchEntry 纯判定', () {
    test('桌面永远完整入口（没有无界面启动）', () {
      expect(
        chooseLaunchEntry(
          mobile: false,
          presence: headless,
          lifecycle: null,
          inactiveMeansUi: true,
        ),
        LaunchEntry.full,
      );
    });

    test('原生不知道 → 完整入口（偏向有界面，不卡真启动）', () {
      expect(
        chooseLaunchEntry(
          mobile: true,
          presence: null,
          lifecycle: null,
          inactiveMeansUi: true,
        ),
        LaunchEntry.full,
      );
    });

    test('原生说有界面 → 完整入口', () {
      expect(
        chooseLaunchEntry(
          mobile: true,
          presence: withUi,
          lifecycle: null,
          inactiveMeansUi: true,
        ),
        LaunchEntry.full,
      );
    });

    test('原生说没界面、生命周期不在前台 → 精简入口', () {
      for (final AppLifecycleState? s in <AppLifecycleState?>[
        null,
        AppLifecycleState.detached,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
      ]) {
        expect(
          chooseLaunchEntry(
            mobile: true,
            presence: headless,
            lifecycle: s,
            inactiveMeansUi: true,
          ),
          LaunchEntry.deferUntilUi,
          reason: '$s',
        );
      }
    });

    test('iOS：原生说没界面、生命周期是 inactive → 仍走精简入口（inactive 不算界面）', () {
      expect(
        chooseLaunchEntry(
          mobile: true,
          presence: iosHeadless,
          lifecycle: AppLifecycleState.inactive,
          inactiveMeansUi: false,
        ),
        LaunchEntry.deferUntilUi,
      );
      expect(
        chooseLaunchEntry(
          mobile: true,
          presence: iosHeadless,
          lifecycle: AppLifecycleState.resumed,
          inactiveMeansUi: false,
        ),
        LaunchEntry.full,
      );
    });

    test('原生说没界面但界面已接上（resumed / inactive）→ 完整入口', () {
      for (final AppLifecycleState s in <AppLifecycleState>[
        AppLifecycleState.resumed,
        AppLifecycleState.inactive,
      ]) {
        expect(
          chooseLaunchEntry(
            mobile: true,
            presence: headless,
            lifecycle: s,
            inactiveMeansUi: true,
          ),
          LaunchEntry.full,
          reason: '$s',
        );
      }
    });
  });

  group('holdHeadlessLaunchUntilUi', () {
    test('桌面不问原生、直接放行', () async {
      int asked = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        MethodCall call,
      ) async {
        asked++;
        return <String, Object?>{kLaunchPresenceHasUiKey: false};
      });
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final HeadlessLaunchOutcome o = await holdHeadlessLaunchUntilUi(
        binding: binding,
        mobile: false,
        channel: channel,
      );
      expect(asked, 0);
      expect(o.entry, LaunchEntry.full);
      expect(o.describe(), isNull);
    });

    test('通道没注册（MissingPluginException）→ 不知道 → 直接放行', () async {
      answer(null);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final HeadlessLaunchOutcome o = await holdHeadlessLaunchUntilUi(
        binding: binding,
        mobile: true,
        channel: channel,
      );
      expect(o.entry, LaunchEntry.full);
      expect(o.presenceDetail, isNull);
    });

    test('有界面启动 → 直接放行', () async {
      answer(withUi);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final HeadlessLaunchOutcome o = await holdHeadlessLaunchUntilUi(
        binding: binding,
        mobile: true,
        channel: channel,
      );
      expect(o.entry, LaunchEntry.full);
      expect(o.waitedMs, 0);
      expect(lastHeadlessLaunchOutcome, same(o));
    });

    test('Android 无界面启动停在精简入口；paused / hidden 不放行，inactive 才放行', () async {
      answer(headless);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      int now = 1000;
      bool released = false;
      final Future<HeadlessLaunchOutcome> held = holdHeadlessLaunchUntilUi(
        binding: binding,
        mobile: true,
        inactiveMeansUi: true,
        channel: channel,
        nowMs: () => now,
      )..then((_) => released = true);
      await pumpEventQueue();
      expect(released, isFalse, reason: '还没有界面，完整初始化不许开始');

      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(released, isFalse);

      now = 4500;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final HeadlessLaunchOutcome o = await held;
      expect(released, isTrue);
      expect(o.entry, LaunchEntry.deferUntilUi);
      expect(o.deferred, isTrue);
      expect(o.waitedMs, 3500);
      expect(o.presenceDetail, 'activity=none importance=125');
      expect(o.describe(), contains('3500ms'));
      expect(o.describe(), contains('launch={activity=none importance=125}'));
    });

    test('无界面启动、resumed 到达即放行', () async {
      answer(headless);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      final Completer<void> done = Completer<void>();
      unawaited(
        holdHeadlessLaunchUntilUi(
          binding: binding,
          mobile: true,
          channel: channel,
        ).then((_) => done.complete()),
      );
      await pumpEventQueue();
      expect(done.isCompleted, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await done.future;
    });

    test('iOS 后台拉起：已是 inactive 也停在精简入口，再来 inactive 不放行，resumed 才放行', () async {
      answer(iosHeadless);
      // 反馈 wlUi86UBfd：scene 已连接但不在前台，引擎启动后几毫秒就报 inactive。
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      bool released = false;
      final Future<HeadlessLaunchOutcome> held = holdHeadlessLaunchUntilUi(
        binding: binding,
        mobile: true,
        inactiveMeansUi: false,
        channel: channel,
      )..then((_) => released = true);
      await pumpEventQueue();
      expect(released, isFalse, reason: 'iOS 的 inactive 不是界面，完整初始化不许在后台开始');

      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await pumpEventQueue();
      expect(released, isFalse);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final HeadlessLaunchOutcome o = await held;
      expect(released, isTrue);
      expect(o.entry, LaunchEntry.deferUntilUi);
      expect(
        o.presenceDetail,
        'applicationState=background scenes=1 foregroundScene=false',
      );
    });

    test('原生说没界面但问答期间界面已接上 → 不等', () async {
      answer(headless);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final HeadlessLaunchOutcome o = await holdHeadlessLaunchUntilUi(
        binding: binding,
        mobile: true,
        channel: channel,
      );
      expect(o.entry, LaunchEntry.full);
    });
  });
}
