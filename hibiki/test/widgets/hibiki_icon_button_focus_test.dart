import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/utils/components/hibiki_icon_button.dart';

import 'widget_test_helpers.dart';

void main() {
  group('FushiIconButton default focusability', () {
    testWidgets(
        'registers under the focus root WITHOUT an explicit focusId and activates',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(buildTestApp(
        FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiIconButton(
                icon: Icons.add,
                tooltip: 'Add',
                onTap: () => taps += 1,
              ),
              FushiIconButton(
                icon: Icons.remove,
                tooltip: 'Remove',
                onTap: () => taps += 1,
              ),
            ],
          ),
        ),
      ));
      await tester.pump();

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.add)),
      );

      // A no-focusId button is now a default focus target: bootstrap lands on
      // the first one.
      controller.ensureFocus();
      await tester.pump();
      final FushiFocusId? firstId = controller.activeId;
      expect(firstId, isNotNull,
          reason: 'a no-focusId FushiIconButton registers by default');

      // D-pad down moves to the second button.
      expect(controller.move(FushiFocusDirection.down), isTrue);
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
        'a decorative FushiIconButton (onTap == null) is NOT a focus target',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiIconButton(icon: Icons.info_outline, tooltip: 'Info'),
            ],
          ),
        ),
      ));
      await tester.pump();

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.info_outline)),
      );
      controller.move(FushiFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull,
          reason: 'a decorative (no onTap) icon must not pollute traversal');
      expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
    });

    testWidgets('a disabled FushiIconButton is not focusable',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        FushiFocusRoot(
          child: Column(
            children: <Widget>[
              FushiIconButton(
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

      final FushiFocusController controller = FushiFocusRoot.controllerOf(
        tester.element(find.byIcon(Icons.delete)),
      );
      controller.move(FushiFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull,
          reason: 'a disabled button (canRequestFocus=false) is skipped');
    });
  });
}
