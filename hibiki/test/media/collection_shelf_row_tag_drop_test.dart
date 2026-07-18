import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/media/collections/collection_shelf_row.dart';

/// BUG-899：把标签拖到合集**行头** = 给整个合集打标签（与书/视频卡的书级拖放一致）。
/// 根因是合集行既非 `DragTarget` 也未被调用点包进 `BookDragTarget`，标签落上去静默无
/// 反应。这里守卫「行头拖放接收」这条交互：拖入触发回调、漏接线（onTagDropped=null）
/// 时不建 DragTarget（防止再次退回静默）。纯 `BookTagRow` data class，不开 DB。
void main() {
  const BookTagRow tag = BookTagRow(
    id: 7,
    name: 'お気に入り',
    colorValue: 0xFF2196F3,
    sortOrder: 0,
    createdAt: 0,
  );

  Future<void> pump(WidgetTester tester, CollectionShelfRow row) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 非滚动 Column（不用 ListView）：避免外层竖直滚动手势与 Draggable 的拖拽
          // 识别器在手势竞技场抢赢，导致 moveBy 被当滚动吞掉、拖拽根本没启动。
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 拖动源：一个携带 [tag] 的普通 Draggable（真 app 里是标签栏的
              // LongPressDraggable<BookTagRow>，此处简化手势，payload 类型一致即可）。
              Draggable<BookTagRow>(
                data: tag,
                feedback: const SizedBox(
                  key: ValueKey<String>('tag_feedback'),
                  width: 40,
                  height: 20,
                ),
                // 有颜色的 Container 才参与命中测试（裸 SizedBox 透明，指针按下命中
                // 不到 Draggable 的 Listener，拖拽根本不会启动）。
                child: Container(
                  key: const ValueKey<String>('tag_handle'),
                  width: 40,
                  height: 20,
                  color: const Color(0xFF2196F3),
                ),
              ),
              row,
            ],
          ),
        ),
      ),
    );
  }

  CollectionShelfRow buildRow({void Function(BookTagRow tag)? onTagDropped}) =>
      CollectionShelfRow(
        title: 'コレクション',
        countLabel: '3',
        itemCount: 1,
        itemWidth: 200,
        rowHeight: 160,
        onOpenDetail: () {},
        onTagDropped: onTagDropped,
        itemBuilder: (BuildContext _, int __) => const Text('EP0'),
      );

  testWidgets('把标签拖到合集行头触发 onTagDropped（合集级打标签入口）',
      (WidgetTester tester) async {
    BookTagRow? dropped;
    await pump(tester, buildRow(onTagDropped: (BookTagRow t) => dropped = t));

    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('tag_handle'))),
    );
    await tester.pump();
    // 先小步移动启动拖拽（Draggable 的 recognizer 需一次超过 slop 的移动才 onStart），
    // 再落到行头标题上（行头区被 DragTarget 包裹）。
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('tag_feedback')),
      findsOneWidget,
      reason: '拖拽应已启动（feedback 出现）',
    );
    await gesture.moveTo(tester.getCenter(find.text('コレクション')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dropped, isNotNull, reason: '行头必须接收标签拖放');
    expect(dropped!.id, tag.id, reason: '回调必须收到被拖的那个 BookTagRow');
  });

  testWidgets('onTagDropped 非 null 时行头是 DragTarget<BookTagRow>',
      (WidgetTester tester) async {
    await pump(tester, buildRow(onTagDropped: (_) {}));
    expect(find.byType(DragTarget<BookTagRow>), findsOneWidget);
  });

  testWidgets('onTagDropped 为 null 时行头不建 DragTarget（守卫调用点漏接线又退回静默）',
      (WidgetTester tester) async {
    await pump(tester, buildRow(onTagDropped: null));
    expect(find.byType(DragTarget<BookTagRow>), findsNothing);
  });
}
