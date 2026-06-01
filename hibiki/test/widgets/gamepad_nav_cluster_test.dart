import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_navigation.dart';

import 'widget_test_helpers.dart';

// Regression for the reported gamepad bug: focus reached the bottom nav bar /
// side rail and got stuck (could not move between tabs) or lost the ring. The
// bar is now one gamepad focus stop: directional focus lands on it (ring
// follows) and the along-axis D-pad switches tabs in place.
void main() {
  Widget contentThenCluster({
    required int index,
    required ValueChanged<int> onSelect,
    Axis axis = Axis.horizontal,
  }) {
    return HibikiFocusRoot(
      child: Column(
        children: <Widget>[
          const HibikiFocusTarget(
            id: HibikiFocusId('content'),
            child: SizedBox(width: 240, height: 80),
          ),
          GamepadNavCluster(
            axis: axis,
            count: 3,
            currentIndex: index,
            onSelect: onSelect,
            child: const SizedBox(width: 240, height: 60),
          ),
        ],
      ),
    );
  }

  testWidgets('D-pad Down reaches the bottom bar; Left/Right switches tabs',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenCluster(
          index: index,
          onSelect: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column)),
    );
    controller.requestById(const HibikiFocusId('content'));
    await tester.pump();

    // Down from the content lands on the nav bar (now a registered focus stop).
    expect(controller.move(HibikiFocusDirection.down), isTrue,
        reason: 'the bottom bar is reachable, not a focus dead zone');
    await tester.pump();
    final HibikiFocusId? onBar = controller.activeId;
    expect(onBar, isNot(const HibikiFocusId('content')));

    // D-pad Right switches to the next tab, staying on the bar.
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      ),
      isTrue,
      reason: 'Right is consumed by the bar (switches tab in place)',
    );
    await tester.pump();
    expect(index, 1);
    expect(controller.activeId, onBar, reason: 'still focused on the bar');

    // Left switches back.
    Actions.maybeInvoke<GamepadButtonIntent>(
      controller.activeContext!,
      const GamepadButtonIntent(GamepadButton.dpadLeft),
    );
    await tester.pump();
    expect(index, 0);
  });

  testWidgets('horizontal bar clamps at the ends and bubbles the cross axis',
      (WidgetTester tester) async {
    int index = 2; // last tab
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenCluster(
          index: index,
          onSelect: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column)),
    );
    controller.ensureFocus();
    await tester.pump();
    controller.move(HibikiFocusDirection.down); // onto the bar
    await tester.pump();
    final BuildContext ctx = controller.activeContext!;

    // Right at the last tab clamps (no wrap).
    Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadRight));
    await tester.pump();
    expect(index, 2, reason: 'clamped at the last tab');

    // Up (cross axis) is NOT consumed → focus can leave the bar upward.
    final Object? up = Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadUp));
    expect(up, isNot(true),
        reason: 'the cross-axis press must bubble so focus can leave the bar');
    expect(index, 2, reason: 'up does not switch tabs');
  });

  testWidgets('vertical rail switches on Up/Down, bubbles Left/Right',
      (WidgetTester tester) async {
    int index = 0;
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => contentThenCluster(
          index: index,
          axis: Axis.vertical,
          onSelect: (int i) => setState(() => index = i),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(Column)),
    );
    controller.ensureFocus();
    await tester.pump();
    controller.move(HibikiFocusDirection.down); // onto the rail cluster
    await tester.pump();
    final BuildContext ctx = controller.activeContext!;

    // Down switches to the next tab (vertical axis).
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
          ctx, const GamepadButtonIntent(GamepadButton.dpadDown)),
      isTrue,
    );
    await tester.pump();
    expect(index, 1);

    // Right (cross axis) bubbles so focus can leave the rail toward content.
    final Object? right = Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadRight));
    expect(right, isNot(true));
    expect(index, 1, reason: 'right does not switch rail tabs');
  });
}
