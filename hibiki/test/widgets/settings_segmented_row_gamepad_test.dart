import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for the reported gamepad bug: in 排版设置, D-pad Down from a stepper
// could not reach the segmented rows below (跨页模式 etc.) because a segmented row
// was never registered as a HibikiFocusTarget. It is now a single focus stop with
// D-pad Left/Right cycling the segment in place.
void main() {
  Widget stepperThenSegmented({
    required String selected,
    required ValueChanged<String> onChanged,
  }) {
    return HibikiFocusRoot(
      child: Column(
        children: <Widget>[
          AdaptiveSettingsStepperRow(
            title: 'Columns',
            value: 2,
            step: 1,
            min: 0,
            max: 4,
            format: (double v) => '${v.round()}',
            onChanged: (_) {},
          ),
          AdaptiveSettingsSegmentedRow<String>(
            title: 'Spread',
            segments: const <ButtonSegment<String>>[
              ButtonSegment<String>(value: 'off', label: Text('Off')),
              ButtonSegment<String>(value: 'on', label: Text('On')),
              ButtonSegment<String>(value: 'auto', label: Text('Auto')),
            ],
            selected: selected,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  testWidgets('D-pad Down from a stepper reaches the segmented row below',
      (WidgetTester tester) async {
    String spread = 'off';
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => stepperThenSegmented(
          selected: spread,
          onChanged: (String v) => setState(() => spread = v),
        ),
      ),
    ));
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Columns')),
    );
    // Focus bootstraps onto the first registered target (the stepper).
    controller.ensureFocus();
    await tester.pump();
    expect(controller.activeId, isNotNull);

    // Down must land on the segmented row — it is now a registered focus stop,
    // not skipped. Before the fix this returned false / stayed on the stepper.
    expect(controller.move(HibikiFocusDirection.down), isTrue,
        reason: 'the segmented row is reachable by geometric down');
    await tester.pump();

    // Prove the landing IS the segmented row: D-pad Right cycles its value.
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      ),
      isTrue,
      reason: 'D-pad right is consumed by the segmented row (cycles in place)',
    );
    await tester.pump();
    expect(spread, 'on', reason: 'off → on (next segment)');
  });

  testWidgets('D-pad Left/Right cycles segments and clamps at the ends',
      (WidgetTester tester) async {
    String spread = 'on';
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => stepperThenSegmented(
          selected: spread,
          onChanged: (String v) => setState(() => spread = v),
        ),
      ),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Spread')),
    );
    controller.ensureFocus(); // stepper (first target)
    await tester.pump();
    controller.move(HibikiFocusDirection.down); // stepper → segmented
    await tester.pump();
    final BuildContext ctx = controller.activeContext!;

    // on → auto (right), auto → auto (right clamps at last).
    Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadRight));
    await tester.pump();
    expect(spread, 'auto');
    Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadRight));
    await tester.pump();
    expect(spread, 'auto', reason: 'clamped at the last segment, no wrap');

    // auto → on → off (left), off → off (left clamps at first).
    Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadLeft));
    await tester.pump();
    expect(spread, 'on');
    Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadLeft));
    await tester.pump();
    expect(spread, 'off');
    Actions.maybeInvoke<GamepadButtonIntent>(
        ctx, const GamepadButtonIntent(GamepadButton.dpadLeft));
    await tester.pump();
    expect(spread, 'off', reason: 'clamped at the first segment, no wrap');
  });

  testWidgets('Up/Down is NOT consumed by the segmented row (focus can leave)',
      (WidgetTester tester) async {
    String spread = 'off';
    await tester.pumpWidget(buildTestApp(
      stepperThenSegmented(
          selected: spread,
          onChanged: (String v) {
            spread = v;
          }),
    ));
    await tester.pump();
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Spread')),
    );
    controller.ensureFocus();
    await tester.pump();
    controller.move(HibikiFocusDirection.down); // onto the segmented row
    await tester.pump();
    final BuildContext ctx = controller.activeContext!;

    final Object? down = Actions.maybeInvoke<GamepadButtonIntent>(
      ctx,
      const GamepadButtonIntent(GamepadButton.dpadDown),
    );
    expect(down, isNot(true),
        reason: 'down must bubble so focus can move off the segmented row');
    expect(spread, 'off', reason: 'up/down does not change the segment');
  });
}
