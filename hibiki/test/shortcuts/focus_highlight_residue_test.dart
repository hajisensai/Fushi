import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';

/// BUG-397 / TODO-699: the focus ring (Material focus highlight) appears on the
/// default build and gets carried to a freshly-entered screen.
///
/// Two root causes, both in [GamepadService]:
///   (1) `_onKey` flipped the highlight strategy to `alwaysTraditional` for ANY
///       physical key (typing a letter, Esc, a shortcut, even a KeyUp) so the
///       first keystroke after launch lights the ring on whatever Material
///       control happens to hold focus. The ring should only show for actual
///       directional focus navigation (arrow keys / Tab), not arbitrary typing.
///   (2) Nothing reset the strategy back to touch on a screen change, so a ring
///       lit on one page stayed lit when a new page/tab took focus.
void main() {
  tearDown(() {
    // Restore the framework default so cross-test state does not leak.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('gamepadKeyDrivesFocusRing - only nav keys light the ring', () {
    test('a plain letter KeyDown does NOT drive the ring', () {
      final KeyDownEvent letter = _keyDown(LogicalKeyboardKey.keyA);
      expect(
        gamepadKeyDrivesFocusRing(letter),
        isFalse,
        reason: 'typing a letter is not focus navigation; it must not show the '
            'focus ring',
      );
    });

    test('any KeyUp does NOT drive the ring (even an arrow KeyUp)', () {
      final KeyUpEvent arrowUpRelease = _keyUp(LogicalKeyboardKey.arrowDown);
      expect(
        gamepadKeyDrivesFocusRing(arrowUpRelease),
        isFalse,
        reason: 'a release edge does not navigate; only the press/repeat does',
      );
    });

    test('Escape KeyDown does NOT drive the ring', () {
      expect(
        gamepadKeyDrivesFocusRing(_keyDown(LogicalKeyboardKey.escape)),
        isFalse,
      );
    });

    test('an arrow KeyDown DOES drive the ring (must not be killed)', () {
      expect(
        gamepadKeyDrivesFocusRing(_keyDown(LogicalKeyboardKey.arrowDown)),
        isTrue,
        reason: 'arrow keys are directional focus navigation - keep the ring',
      );
    });

    test('an arrow KeyRepeat DOES drive the ring', () {
      expect(
        gamepadKeyDrivesFocusRing(_keyRepeat(LogicalKeyboardKey.arrowRight)),
        isTrue,
      );
    });

    test('a Tab KeyDown DOES drive the ring', () {
      expect(
        gamepadKeyDrivesFocusRing(_keyDown(LogicalKeyboardKey.tab)),
        isTrue,
        reason: 'Tab traversal is focus navigation - keep the ring',
      );
    });
  });

  group('GamepadService._onKey wiring (root cause 1)', () {
    testWidgets(
        'a non-nav key on a focused Material control keeps touch highlight',
        (WidgetTester tester) async {
      final GamepadService service =
          GamepadService(navigatorKey: GlobalKey<NavigatorState>());
      // start() installs the HardwareKeyboard handler that contains _onKey on
      // every desktop/Apple platform (the test host qualifies). On Android it
      // early-returns; this test is therefore desktop-only behaviour, which is
      // exactly where the residue was reported.
      service.start();
      addTearDown(service.dispose);

      // Seed touch mode (what the default build shows after launch).
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTouch;

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

      // User types a letter (NOT focus navigation).
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(
        FocusManager.instance.highlightStrategy,
        isNot(FocusHighlightStrategy.alwaysTraditional),
        reason: 'a plain letter must not light the focus ring (root cause 1)',
      );

      // A real arrow press still arms the ring so navigation stays visible.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTraditional,
        reason: 'directional navigation must still show the ring',
      );

      // Dispose now (before the widget tree is torn down) so the poller Timer
      // installed by start() is cancelled and the framework sees no pending
      // timer. The addTearDown dispose above is idempotent.
      service.dispose();
    });
  });

  group('screen/tab switch resets the highlight (root cause 2)', () {
    test('resetHighlightForScreenSwitch flips traditional back to touch', () {
      final GamepadService service =
          GamepadService(navigatorKey: GlobalKey<NavigatorState>());
      service.start();
      addTearDown(service.dispose);

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;

      service.resetHighlightForScreenSwitch();

      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'switching screens must drop a stale ring back to touch',
      );
    });

    testWidgets('a NavigatorObserver push/pop resets the highlight',
        (WidgetTester tester) async {
      // No start(): resetHighlightForScreenSwitch only touches FocusManager, so
      // the observer can drive it without the polling Timer the service owns.
      final GamepadService service =
          GamepadService(navigatorKey: GlobalKey<NavigatorState>());
      final NavigatorObserver observer = HighlightResetNavigatorObserver(
          service.resetHighlightForScreenSwitch);
      final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: <NavigatorObserver>[observer],
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.pump();

      // Simulate a ring lit by prior keyboard navigation.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;

      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail')),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'pushing a new full-page route must reset the stale ring',
      );

      // Re-light, then pop: the reset must fire on pop too.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'popping back must also reset the stale ring',
      );
    });
  });
}

KeyDownEvent _keyDown(LogicalKeyboardKey key) => KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

KeyUpEvent _keyUp(LogicalKeyboardKey key) => KeyUpEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

KeyRepeatEvent _keyRepeat(LogicalKeyboardKey key) => KeyRepeatEvent(
      physicalKey: PhysicalKeyboardKey.keyA,
      logicalKey: key,
      timeStamp: Duration.zero,
    );

void _noop() {}
