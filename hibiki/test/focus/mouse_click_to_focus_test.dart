import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/focus/hibiki_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';

/// TODO-1113 P3: keyboard/gamepad focus navigation should also support the
/// mouse. On desktop, clicking a [FushiFocusTarget] carries directional-
/// navigation focus there (so subsequent arrow/gamepad traversal continues from
/// what the user clicked) WITHOUT double-activating the child, and the focus
/// ring stays lit on that press so the placed focus is visible. Hover/move do
/// not light the ring (conservative option b). Mobile/touch keep plain-tap.
void main() {
  group('FushiFocusTarget mouse click-to-focus (desktop-gated)', () {
    testWidgets(
        'a mouse click on a desktop target carries focus without double-firing',
        (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final FocusNode first = FocusNode(debugLabel: 'first');
      final FocusNode second = FocusNode(debugLabel: 'second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      int secondTaps = 0;
      late FushiFocusController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Builder(
              builder: (BuildContext context) {
                controller = FushiFocusRoot.controllerOf(context);
                return Column(
                  children: <Widget>[
                    FushiFocusTarget(
                      id: const FushiFocusId('first'),
                      focusNode: first,
                      child: const SizedBox(width: 40, height: 40),
                    ),
                    FushiFocusTarget(
                      id: const FushiFocusId('second'),
                      focusNode: second,
                      child: GestureDetector(
                        onTap: () => secondTaps++,
                        behavior: HitTestBehavior.opaque,
                        child: const SizedBox(width: 40, height: 40),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      first.requestFocus();
      await tester.pump();
      expect(controller.activeId, const FushiFocusId('first'));

      await tester.tap(
        find.byType(GestureDetector),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();

      expect(controller.activeId, const FushiFocusId('second'));
      expect(second.hasPrimaryFocus, isTrue);
      expect(first.hasPrimaryFocus, isFalse);
      expect(secondTaps, 1);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
        'on a mobile platform a mouse click does NOT change focus navigation',
        (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final FocusNode first = FocusNode(debugLabel: 'first');
      final FocusNode second = FocusNode(debugLabel: 'second');
      addTearDown(first.dispose);
      addTearDown(second.dispose);

      int secondTaps = 0;
      late FushiFocusController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Builder(
              builder: (BuildContext context) {
                controller = FushiFocusRoot.controllerOf(context);
                return Column(
                  children: <Widget>[
                    FushiFocusTarget(
                      id: const FushiFocusId('first'),
                      focusNode: first,
                      child: const SizedBox(width: 40, height: 40),
                    ),
                    FushiFocusTarget(
                      id: const FushiFocusId('second'),
                      focusNode: second,
                      child: GestureDetector(
                        onTap: () => secondTaps++,
                        behavior: HitTestBehavior.opaque,
                        child: const SizedBox(width: 40, height: 40),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      first.requestFocus();
      await tester.pump();
      expect(controller.activeId, const FushiFocusId('first'));

      await tester.tap(
        find.byType(GestureDetector),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();

      expect(secondTaps, 1);
      expect(controller.activeId, const FushiFocusId('first'));
      expect(second.hasPrimaryFocus, isFalse);

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('GamepadService pointer ring behaviour (TODO-1113 P3)', () {
    tearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    testWidgets('with focus navigation ON, a mouse DOWN keeps the ring lit',
        (WidgetTester tester) async {
      final GamepadService service = GamepadService(
        navigatorKey: GlobalKey<NavigatorState>(),
        focusNavigationEnabled: () => true,
      );
      service.start();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: Text('x')))),
      );
      await tester.pump();

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.down(tester.getCenter(find.text('x')));
      await tester.pump();

      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTraditional,
        reason: 'a click that carries focus must keep the ring visible',
      );

      await gesture.moveBy(const Offset(10, 10));
      await tester.pump();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'hover/move must not carry a focus ring',
      );

      await gesture.up();
      service.dispose();
    });

    testWidgets(
        'with focus navigation OFF, a mouse DOWN drops the ring (old behaviour)',
        (WidgetTester tester) async {
      final GamepadService service = GamepadService(
        navigatorKey: GlobalKey<NavigatorState>(),
        focusNavigationEnabled: () => false,
      );
      service.start();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Center(child: Text('x')))),
      );
      await tester.pump();

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.down(tester.getCenter(find.text('x')));
      await tester.pump();

      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'with focus navigation off, any pointer hides the ring',
      );

      await gesture.up();
      service.dispose();
    });
  });
}
