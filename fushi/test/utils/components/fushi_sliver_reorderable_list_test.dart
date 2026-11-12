import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_sliver_reorderable_list.dart';
import 'package:material_ui/material_ui.dart';

/// [FushiSliverReorderableList]：懒建（#E5IZOyVcbm，上千行已装源不能全建）+ 拖拽重排。
void main() {
  Future<List<(int, int)>> pumpList(WidgetTester tester, int count) async {
    final List<(int, int)> reorders = <(int, int)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: <Widget>[
              FushiSliverReorderableList(
                itemCount: count,
                spacing: 4,
                keyForIndex: (int index) => ValueKey<String>('row_$index'),
                onReorder: (int from, int to) => reorders.add((from, to)),
                itemBuilder: (BuildContext context, int index) =>
                    SizedBox(height: 56, child: Text('Row $index')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return reorders;
  }

  testWidgets('只建视口 + 缓存区里的行', (WidgetTester tester) async {
    await pumpList(tester, 1000);
    final int built = find
        .textContaining('Row ', skipOffstage: false)
        .evaluate()
        .length;
    expect(built, lessThan(40), reason: '实建 $built 行');
    expect(find.text('Row 999', skipOffstage: false), findsNothing);
  });

  testWidgets('鼠标拖过下一行中线 → onReorder(0, 1)', (WidgetTester tester) async {
    final List<(int, int)> reorders = await pumpList(tester, 50);
    final Offset start = tester.getCenter(find.text('Row 0'));
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    // 行高 56 + 间距 4：Row 1 中线在起点下方 60，越过它再多 10。
    for (int i = 1; i <= 7; i++) {
      await gesture.moveTo(start + Offset(0, 10.0 * i));
      await tester.pump();
    }
    // 拖拽中：被拖行已换到第二个槽位。
    expect(
      tester.getCenter(find.text('Row 0')).dy,
      greaterThan(tester.getCenter(find.text('Row 1')).dy),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reorders, <(int, int)>[(0, 1)]);
  });

  testWidgets('没越过中线就松手：不提交', (WidgetTester tester) async {
    final List<(int, int)> reorders = await pumpList(tester, 50);
    final Offset start = tester.getCenter(find.text('Row 0'));
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    for (int i = 1; i <= 4; i++) {
      await gesture.moveTo(start + Offset(0, 10.0 * i));
      await tester.pump();
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reorders, isEmpty);
  });

  testWidgets('指针停在下边缘带、没越过中线：仍主动排帧把自动滚动跑起来', (WidgetTester tester) async {
    // 默认视口 800×600，行高 56 + 间距 4：Row 8 中线 508、Row 9 中线 568；
    // 下边缘带从 600 − 64 = 536 起。拖 Row 8 到 560：进了边缘带，又没越过
    // Row 9 中线 → 不换位、不 setState。此前帧回调挂上了却没人排帧，自动滚动不起步。
    final List<(int, int)> reorders = await pumpList(tester, 50);
    final Offset start = tester.getCenter(find.text('Row 8'));
    expect(start.dy, 508);
    final TestGesture gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(start + const Offset(0, 12));
    // 让抬起动效走完，帧队列回到空闲。
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveTo(const Offset(400, 560));
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '进入边缘带后必须有一帧来跑自动滚动的帧回调',
    );
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(scrollable.position.pixels, greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reorders, isNot(isEmpty), reason: '自动滚动带着被拖行往下换位');
  });

  testWidgets('触摸快速滑动交给滚动，不起拖', (WidgetTester tester) async {
    final List<(int, int)> reorders = await pumpList(tester, 50);
    await tester.drag(find.text('Row 2'), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(reorders, isEmpty);
    expect(find.text('Row 0'), findsNothing, reason: '列表应已向下滚动');
  });
}
