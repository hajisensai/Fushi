import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/collections/collection_drag.dart';
import 'package:fushi/src/media/collections/collection_shelf_row.dart';

/// 「拖进合集直接自动分配进这个合集」：媒体卡拖到合集行头 / 合集封面卡即加入该合集。
///
/// 守卫三件事：
/// 1. 行头接收 `MediaRef` 拖放并回调（漏接线时不建 DragTarget，防退回静默）；
/// 2. **两条拖放通道靠泛型分流互不误接**——拖 `MediaRef` 不得触发 `onTagDropped`、
///    拖 `BookTagRow` 不得触发 `onMediaDropped`。这是「行头同时挂两个 DragTarget」
///    这个设计的正确性核心，也是不复用 `DragTarget<BookTagRow>` 的原因；
/// 3. [MediaCardDraggable] 的按平台分流：桌面建 [Draggable]（按下即拖，与卡片既有
///    tap/longPress 零冲突），触屏不建拖拽源（长按已被上下文菜单占用）。
///
/// 纯 widget 层，不开 DB。
void main() {
  const MediaRef bookRef = MediaRef(kind: MediaKind.epub, entryKey: 'book-key');
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
          // 非滚动 Column：避免外层竖直滚动手势与 Draggable 抢手势竞技场，
          // 导致 moveBy 被当滚动吞掉（同 collection_shelf_row_tag_drop_test）。
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Draggable<MediaRef>(
                data: bookRef,
                feedback: const SizedBox(
                  key: ValueKey<String>('media_feedback'),
                  width: 40,
                  height: 20,
                ),
                // 有颜色的 Container 才参与命中测试（裸 SizedBox 透明）。
                child: Container(
                  key: const ValueKey<String>('media_handle'),
                  width: 40,
                  height: 20,
                  color: const Color(0xFF4CAF50),
                ),
              ),
              Draggable<BookTagRow>(
                data: tag,
                feedback: const SizedBox(
                  key: ValueKey<String>('tag_feedback'),
                  width: 40,
                  height: 20,
                ),
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

  CollectionShelfRow buildRow({
    void Function(MediaRef ref)? onMediaDropped,
    void Function(BookTagRow tag)? onTagDropped,
  }) =>
      CollectionShelfRow(
        title: 'コレクション',
        countLabel: '3',
        itemCount: 1,
        itemWidth: 200,
        rowHeight: 160,
        onOpenDetail: () {},
        onMediaDropped: onMediaDropped,
        onTagDropped: onTagDropped,
        itemBuilder: (BuildContext _, int __) => const Text('EP0'),
      );

  /// 从 [handleKey] 起拖，落到行头标题上。
  Future<void> dragOntoHeader(WidgetTester tester, String handleKey) async {
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(ValueKey<String>(handleKey))),
    );
    await tester.pump();
    // 先小步移动启动拖拽（recognizer 需一次超过 slop 的移动才 onStart）。
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('コレクション')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  testWidgets('把媒体卡拖到合集行头触发 onMediaDropped（自动加入该合集）',
      (WidgetTester tester) async {
    MediaRef? dropped;
    await pump(
      tester,
      buildRow(onMediaDropped: (MediaRef r) => dropped = r),
    );

    await dragOntoHeader(tester, 'media_handle');

    expect(dropped, isNotNull, reason: '行头必须接收媒体卡拖放');
    expect(dropped, bookRef, reason: '回调必须收到被拖条目的 (kind, entryKey)');
  });

  testWidgets('onMediaDropped 非 null 时行头是 DragTarget<MediaRef>',
      (WidgetTester tester) async {
    await pump(tester, buildRow(onMediaDropped: (_) {}));
    expect(find.byType(DragTarget<MediaRef>), findsOneWidget);
  });

  testWidgets('onMediaDropped 为 null 时行头不建 DragTarget（守卫调用点漏接线退回静默）',
      (WidgetTester tester) async {
    await pump(tester, buildRow(onMediaDropped: null));
    expect(find.byType(DragTarget<MediaRef>), findsNothing);
  });

  testWidgets('两条拖放通道靠泛型分流：拖媒体卡不触发 onTagDropped', (WidgetTester tester) async {
    MediaRef? droppedMedia;
    BookTagRow? droppedTag;
    await pump(
      tester,
      buildRow(
        onMediaDropped: (MediaRef r) => droppedMedia = r,
        onTagDropped: (BookTagRow t) => droppedTag = t,
      ),
    );

    await dragOntoHeader(tester, 'media_handle');

    expect(droppedMedia, bookRef, reason: '媒体通道必须收到');
    expect(droppedTag, isNull, reason: '标签通道绝不能被媒体拖放误触发');
  });

  testWidgets('两条拖放通道靠泛型分流：拖标签不触发 onMediaDropped', (WidgetTester tester) async {
    MediaRef? droppedMedia;
    BookTagRow? droppedTag;
    await pump(
      tester,
      buildRow(
        onMediaDropped: (MediaRef r) => droppedMedia = r,
        onTagDropped: (BookTagRow t) => droppedTag = t,
      ),
    );

    await dragOntoHeader(tester, 'tag_handle');

    expect(droppedTag, isNotNull, reason: '标签通道必须收到');
    expect(droppedMedia, isNull, reason: '媒体通道绝不能被标签拖放误触发');
  });

  group('MediaCardDraggable 按平台分流', () {
    Future<void> pumpCard(
      WidgetTester tester,
      TargetPlatform platform, {
      bool enabled = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
            body: MediaCardDraggable(
              mediaRef: bookRef,
              label: '書名',
              enabled: enabled,
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      );
    }

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    ]) {
      testWidgets('$platform 建 Draggable（按下即拖，不与长按菜单抢手势）',
          (WidgetTester tester) async {
        await pumpCard(tester, platform);
        expect(find.byType(Draggable<MediaRef>), findsOneWidget);
        // 必须**不是** LongPressDraggable：卡片长按已绑定上下文菜单，
        // 长按拖拽会被 InkWell.onLongPress 抢走，拖拽永远起不来。
        expect(find.byType(LongPressDraggable<MediaRef>), findsNothing);
      });
    }

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.fuchsia,
    ]) {
      testWidgets('$platform 不建拖拽源（触屏按下即拖会吞掉列表滚动）',
          (WidgetTester tester) async {
        await pumpCard(tester, platform);
        expect(find.byType(Draggable<MediaRef>), findsNothing);
      });
    }

    testWidgets('enabled=false 不建拖拽源（多选态卡片点击是切换选中，不应能拖走）',
        (WidgetTester tester) async {
      await pumpCard(tester, TargetPlatform.windows, enabled: false);
      expect(find.byType(Draggable<MediaRef>), findsNothing);
    });
  });
}
