import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/collections/collection_shelf_row.dart';

/// 统一合集 UI v2 Phase C：合集横排行组件行为测试。
void main() {
  Future<void> pump(
    WidgetTester tester, {
    required CollectionShelfRow row,
    Size viewSize = const Size(800, 600),
  }) async {
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: <Widget>[row]),
        ),
      ),
    );
  }

  testWidgets('渲染头（合集名+数量+查看全部）+ 横向成员卡', (WidgetTester tester) async {
    int detailTaps = 0;
    await pump(
      tester,
      row: CollectionShelfRow(
        title: '孤独摇滚',
        countLabel: '12 集',
        itemCount: 3,
        itemWidth: 200,
        rowHeight: 160,
        onOpenDetail: () => detailTaps++,
        itemBuilder: (BuildContext _, int i) =>
            Text('EP$i', key: ValueKey<String>('ep_$i')),
      ),
    );
    expect(find.text('孤独摇滚'), findsOneWidget);
    expect(find.text('12 集'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ep_0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ep_1')), findsOneWidget);
    await tester.tap(find.text('孤独摇滚'));
    await tester.pump();
    expect(detailTaps, 1, reason: '行头点击必须进详情页');
  });

  testWidgets('initialIndex 把继续看成员滚进初始视野（前面的集在视野外）',
      (WidgetTester tester) async {
    await pump(
      tester,
      viewSize: const Size(500, 600),
      row: CollectionShelfRow(
        title: 'C',
        countLabel: '10',
        itemCount: 10,
        itemWidth: 200,
        rowHeight: 160,
        initialIndex: 5,
        onOpenDetail: () {},
        itemBuilder: (BuildContext _, int i) =>
            Text('EP$i', key: ValueKey<String>('ep_$i')),
      ),
    );
    // 初始 offset = 5*(200+12)：EP5 在视野内、EP0 在视野外（横向懒加载未建）。
    expect(find.byKey(const ValueKey<String>('ep_5')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('ep_0')), findsNothing);
  });

  testWidgets('initialIndex 越界安全（clamp 到末尾，不抛）', (WidgetTester tester) async {
    await pump(
      tester,
      viewSize: const Size(500, 600),
      row: CollectionShelfRow(
        title: 'C',
        countLabel: '2',
        itemCount: 2,
        itemWidth: 200,
        rowHeight: 160,
        initialIndex: 99,
        onOpenDetail: () {},
        itemBuilder: (BuildContext _, int i) =>
            Text('EP$i', key: ValueKey<String>('ep_$i')),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey<String>('ep_1')), findsOneWidget);
  });

  testWidgets('成员卡横向可滚动（拖动后后续集可见）', (WidgetTester tester) async {
    await pump(
      tester,
      viewSize: const Size(500, 600),
      row: CollectionShelfRow(
        title: 'C',
        countLabel: '10',
        itemCount: 10,
        itemWidth: 200,
        rowHeight: 160,
        onOpenDetail: () {},
        itemBuilder: (BuildContext _, int i) =>
            Text('EP$i', key: ValueKey<String>('ep_$i')),
      ),
    );
    expect(find.byKey(const ValueKey<String>('ep_6')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey<String>('ep_1')),
      const Offset(-1200, 0),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('ep_6')), findsOneWidget);
  });
}
