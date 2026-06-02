import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for the reported bug: in 外观设置 the 主题 swatch row could not be
// reached by gamepad/keyboard directional navigation ("到不了主题的位置"). The
// swatches were bare InkWells — never registered as HibikiFocusTargets — so the
// directional controller, which walks ONLY registered targets, skipped the
// whole row (设计系统 → 深色模式). Each onTap swatch is now a single focus stop
// that A/Enter activates.
void main() {
  Widget stepperThenSwatches({
    required void Function(int) onPick,
    int count = 3,
  }) {
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
          Wrap(
            children: <Widget>[
              for (int i = 0; i < count; i++)
                HibikiColorSwatch(
                  key: ValueKey<int>(i),
                  color: Colors.primaries[i],
                  shape: HibikiColorSwatchShape.dot,
                  onTap: () => onPick(i),
                ),
            ],
          ),
        ],
      ),
    );
  }

  testWidgets('D-pad Down from the row above reaches a theme swatch',
      (WidgetTester tester) async {
    int? picked;
    await tester.pumpWidget(buildTestApp(
      stepperThenSwatches(onPick: (int i) => picked = i),
    ));
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Scale')),
    );
    controller.ensureFocus(); // bootstraps onto the stepper (first target)
    await tester.pump();
    expect(controller.activeId, isNotNull);

    // Before the fix this returned false: with no registered swatch below, the
    // controller had nothing to move onto and the cursor stayed on the stepper.
    expect(controller.move(HibikiFocusDirection.down), isTrue,
        reason: 'the swatch row is now a registered focus stop');
    await tester.pump();

    // Prove the landing IS a swatch: A/Enter (ActivateIntent) fires its onTap.
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(picked, isNotNull, reason: 'A on the focused swatch selects it');
  });

  testWidgets('D-pad Left/Right moves between adjacent swatches',
      (WidgetTester tester) async {
    int? picked;
    await tester.pumpWidget(buildTestApp(
      stepperThenSwatches(onPick: (int i) => picked = i),
    ));
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('Scale')),
    );
    controller.ensureFocus();
    await tester.pump();
    controller.move(HibikiFocusDirection.down); // onto some swatch
    await tester.pump();

    // Clamp left to the leftmost swatch deterministically (no wrap), so the
    // assertion below does not depend on which swatch Down geometrically picked.
    controller.move(HibikiFocusDirection.left);
    await tester.pump();
    controller.move(HibikiFocusDirection.left);
    await tester.pump();
    final HibikiFocusId? leftmostId = controller.activeId;

    expect(controller.move(HibikiFocusDirection.right), isTrue,
        reason: 'right reaches the next swatch in the row');
    await tester.pump();
    expect(controller.activeId, isNot(leftmostId));

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(picked, 1,
        reason: 'one right from the first swatch lands on index 1');
  });
}
