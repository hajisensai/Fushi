import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';

void main() {
  testWidgets('clickable FushiCard registers with the focus root',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: FushiFocusRoot(
        child: Column(
          children: <Widget>[
            FushiCard(
              focusId: const FushiFocusId('first-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 80, height: 48),
            ),
            FushiCard(
              focusId: const FushiFocusId('second-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 80, height: 48),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final BuildContext context = tester.element(find.byType(Column));
    final FushiFocusController controller =
        FushiFocusRoot.controllerOf(context);
    expect(
      controller.requestById(const FushiFocusId('first-card')),
      isTrue,
    );
    await tester.pump();

    expect(controller.activeId, const FushiFocusId('first-card'));

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    expect(taps, 1);
  });
}
