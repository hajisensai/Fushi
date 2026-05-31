import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_scroll.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';

void main() {
  testWidgets('HibikiFocusScroll reveals a normal off-screen context',
      (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        height: 120,
        child: ListView.builder(
          controller: controller,
          itemExtent: 48,
          itemCount: 20,
          itemBuilder: (BuildContext context, int index) {
            return Text('Row $index');
          },
        ),
      ),
    ));

    HibikiFocusScroll.ensureVisible(tester.element(find.text('Row 8')));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('directional move scrolls the newly focused target into view',
      (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: HibikiFocusRoot(
        child: SizedBox(
          height: 120,
          child: ListView.builder(
            controller: controller,
            itemExtent: 48,
            itemCount: 20,
            itemBuilder: (BuildContext context, int index) {
              return HibikiFocusTarget(
                id: HibikiFocusId('row-$index'),
                child: TextButton(
                  onPressed: () {},
                  child: Text('Row $index'),
                ),
              );
            },
          ),
        ),
      ),
    ));

    final HibikiFocusController focus = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(ListView)),
    );
    focus.requestById(const HibikiFocusId('row-0'));
    await tester.pump();

    for (int i = 0; i < 8; i += 1) {
      focus.move(HibikiFocusDirection.down);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(focus.activeId, const HibikiFocusId('row-8'));
    expect(find.text('Row 8'), findsOneWidget);
    final Rect viewport = tester.getRect(find.byType(ListView));
    final Rect row = tester.getRect(find.text('Row 8'));
    expect(
      row.top >= viewport.top && row.bottom <= viewport.bottom,
      isTrue,
      reason: 'primary=${FocusManager.instance.primaryFocus?.debugLabel} '
          'offset=${controller.offset} row=$row viewport=$viewport',
    );
    expect(controller.offset, greaterThan(0));
  });
}
