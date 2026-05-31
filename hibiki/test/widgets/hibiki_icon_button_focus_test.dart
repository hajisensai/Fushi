import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';

import 'widget_test_helpers.dart';

void main() {
  group('HibikiIconButton default focusability', () {
    testWidgets(
        'registers under the focus root WITHOUT an explicit focusId and activates',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiIconButton(
                icon: Icons.add,
                tooltip: 'Add',
                onTap: () => taps += 1,
              ),
              HibikiIconButton(
                icon: Icons.remove,
                tooltip: 'Remove',
                onTap: () => taps += 1,
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.add)),
      );

      // A no-focusId button is now a default focus target: bootstrap lands on
      // the first one.
      controller.ensureFocus();
      await tester.pump();
      final HibikiFocusId? firstId = controller.activeId;
      expect(firstId, isNotNull,
          reason: 'a no-focusId HibikiIconButton registers by default');

      // D-pad down moves to the second button.
      expect(controller.move(HibikiFocusDirection.down), isTrue);
      await tester.pump();
      expect(controller.activeId, isNotNull);
      expect(controller.activeId, isNot(firstId),
          reason: 'directional move steps between the two buttons');

      // Activating the focused button fires its onTap.
      Actions.maybeInvoke<ActivateIntent>(
        controller.activeContext!,
        const ActivateIntent(),
      );
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets(
        'a decorative HibikiIconButton (onTap == null) is NOT a focus target',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiIconButton(icon: Icons.info_outline, tooltip: 'Info'),
            ],
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.info_outline)),
      );
      controller.move(HibikiFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull,
          reason: 'a decorative (no onTap) icon must not pollute traversal');
      expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
    });

    testWidgets('a disabled HibikiIconButton is not focusable',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        HibikiFocusRoot(
          child: Column(
            children: <Widget>[
              HibikiIconButton(
                icon: Icons.delete,
                tooltip: 'Delete',
                enabled: false,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.delete)),
      );
      controller.move(HibikiFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull,
          reason: 'a disabled button (canRequestFocus=false) is skipped');
    });
  });
}
