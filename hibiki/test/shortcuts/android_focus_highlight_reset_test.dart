import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';

/// TODO-939 / BUG-452: on Android the Material focus ring lit by a gamepad /
/// D-pad key event would NOT clear on a touch swipe (and never on a controller
/// key, since those keep arming it) — it stayed stuck on the home / video
/// surfaces.
///
/// Root cause (confirmed): [GamepadService.start] early-returned on Android
/// (`if (!isSupportedPlatform) return;`), so Android never installed the global
/// pointer route + key handler and never seeded an explicit
/// [FocusHighlightStrategy]. Flutter's default `automatic` strategy then stayed
/// in charge: a `gameButton*` key event pushes it to `traditional`, a *tap*
/// (PointerDown) pulls it back to `touch`, but a *swipe* (PointerMove) does NOT
/// — so the ring lingered.
///
/// Fix: split [GamepadService.start] so the input-device → highlight-strategy
/// tracking (pointer route + key handler + startup seed) installs on EVERY
/// platform, while only the `gamepads` POLLER stays gated to desktop/Apple via
/// [GamepadService.needsGamepadPoller].
///
/// These tests cover:
///   (A) a source-contract guard so Android can never silently lose the
///       highlight tracking again (the real Android branch can't run in a
///       headless host test, so the contract is pinned in source);
///   (B) host-driven behaviour proving the installed pointer route maps a
///       PointerMove (swipe) → `alwaysTouch` and a nav key → `alwaysTraditional`
///       — i.e. exactly the swipe-reset path that was missing on Android.
void main() {
  tearDown(() {
    // Restore the framework default so cross-test state does not leak.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('TODO-939 source contract — Android keeps highlight tracking', () {
    final String src =
        File('lib/src/shortcuts/gamepad_service.dart').readAsStringSync();

    test('start() installs highlight tracking BEFORE the poller gate', () {
      final int startIdx = src.indexOf('void start() {');
      expect(startIdx, greaterThanOrEqualTo(0));
      final int trackIdx = src.indexOf('_installHighlightTracking()', startIdx);
      final int gateIdx =
          src.indexOf('if (!needsGamepadPoller) return', startIdx);
      expect(trackIdx, greaterThanOrEqualTo(0),
          reason: 'start() 必须调用 _installHighlightTracking()（平台无关）');
      expect(gateIdx, greaterThan(trackIdx),
          reason: 'highlight tracking 必须在 needsGamepadPoller 早退之前安装，'
              '否则 Android 仍拿不到 pointer route + strategy seed');
    });

    test('the poller — NOT the highlight tracking — is what Android gates out',
        () {
      expect(src, contains('static bool get needsGamepadPoller'),
          reason: 'poller 平台判据应命名为 needsGamepadPoller（只 gate 轮询）');
      // The pointer route + key handler must live in the platform-independent
      // installer, not behind the poller gate.
      final int installStart = src.indexOf('void _installHighlightTracking()');
      final int installEnd = src.indexOf('void _startGamepadPoller()');
      expect(installStart, greaterThanOrEqualTo(0));
      expect(installEnd, greaterThan(installStart));
      final String installBody = src.substring(installStart, installEnd);
      expect(installBody, contains('addGlobalRoute(_onPointerGlobal)'),
          reason: '全局 pointer route 必须在平台无关的 installer 里安装');
      expect(installBody, contains('addHandler(_onKey)'),
          reason: 'key handler 必须在平台无关的 installer 里安装');
      expect(installBody, contains('FocusHighlightStrategy.alwaysTouch'),
          reason: '启动时必须显式 seed alwaysTouch（接管 automatic）');
    });

    test('PointerMove (swipe) is a touch-reset trigger', () {
      final int onPtrStart = src.indexOf('void _onPointerGlobal(');
      expect(onPtrStart, greaterThanOrEqualTo(0));
      final String onPtrBody = src.substring(onPtrStart, onPtrStart + 600);
      expect(onPtrBody, contains('PointerMoveEvent'),
          reason: 'PointerMove（滑动）必须把 strategy 复位 touch — '
              '这是 Android「滑动消不掉」的直接解');
      expect(onPtrBody, contains('FocusHighlightStrategy.alwaysTouch'),
          reason: 'pointer 事件必须复位到 alwaysTouch');
    });
  });

  group('TODO-939 behaviour — installed pointer route resets the ring', () {
    testWidgets(
        'a nav key arms the ring, then a swipe (PointerMove) drops it to touch',
        (WidgetTester tester) async {
      final GamepadService service =
          GamepadService(navigatorKey: GlobalKey<NavigatorState>());
      // start() installs the same platform-independent highlight tracking that
      // now also runs on Android (the host here is desktop, but the route +
      // handler are identical — this proves the swipe-reset path Android lacked).
      service.start();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: _noop,
                autofocus: true,
                child: Text('btn'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Hardware navigation (arrow) lights the ring — like a D-pad on Android.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTraditional,
        reason: 'directional navigation must show the ring',
      );

      // A touch SWIPE (PointerMove, not a tap) must drop the ring back to touch.
      // This is the case Android's `automatic` strategy did NOT handle, so the
      // ring stayed stuck until TODO-939 made this service own the strategy.
      final TestGesture gesture =
          await tester.startGesture(const Offset(100, 100));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'a touch swipe (PointerMove) must hide the focus ring — '
            'the Android "滑动消不掉" symptom',
      );
      await gesture.up();

      service.dispose();
    });
  });
}

void _noop() {}
