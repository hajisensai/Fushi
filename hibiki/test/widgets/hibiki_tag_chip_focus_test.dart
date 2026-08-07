import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  group('FushiTagChip default focusability', () {
    testWidgets(
        'a tappable FushiTagChip registers under the focus root WITHOUT focusId',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(buildTestApp(
        FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiTagChip(label: 'A', onTap: () => taps += 1),
              FushiTagChip(label: 'B', onTap: () => taps += 1),
            ],
          ),
        ),
      ));
      await tester.pump();

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
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

    testWidgets('a passive FushiTagChip (onTap == null) is not a focus target',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiTagChip(label: 'Passive'),
            ],
          ),
        ),
      ));
      await tester.pump();

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.text('Passive')),
      );
      controller.move(FushiFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull);
      expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
    });

    testWidgets(
        'a deletable FushiTagChip registers and deletes with gamepad X',
        (WidgetTester tester) async {
      int deletes = 0;
      await tester.pumpWidget(buildTestApp(
        FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiTagChip(label: 'Ctrl+K', onDeleted: () => deletes += 1),
            ],
          ),
        ),
      ));
      await tester.pump();

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
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
