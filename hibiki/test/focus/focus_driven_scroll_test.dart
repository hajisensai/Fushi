import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/hibiki_focus_controller.dart';
import 'package:fushi/src/focus/hibiki_focus_scroll.dart';
import 'package:fushi/src/focus/hibiki_focus_target.dart';

void main() {
  testWidgets('FushiFocusScroll reveals a normal off-screen context',
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

    FushiFocusScroll.ensureVisible(tester.element(find.text('Row 8')));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('directional move scrolls the newly focused target into view',
      (WidgetTester tester) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: FushiFocusRoot(
        child: SizedBox(
          height: 120,
          child: ListView.builder(
            controller: controller,
            itemExtent: 48,
            itemCount: 20,
            itemBuilder: (BuildContext context, int index) {
              return FushiFocusTarget(
                id: FushiFocusId('row-$index'),
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

    final FushiFocusController focus = FushiFocusRoot.controllerOf(
      tester.element(find.byType(ListView)),
    );
    focus.requestById(const FushiFocusId('row-0'));
    await tester.pump();

    for (int i = 0; i < 8; i += 1) {
      focus.move(FushiFocusDirection.down);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(focus.activeId, const FushiFocusId('row-8'));
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
