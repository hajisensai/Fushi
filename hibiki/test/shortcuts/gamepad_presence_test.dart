import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';

/// TODO-728①守卫：GamepadService 的控制器在场推断（活跃 + 空闲超时）。
/// 用 fakeAsync 驱动空闲定时器；用 debugMarkGamepadActivity 模拟一帧控制器事件
/// （等价于真实 _PluginGamepadPoller.onActivity，无需真插件后端）。
void main() {
  test('rising edge: first activity fires present=true exactly once', () {
    final List<bool> events = <bool>[];
    final GamepadService service = GamepadService(
      navigatorKey: GlobalKey<NavigatorState>(),
      onPresenceChanged: events.add,
    );

    service.debugMarkGamepadActivity();
    // 再来一帧活跃：不应重复发 true。
    service.debugMarkGamepadActivity();

    expect(events, <bool>[true]);
    service.dispose();
  });

  test('falling edge: idle past timeout fires present=false once', () {
    fakeAsync((FakeAsync async) {
      final List<bool> events = <bool>[];
      final GamepadService service = GamepadService(
        navigatorKey: GlobalKey<NavigatorState>(),
        onPresenceChanged: events.add,
      );

      service.debugMarkGamepadActivity();
      expect(events, <bool>[true]);

      // 还没到超时：仍在场。
      async.elapse(
          GamepadService.debugPresenceIdleTimeout - const Duration(seconds: 1));
      expect(events, <bool>[true]);

      // 越过超时：落到不在场。
      async.elapse(const Duration(seconds: 2));
      expect(events, <bool>[true, false]);

      service.dispose();
    });
  });

  test('activity re-arms the idle timer (resting controller stays present)',
      () {
    fakeAsync((FakeAsync async) {
      final List<bool> events = <bool>[];
      final GamepadService service = GamepadService(
        navigatorKey: GlobalKey<NavigatorState>(),
        onPresenceChanged: events.add,
      );

      service.debugMarkGamepadActivity();
      // 在超时前再活跃一次 → 重置定时器，不应被误判离场。
      async.elapse(
          GamepadService.debugPresenceIdleTimeout - const Duration(seconds: 1));
      service.debugMarkGamepadActivity();
      async.elapse(
          GamepadService.debugPresenceIdleTimeout - const Duration(seconds: 1));
      expect(events, <bool>[true],
          reason: 'continued activity must not flip presence to false');

      // 彻底静置 → 最终离场。
      async.elapse(
          GamepadService.debugPresenceIdleTimeout + const Duration(seconds: 1));
      expect(events, <bool>[true, false]);

      service.dispose();
    });
  });

  test('re-activity after going idle fires present=true again', () {
    fakeAsync((FakeAsync async) {
      final List<bool> events = <bool>[];
      final GamepadService service = GamepadService(
        navigatorKey: GlobalKey<NavigatorState>(),
        onPresenceChanged: events.add,
      );

      service.debugMarkGamepadActivity();
      async.elapse(
          GamepadService.debugPresenceIdleTimeout + const Duration(seconds: 1));
      expect(events, <bool>[true, false]);

      // 新一轮活跃 → 重新升起。
      service.debugMarkGamepadActivity();
      expect(events, <bool>[true, false, true]);

      service.dispose();
    });
  });

  test('no onPresenceChanged callback: activity is a harmless no-op', () {
    final GamepadService service = GamepadService(
      navigatorKey: GlobalKey<NavigatorState>(),
    );
    // Must not throw even with no listener.
    service.debugMarkGamepadActivity();
    service.dispose();
  });
}
