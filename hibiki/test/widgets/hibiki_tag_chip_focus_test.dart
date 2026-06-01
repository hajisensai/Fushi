import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiTagChip default focusability', () {
    testWidgets(
        'a tappable HibikiTagChip registers under the focus root WITHOUT focusId',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiTagChip(label: 'A', onTap: () => taps += 1),
              HibikiTagChip(label: 'B', onTap: () => taps += 1),
            ],
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('A')),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull,
          reason: 'a tappable tag chip is a default gamepad focus target');

      Actions.maybeInvoke<ActivateIntent>(
        controller.activeContext!,
        const ActivateIntent(),
      );
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('a passive HibikiTagChip (onTap == null) is not a focus target',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiTagChip(label: 'Passive'),
            ],
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Passive')),
      );
      controller.move(HibikiFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull);
      expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
    });

    testWidgets(
        'a deletable HibikiTagChip registers and deletes with gamepad X',
        (WidgetTester tester) async {
      int deletes = 0;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiTagChip(label: 'Ctrl+K', onDeleted: () => deletes += 1),
            ],
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.text('Ctrl+K')),
      );
      controller.ensureFocus();
      await tester.pump();

      expect(controller.activeId, isNotNull,
          reason: 'a deletable chip is a real gamepad target, not just a '
              'tiny pointer-only close icon');
      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          controller.activeContext!,
          const GamepadButtonIntent(GamepadButton.x),
        ),
        isTrue,
      );
      expect(deletes, 1);
    });
  });
}
