import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for the family of gamepad/keyboard focus-skip bugs (same root cause
// as the theme color swatches): native interactive CLUSTERS placed among
// registered FushiFocusTargets were skipped by the directional controller,
// which walks only registered targets. These cover the three primitives the
// page fixes now route through: FushiSelectableChip(focusId) (reader theme
// chips), FushiAdjustableSegmented (dictionary type / sync conflict selectors),
// and FushiFocusable (reader bottom action buttons).
void main() {
  Widget stepperThen(Widget below) {
    return FushiFocusRoot(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdaptiveSettingsStepperRow(
            title: 'Scale',
            value: 2,
            step: 1,
            min: 0,
            max: 4,
            format: (double v) => '${v.round()}',
            onChanged: (_) {},
          ),
          below,
        ],
      ),
    );
  }

  FushiFocusController controllerFor(WidgetTester tester) =>
      FushiFocusRoot.controllerOf(tester.element(find.text('Scale')));

  testWidgets('FushiSelectableChip with focusId is a reachable focus stop',
      (WidgetTester tester) async {
    String? picked;
    await tester.pumpWidget(buildTestApp(stepperThen(
      Wrap(
        children: <Widget>[
          FushiSelectableChip(
            label: 'A',
            selected: false,
            focusId: const FushiFocusId('chip-a'),
            onSelected: (_) => picked = 'a',
          ),
          FushiSelectableChip(
            label: 'B',
            selected: false,
            focusId: const FushiFocusId('chip-b'),
            onSelected: (_) => picked = 'b',
          ),
        ],
      ),
    )));
    await tester.pump();

    final FushiFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(FushiFocusDirection.down), isTrue,
        reason: 'a registered chip sits below the stepper');
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(picked, isNotNull, reason: 'A on the focused chip selects it');
  });

  testWidgets('FushiAdjustableSegmented is reachable and D-pad Right cycles',
      (WidgetTester tester) async {
    String value = 'a';
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => stepperThen(
          FushiAdjustableSegmented<String>(
            focusIdPrefix: 'seg',
            values: const <String>['a', 'b', 'c'],
            selected: value,
            onChanged: (String v) => setState(() => value = v),
            child: const SizedBox(width: 200, height: 40),
          ),
        ),
      ),
    ));
    await tester.pump();

    final FushiFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(FushiFocusDirection.down), isTrue,
        reason: 'the segmented selector is a registered focus stop');
    await tester.pump();
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      ),
      isTrue,
      reason: 'D-pad Right is consumed and cycles the segment in place',
    );
    await tester.pump();
    expect(value, 'b', reason: 'a → b (next value)');
  });

  testWidgets('FushiActivatableFocusTarget action button is a reachable stop',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(buildTestApp(stepperThen(
      Row(
        children: <Widget>[
          FushiActivatableFocusTarget(
            focusIdPrefix: 'action',
            onTap: () => tapped = true,
            child: const SizedBox(width: 60, height: 48),
          ),
        ],
      ),
    )));
    await tester.pump();

    final FushiFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(FushiFocusDirection.down), isTrue,
        reason: 'the action button is a registered focus stop');
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(tapped, isTrue, reason: 'A on the focused button activates it');
  });
}
