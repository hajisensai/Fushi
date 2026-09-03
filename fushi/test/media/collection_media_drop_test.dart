import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
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

  /// 拖拽浮层从「紧凑 chip（只有条目名）」改成「卡片本体」。
  ///
  /// 原实现刻意不复用卡片，理由写在旧注释里：卡片内含 `FushiFocusTarget`，
  /// 焦点表按 id 唯一（`register` 是 `_entries[id] = entry` 直接覆盖），同一棵树
  /// 渲染第二份会让浮层顶掉真卡的 entry，浮层消失时 `unregister` 又把这条 entry
  /// 整个删掉——**真卡从此在手柄/键盘焦点表里消失**。
  ///
  /// 现在浮层用 `FushiFocusRoot(enabled: false)` 把子树的控制器屏蔽成 null，
  /// 其中的 `FushiFocusTarget` 只渲染不注册。
  ///
  /// ⚠️ **变异实测结论（别高估下面第二条用例）**：把屏蔽整层去掉、把
  /// `FushiFocusController.unregister` 的 `focusNode` / `owner` 双重校验去掉、
  /// 两者同时去掉——三种变异下这一组**都照样全绿**。原因是拖动结束时真卡的
  /// `FushiFocusTarget` 会 `didUpdateWidget` 重新注册，最终状态在所有变异下相同，
  /// 而 `requestById` 只看「entry 在不在且可聚焦」，浮层那份 entry 同样满足。
  ///
  /// 所以第二条用例守住的是「拖完之后真卡仍可被焦点导航命中」这个**最终状态**
  /// （能挡住 unregister 误删整条 entry 那类回归），**不是**屏蔽本身。屏蔽保留的
  /// 理由是：意图明确，且避免拖动期间焦点表里的 entry 指向浮层那一份——该性质
  /// 目前没有可落地的断言方式（controller 不暴露 entry，而给真卡传显式 FocusNode
  /// 会被浮层复用同一实例、直接 assert）。留在这里是为了不让后人误以为它有守卫。
  group('拖拽浮层是卡片本体', () {
    const FushiFocusId cardFocusId = FushiFocusId('drag-card');
    const Key cardVisualKey = Key('card-visual');

    Future<FushiFocusController> pumpFocusableCard(WidgetTester tester) async {
      late FushiFocusController controller;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          // 复刻真实 app 的层级：`main.dart` 把 FushiFocusRoot 挂在
          // `MaterialApp.builder` 里，即**在 Navigator 之上**，于是 Overlay
          // （Draggable 浮层的宿主）落在它之下、能拿到同一个 controller。
          // 若像最初那样把它写进 `home:`，浮层反而在焦点根之外、天然拿不到
          // controller——撞车根本不会发生，这一组守卫就成了空转（实测：去掉
          // 屏蔽后测试照样全绿）。
          builder: (BuildContext context, Widget? child) =>
              FushiFocusRoot(child: child!),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) {
                controller = FushiFocusRoot.controllerOf(context);
                return Align(
                  alignment: Alignment.topLeft,
                  child: MediaCardDraggable(
                    mediaRef: bookRef,
                    label: '書名',
                    // 必须是能命中 hitTest 的可见盒：裸 SizedBox（无 child）
                    // 的 RenderBox 不 hitTestSelf，指针根本落不到 Draggable
                    // 上，拖动永远起不来（这条曾让本用例空转）。
                    child: const FushiFocusTarget(
                      id: cardFocusId,
                      child: ColoredBox(
                        key: cardVisualKey,
                        color: Color(0xFF884422),
                        child: SizedBox(width: 60, height: 80),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('拖起来时浮层渲染卡片本体，且与原卡同尺寸', (WidgetTester tester) async {
      await pumpFocusableCard(tester);
      final Size cardSize = tester.getSize(find.byKey(cardVisualKey));
      expect(cardSize, const Size(60, 80));

      final TestGesture gesture = await tester
          .startGesture(tester.getCenter(find.byKey(cardVisualKey)));
      await tester.pump();
      // 先小步过 slop 让 recognizer onStart，再移动（同 dragOntoHeader 范式）。
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      // 卡片被渲染了两份：原位（childWhenDragging）+ 浮层。
      expect(find.byKey(cardVisualKey), findsNWidgets(2),
          reason: '浮层必须是卡片本体，而不是只有条目名的 chip');
      final List<Size> sizes = find
          .byKey(cardVisualKey)
          .evaluate()
          .map((Element e) => (e.renderObject! as RenderBox).size)
          .toList();
      expect(sizes, everyElement(const Size(60, 80)),
          reason: '浮层尺寸必须等于原卡真实尺寸；'
              '若改用父约束（常是宽松的 0..屏宽）会把浮层撑成整屏');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('浮层不注册焦点：拖动前中后真卡的焦点条目始终有效', (WidgetTester tester) async {
      final FushiFocusController controller = await pumpFocusableCard(tester);
      expect(controller.requestById(cardFocusId), isTrue,
          reason: '前置条件：真卡本来就注册了焦点条目');

      final TestGesture gesture = await tester
          .startGesture(tester.getCenter(find.byKey(cardVisualKey)));
      await tester.pump();
      // 先小步过 slop 让 recognizer onStart，再移动（同 dragOntoHeader 范式）。
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();

      expect(controller.requestById(cardFocusId), isTrue,
          reason: '浮层里的第二份 FushiFocusTarget 不得覆盖真卡的 entry');

      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.requestById(cardFocusId), isTrue,
          reason: '浮层消失时不得把真卡的 entry 一起注销——'
              '这正是原实现不敢复用卡片的那个失效模式');
    });
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
