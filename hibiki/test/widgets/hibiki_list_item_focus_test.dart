import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

void main() {
  testWidgets('clickable HibikiListItem registers with the focus root',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRoot(
        child: Column(
          children: <Widget>[
            HibikiListItem(
              focusId: const HibikiFocusId('first-row'),
              title: const Text('First'),
              onTap: () => taps += 1,
            ),
            HibikiListItem(
              focusId: const HibikiFocusId('second-row'),
              title: const Text('Second'),
              onTap: () => taps += 1,
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.text('First')),
    );

    expect(controller.requestById(const HibikiFocusId('first-row')), isTrue);
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('first-row'));

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    expect(taps, 1);
  });

  testWidgets('passive HibikiListItem is not a focus target',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: HibikiFocusRoot(
        child: Column(
          children: <Widget>[
            HibikiListItem(title: Text('Passive')),
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
}
