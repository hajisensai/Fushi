// Wn1SZdlyhl：控件布局编辑器拖拽时没有边缘自动滚动，视口外的槽位够不到。
// 这里用真实指针手势（startGesture → moveTo）驱动 Draggable，断言拖到视口边缘
// 时滚动视口自己滚、松手后落到原本在视口外的槽位里。
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_layout_edit_overlay.dart';
import 'package:fushi/src/media/video/video_control_layout_editor.dart';
import 'package:fushi/src/controls/control_layout.dart' show ControlDragData;
import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_control_layout_editor.dart';

Finder _videoPaletteChip(VideoControlItem item) {
  return find.byWidgetPredicate(
    (Widget w) =>
        w is Draggable<VideoControlDragData> &&
        w.data?.item == item &&
        w.data?.sourceSlot == null,
  );
}

Finder _videoPlacedChip(VideoControlItem item, VideoControlSlot slot) {
  return find.byWidgetPredicate(
    (Widget w) =>
        w is Draggable<VideoControlDragData> &&
        w.data?.item == item &&
        w.data?.sourceSlot == slot,
  );
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('视频控件编辑覆盖层（手机横屏 853x384）：拖到槽位视口底边会自动滚，能放进最底部槽位', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(853, 384));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SizedBox.expand(
            child: VideoControlLayoutEditOverlay(
              layout: VideoControlLayout.currentChrome,
              onLayoutChanged: (VideoControlLayout layout) async =>
                  committed = layout,
              onClose: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final Finder slotsScroll = find.byKey(
      const ValueKey<String>('video-control-edit-compact-slots'),
    );
    expect(slotsScroll, findsOneWidget);
    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(of: slotsScroll, matching: find.byType(Scrollable)).first,
    );
    expect(scrollable.position.pixels, 0);
    expect(
      scrollable.position.maxScrollExtent,
      greaterThan(0),
      reason: '槽位放不下一屏才有本问题',
    );

    Finder regionOf(VideoControlSlot slot) => find.byKey(
      ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
    );
    final Rect viewport = tester.getRect(slotsScroll);
    // 一开始整个在视口下方、够不到的槽位（不含「移出」托盘）。
    final List<VideoControlSlot> outOfView = <VideoControlSlot>[
      for (final VideoControlSlot slot in VideoControlSlot.editableSlots)
        if (slot != VideoControlSlot.hidden &&
            tester.getRect(regionOf(slot)).top >= viewport.bottom)
          slot,
    ];
    expect(outOfView, isNotEmpty, reason: '应有一开始在视口外的槽位');

    // 调色板里当前可见（可命中）的第一颗按钮。
    VideoControlItem? picked;
    for (final VideoControlItem item in VideoControlItem.customizableItems) {
      if (_videoPaletteChip(item).hitTestable().evaluate().isNotEmpty) {
        picked = item;
        break;
      }
    }
    expect(picked, isNotNull, reason: '调色板里应有可见的按钮');
    final VideoControlItem dragged = picked!;
    final Finder chip = _videoPaletteChip(dragged);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(chip),
    );
    // 先横向挪过拖拽阈值：调色板本身是竖向滚动区，竖向起手会被它的滚动手势抢走。
    await gesture.moveBy(const Offset(24, 0));
    await tester.pump();
    expect(
      find.byWidgetPredicate((Widget w) => w is Opacity && w.opacity == 0.3),
      findsOneWidget,
      reason: '拖动已开始（源 chip 变半透明占位）',
    );
    // 拖到槽位视口底边内侧的边缘带。
    await gesture.moveTo(Offset(viewport.center.dx, viewport.bottom - 6));
    await _pumpFrames(tester, 40);

    expect(
      scrollable.position.pixels,
      greaterThan(0),
      reason:
          '拖到边缘带应触发 EdgeDraggingAutoScroller；'
          'max=${scrollable.position.maxScrollExtent} viewport=$viewport '
          'ghost=${find.byWidgetPredicate((Widget w) => w is Opacity && w.opacity == 0.3).evaluate().length}',
    );

    // 目标槽位已滚进视口：指针移到它上面松手。
    // 原本在视口外的槽位里，现在完整滚进视口的那一个。
    VideoControlSlot? deepSlot;
    Rect? visible;
    for (final VideoControlSlot slot in outOfView) {
      final Rect rect = tester.getRect(regionOf(slot)).intersect(viewport);
      if (rect.height >= 40 && rect.width > 0) {
        deepSlot = slot;
        visible = rect;
        break;
      }
    }
    expect(
      deepSlot,
      isNotNull,
      reason:
          '原本够不到的槽位滚进了视口；'
          '${[for (final VideoControlSlot s in outOfView) tester.getRect(regionOf(s))]} viewport=$viewport pixels=${scrollable.position.pixels} slotsRect=${tester.getRect(slotsScroll)}',
    );
    await gesture.moveTo(visible!.center);
    await tester.pump();
    await gesture.moveBy(const Offset(1, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      _videoPlacedChip(dragged, deepSlot!),
      findsOneWidget,
      reason: '松手后按钮落进原本在视口外的槽位',
    );
    expect(committed, isNull, reason: '覆盖层只改草稿，保存前不提交');

    // 停止后不再自己滚。
    final double settled = scrollable.position.pixels;
    await _pumpFrames(tester, 10);
    expect(scrollable.position.pixels, settled);
  });

  for (final ({String name, Widget editor, bool Function(Widget) isChip}) c
      in <({String name, Widget editor, bool Function(Widget) isChip})>[
        (
          name: '阅读器（独立实现）',
          editor: ReaderControlLayoutEditor(
            layout: ReaderControlLayout.defaults,
            onLayoutChanged: (ReaderControlLayout l) async {},
            isTouchControls: false,
          ),
          isChip: (Widget w) => w is Draggable<ReaderControlItem>,
        ),
        (
          name: '视频设置（ControlLayoutEditor）',
          editor: VideoControlLayoutEditor(
            layout: VideoControlLayout.currentChrome,
            onLayoutChanged: (VideoControlLayout l) async {},
            isTouchControls: false,
          ),
          isChip: (Widget w) =>
              w
                  is Draggable<
                    ControlDragData<VideoControlSlot, VideoControlItem>
                  >,
        ),
      ]) {
    testWidgets('${c.name} 控件布局编辑器嵌在设置页 ListView：拖到视口顶边时外层列表回滚', (
      WidgetTester tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(360, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ScrollController controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: controller,
              children: <Widget>[const SizedBox(height: 300), c.editor],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final double start = controller.offset;
      expect(start, greaterThan(0));

      final Rect viewport = tester.getRect(find.byType(ListView));
      // 取视口里最靠下的一颗可拖按钮（调色板 / 托盘在编辑器下方）。
      Offset? origin;
      final List<double> seen = <double>[];
      for (final Element element
          in find.byWidgetPredicate(c.isChip).evaluate()) {
        final RenderBox box = element.renderObject! as RenderBox;
        final Offset center = box.localToGlobal(box.size.center(Offset.zero));
        seen.add(center.dy);
        final bool visible =
            center.dy > viewport.top + 120 && center.dy < viewport.bottom - 10;
        if (visible && (origin == null || center.dy > origin.dy)) {
          origin = center;
        }
      }
      expect(
        origin,
        isNotNull,
        reason: '视口里应有可拖的按钮；centers=$seen viewport=$viewport',
      );

      final TestGesture gesture = await tester.startGesture(origin!);
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await gesture.moveTo(Offset(viewport.center.dx, viewport.top + 6));
      await _pumpFrames(tester, 40);

      expect(controller.offset, lessThan(start), reason: '拖到顶边应让外层列表回滚');

      await gesture.up();
      await tester.pumpAndSettle();
      final double settled = controller.offset;
      await _pumpFrames(tester, 10);
      expect(controller.offset, settled, reason: '松手后停止自动滚动');
    });
  }
}
