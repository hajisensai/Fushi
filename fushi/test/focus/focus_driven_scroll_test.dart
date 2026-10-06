import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';

void main() {
  testWidgets('reveal preserves edge policy, curve and animation completion', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController(
      initialScrollOffset: 80,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 120,
              child: ListView.builder(
                controller: controller,
                // ensureVisible 需要已挂载的 context；缓存目标行但仍保持离屏。
                scrollCacheExtent: const ScrollCacheExtent.pixels(800),
                itemExtent: 40,
                itemCount: 20,
                itemBuilder: (BuildContext context, int index) =>
                    Text('Row $index'),
              ),
            ),
          ),
        ),
      ),
    );

    // 已可见行保留原位置，不能退回默认的居中对齐。
    await FushiFocusScroll.ensureVisible(
      tester.element(find.text('Row 3')),
      duration: Duration.zero,
      alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
    expect(controller.offset, 80);

    bool completed = false;
    final Future<void> reveal =
        FushiFocusScroll.ensureVisible(
          tester.element(find.text('Row 8')),
          duration: const Duration(milliseconds: 200),
          curve: Curves.linear,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ).then<void>((_) {
          completed = true;
        });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(completed, isFalse);
    // Row 8 下缘在 360，视口高 120：目标 offset=240，线性动画中点=160。
    expect(controller.offset, closeTo(160, 1));
    await tester.pumpAndSettle();
    await reveal;
    expect(completed, isTrue);
    expect(controller.offset, closeTo(240, 1));
  });

  testWidgets('FushiFocusScroll reveals a normal off-screen context', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );

    FushiFocusScroll.ensureVisible(tester.element(find.text('Row 8')));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });

  testWidgets('directional move scrolls the newly focused target into view', (
    WidgetTester tester,
  ) async {
    final ScrollController controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );

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
      reason:
          'primary=${FocusManager.instance.primaryFocus?.debugLabel} '
          'offset=${controller.offset} row=$row viewport=$viewport',
    );
    expect(controller.offset, greaterThan(0));
  });
}
