import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  testWidgets('clickable HibikiCard registers with the focus root',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRoot(
        child: Column(
          children: <Widget>[
            HibikiCard(
              focusId: const HibikiFocusId('first-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 80, height: 48),
            ),
            HibikiCard(
              focusId: const HibikiFocusId('second-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 80, height: 48),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final BuildContext context = tester.element(find.byType(Column));
    final HibikiFocusController controller =
        HibikiFocusRoot.controllerOf(context);
    expect(
      controller.requestById(const HibikiFocusId('first-card')),
      isTrue,
    );
    await tester.pump();

    expect(controller.activeId, const HibikiFocusId('first-card'));

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    expect(taps, 1);
  });
}
