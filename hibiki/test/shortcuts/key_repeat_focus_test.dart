import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/utils/components/hibiki_focus_ring.dart';

void main() {
  Future<HibikiFocusController> pumpManagedColumn(
    WidgetTester tester,
    GlobalKey<NavigatorState> navKey, {
    required List<HibikiFocusId> ids,
    Axis axis = Axis.vertical,
  }) async {
    late HibikiFocusController controller;
    final FocusNode sink =
        FocusNode(debugLabel: 'page-sink', skipTraversal: true);
    addTearDown(sink.dispose);

    final List<Widget> targets = <Widget>[
      for (final HibikiFocusId id in ids)
        HibikiFocusTarget(
          id: id,
          child: const SizedBox(width: 120, height: 40),
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: HibikiFocusRoot(
          child: HibikiFocusRing(
            child: wrapWithGlobalNavigation(
              navigatorKey: navKey,
              child: Builder(
                builder: (BuildContext context) {
                  controller = HibikiFocusRoot.controllerOf(context);
                  return Focus(
                    focusNode: sink,
                    autofocus: true,
                    skipTraversal: true,
                    onKeyEvent: (FocusNode node, KeyEvent event) {
                      if (event is! KeyDownEvent) {
                        return KeyEventResult.ignored;
                      }
                      final TraversalDirection? dir =
                          arrowTraversalDirection(event.logicalKey);
                      if (dir != null && focusedEditableText() == null) {
                        gamepadMoveFocusInDirection(context, dir);
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Scaffold(
                      body: axis == Axis.vertical
                          ? Column(children: targets)
                          : Row(children: targets),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  const HibikiFocusId a = HibikiFocusId('a');
  const HibikiFocusId b = HibikiFocusId('b');
  const HibikiFocusId c = HibikiFocusId('c');
  const HibikiFocusId d = HibikiFocusId('d');

  testWidgets(
      'held arrow keeps moving focus: KeyDown plus each KeyRepeat steps',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiFocusController controller = await pumpManagedColumn(
      tester,
      navKey,
      ids: <HibikiFocusId>[a, b, c, d],
    );
    controller.requestById(a);
    await tester.pump();
    expect(controller.activeId, a);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, b, reason: 'press edge moves one step');

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, c, reason: 'first repeat continues moving');

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, d, reason: 'second repeat continues moving');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });

  testWidgets('held arrow stops at the edge, identical to a single press',
      (WidgetTester tester) async {
    // Continuous movement must not run away or wrap past the last control: once
    // focus reaches the edge a further repeat is a no-op, exactly as a discrete
    // press at the edge already is (HibikiFocusController geometry clamps; the
    // repeat shares that same path).
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiFocusController controller = await pumpManagedColumn(
      tester,
      navKey,
      ids: <HibikiFocusId>[a, b],
    );
    controller.requestById(a);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, b,
        reason: 'press edge reaches the last target');

    // Repeats at the edge keep focus on the last target (no wrap, no run-away).
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, b, reason: 'repeat at the edge is a no-op');

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, b, reason: 'still clamped at the edge');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
  });

  testWidgets('a held NON-arrow key does not move focus on repeat',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiFocusController controller = await pumpManagedColumn(
      tester,
      navKey,
      ids: <HibikiFocusId>[a, b, c],
    );
    controller.requestById(a);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(controller.activeId, a,
        reason: 'only arrow repeats move focus; other keys are untouched');

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
  });

  testWidgets('releasing the arrow (KeyUp) does not move focus',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final HibikiFocusController controller = await pumpManagedColumn(
      tester,
      navKey,
      ids: <HibikiFocusId>[a, b, c],
    );
    controller.requestById(a);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, b);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(controller.activeId, b, reason: 'KeyUp is not a move');
  });

  group('arrowFocusMoveDirection (shared rule)', () {
    KeyEvent down(LogicalKeyboardKey k) => KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: k,
        timeStamp: Duration.zero);
    KeyEvent repeat(LogicalKeyboardKey k) => KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: k,
        timeStamp: Duration.zero);
    KeyEvent up(LogicalKeyboardKey k) => KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.arrowDown,
        logicalKey: k,
        timeStamp: Duration.zero);

    test('KeyDown plus KeyRepeat on an arrow both yield a direction', () {
      expect(arrowFocusMoveDirection(down(LogicalKeyboardKey.arrowDown)),
          TraversalDirection.down);
      expect(arrowFocusMoveDirection(repeat(LogicalKeyboardKey.arrowUp)),
          TraversalDirection.up);
    });

    test('KeyUp never yields a direction (release does not move)', () {
      expect(arrowFocusMoveDirection(up(LogicalKeyboardKey.arrowDown)), isNull);
    });

    test('non-arrow keys never yield a direction', () {
      expect(arrowFocusMoveDirection(down(LogicalKeyboardKey.enter)), isNull);
      expect(arrowFocusMoveDirection(repeat(LogicalKeyboardKey.keyA)), isNull);
    });
  });
}
