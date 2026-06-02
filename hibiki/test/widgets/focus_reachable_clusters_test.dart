import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for the family of gamepad/keyboard focus-skip bugs (same root cause
// as the theme color swatches): native interactive CLUSTERS placed among
// registered HibikiFocusTargets were skipped by the directional controller,
// which walks only registered targets. These cover the three primitives the
// page fixes now route through: HibikiSelectableChip(focusId) (reader theme
// chips), HibikiAdjustableSegmented (dictionary type / sync conflict selectors),
// and HibikiFocusable (reader bottom action buttons).
void main() {
  Widget stepperThen(Widget below) {
    return HibikiFocusRoot(
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

  HibikiFocusController controllerFor(WidgetTester tester) =>
      HibikiFocusRoot.controllerOf(tester.element(find.text('Scale')));

  testWidgets('HibikiSelectableChip with focusId is a reachable focus stop',
      (WidgetTester tester) async {
    String? picked;
    await tester.pumpWidget(buildTestApp(stepperThen(
      Wrap(
        children: <Widget>[
          HibikiSelectableChip(
            label: 'A',
            selected: false,
            focusId: const HibikiFocusId('chip-a'),
            onSelected: (_) => picked = 'a',
          ),
          HibikiSelectableChip(
            label: 'B',
            selected: false,
            focusId: const HibikiFocusId('chip-b'),
            onSelected: (_) => picked = 'b',
          ),
        ],
      ),
    )));
    await tester.pump();

    final HibikiFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue,
        reason: 'a registered chip sits below the stepper');
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(picked, isNotNull, reason: 'A on the focused chip selects it');
  });

  testWidgets('HibikiAdjustableSegmented is reachable and D-pad Right cycles',
      (WidgetTester tester) async {
    String value = 'a';
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => stepperThen(
          HibikiAdjustableSegmented<String>(
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

    final HibikiFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue,
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

  testWidgets('HibikiActivatableFocusTarget action button is a reachable stop',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(buildTestApp(stepperThen(
      Row(
        children: <Widget>[
          HibikiActivatableFocusTarget(
            focusIdPrefix: 'action',
            onTap: () => tapped = true,
            child: const SizedBox(width: 60, height: 48),
          ),
        ],
      ),
    )));
    await tester.pump();

    final HibikiFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(HibikiFocusDirection.down), isTrue,
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
