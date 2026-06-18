import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_control_layout_edit_overlay.dart';

Future<void> _pumpOverlay(
  WidgetTester tester, {
  required VideoControlLayout layout,
  required Future<void> Function(VideoControlLayout layout) onLayoutChanged,
  VoidCallback? onClose,
  TextScaler? textScaler,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      builder: (BuildContext context, Widget? child) {
        if (textScaler == null) return child!;
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        );
      },
      home: Scaffold(
        body: SizedBox.expand(
          child: VideoControlLayoutEditOverlay(
            layout: layout,
            onLayoutChanged: onLayoutChanged,
            onClose: onClose ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _paletteChip(VideoControlItem item) {
  return find.byWidgetPredicate(
    (Widget w) =>
        w is Draggable<VideoControlDragData> &&
        w.data?.item == item &&
        w.data?.sourceSlot == null,
  );
}

Finder _placedChip(VideoControlItem item, VideoControlSlot slot) {
  return find.byWidgetPredicate(
    (Widget w) =>
        w is Draggable<VideoControlDragData> &&
        w.data?.item == item &&
        w.data?.sourceSlot == slot,
  );
}

Finder _slotRegion(VideoControlSlot slot) {
  return find.byKey(
    ValueKey<String>('video-control-edit-slot-${slot.storageValue}'),
  );
}

Future<void> _drag(WidgetTester tester, Finder source, Finder target) async {
  final Draggable<VideoControlDragData> draggable =
      tester.widget<Draggable<VideoControlDragData>>(source);
  final DragTarget<VideoControlDragData> dragTarget =
      tester.widget<DragTarget<VideoControlDragData>>(target);
  final DragTargetDetails<VideoControlDragData> details =
      DragTargetDetails<VideoControlDragData>(
    data: draggable.data!,
    offset: tester.getCenter(target),
  );
  expect(dragTarget.onWillAcceptWithDetails!(details), isTrue);
  dragTarget.onAcceptWithDetails!(details);
  await tester.pumpAndSettle();
}

bool _willAccept(WidgetTester tester, Finder source, Finder target) {
  final Draggable<VideoControlDragData> draggable =
      tester.widget<Draggable<VideoControlDragData>>(source);
  final DragTarget<VideoControlDragData> dragTarget =
      tester.widget<DragTarget<VideoControlDragData>>(target);
  return dragTarget.onWillAcceptWithDetails!(
    DragTargetDetails<VideoControlDragData>(
      data: draggable.data!,
      offset: tester.getCenter(target),
    ),
  );
}

void main() {
  testWidgets('onscreen overlay edits a draft and saves explicitly',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    bool closed = false;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (VideoControlLayout layout) async => committed = layout,
      onClose: () => closed = true,
    );

    final Finder source =
        _placedChip(VideoControlItem.settings, VideoControlSlot.screenRight);
    final Finder target = _slotRegion(VideoControlSlot.bottomLeft);
    expect(source, findsOneWidget);
    expect(target, findsOneWidget);

    await _drag(tester, source, target);

    expect(
      committed,
      isNull,
      reason: 'Dragging should only mutate the overlay draft until Save.',
    );
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(committed, isNotNull);
    expect(committed!.itemsIn(VideoControlSlot.bottomLeft),
        contains(VideoControlItem.settings));
    expect(committed!.itemsIn(VideoControlSlot.screenRight),
        isNot(contains(VideoControlItem.settings)));
    expect(closed, isTrue);
  });

  testWidgets('onscreen overlay cancel discards a draft',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    bool closed = false;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (VideoControlLayout layout) async => committed = layout,
      onClose: () => closed = true,
    );

    final Finder source = _paletteChip(VideoControlItem.screenshot);
    final Finder target = _slotRegion(VideoControlSlot.screenLeft);
    expect(source, findsOneWidget);
    expect(target, findsOneWidget);

    await _drag(tester, source, target);

    expect(committed, isNull);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(committed, isNull);
    expect(closed, isTrue);
  });

  testWidgets('onscreen overlay can add a palette button to an existing slot',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (VideoControlLayout layout) async => committed = layout,
    );

    final Finder source = _paletteChip(VideoControlItem.screenshot);
    final Finder target = _slotRegion(VideoControlSlot.screenLeft);
    expect(source, findsOneWidget);
    expect(target, findsOneWidget);

    await _drag(tester, source, target);
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(committed, isNotNull);
    expect(committed!.itemsIn(VideoControlSlot.screenLeft),
        contains(VideoControlItem.screenshot));
    expect(committed!.itemsIn(VideoControlSlot.topRight),
        contains(VideoControlItem.screenshot));
  });

  testWidgets(
      'onscreen overlay copies palette volume to the other bottom slot only',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (VideoControlLayout layout) async => committed = layout,
    );

    final Finder source = _paletteChip(VideoControlItem.volume);
    final Finder bottomLeft = _slotRegion(VideoControlSlot.bottomLeft);
    final Finder topRight = _slotRegion(VideoControlSlot.topRight);
    expect(source, findsOneWidget);
    expect(bottomLeft, findsOneWidget);
    expect(topRight, findsOneWidget);
    expect(_willAccept(tester, source, topRight), isFalse);

    await _drag(tester, source, bottomLeft);
    expect(_willAccept(tester, source, bottomLeft), isFalse);
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(committed, isNotNull);
    expect(committed!.slotsOf(VideoControlItem.volume), <VideoControlSlot>[
      VideoControlSlot.bottomLeft,
      VideoControlSlot.bottomRight,
    ]);
    expect(
      committed!
          .itemsIn(VideoControlSlot.bottomLeft)
          .where((VideoControlItem i) => i == VideoControlItem.volume),
      hasLength(1),
    );
  });

  testWidgets('onscreen overlay moves, removes, and restores title',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (VideoControlLayout layout) async => committed = layout,
    );

    final Finder topCenter = _slotRegion(VideoControlSlot.topCenter);
    final Finder topLeft = _slotRegion(VideoControlSlot.topLeft);
    final Finder topRight = _slotRegion(VideoControlSlot.topRight);
    final Finder hidden = _slotRegion(VideoControlSlot.hidden);
    expect(topCenter, findsOneWidget);
    expect(hidden, findsOneWidget);

    final Finder titleAtCenter =
        _placedChip(VideoControlItem.title, VideoControlSlot.topCenter);
    expect(titleAtCenter, findsOneWidget);
    expect(_willAccept(tester, _paletteChip(VideoControlItem.speed), topCenter),
        isFalse);

    await _drag(tester, titleAtCenter, topLeft);
    expect(_placedChip(VideoControlItem.title, VideoControlSlot.topCenter),
        findsNothing);
    expect(_placedChip(VideoControlItem.title, VideoControlSlot.topLeft),
        findsOneWidget);

    await _drag(
      tester,
      _placedChip(VideoControlItem.title, VideoControlSlot.topLeft),
      hidden,
    );
    expect(_placedChip(VideoControlItem.title, VideoControlSlot.hidden),
        findsNothing);
    expect(_paletteChip(VideoControlItem.title), findsOneWidget);

    await _drag(tester, _paletteChip(VideoControlItem.title), topRight);
    await tester.tap(find.text(t.dialog_save));
    await tester.pumpAndSettle();

    expect(committed, isNotNull);
    expect(committed!.slotsOf(VideoControlItem.title),
        <VideoControlSlot>[VideoControlSlot.topRight]);
    expect(committed!.removedItems, isNot(contains(VideoControlItem.title)));
  });

  testWidgets(
      'onscreen overlay includes subtitle and audio chrome in editable controls',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (_) async {},
    );

    expect(_paletteChip(VideoControlItem.speed), findsOneWidget);
    expect(_paletteChip(VideoControlItem.screenshot), findsOneWidget);
    expect(_paletteChip(VideoControlItem.subtitleTrack), findsOneWidget);
    expect(_paletteChip(VideoControlItem.audioTrack), findsOneWidget);
    expect(
      _placedChip(VideoControlItem.subtitleTrack, VideoControlSlot.topRight),
      findsOneWidget,
    );
    expect(
      _placedChip(VideoControlItem.audioTrack, VideoControlSlot.topRight),
      findsOneWidget,
    );
  });

  testWidgets('onscreen overlay has save, cancel, X remove, and no drag handle',
      (WidgetTester tester) async {
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (_) async {},
    );

    expect(find.text(t.dialog_save), findsOneWidget);
    expect(find.text(t.dialog_cancel), findsOneWidget);
    expect(find.byIcon(Icons.close), findsWidgets);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
    expect(find.text(t.video_control_slot_hidden), findsOneWidget);
  });

  testWidgets('onscreen overlay stays bounded on narrow video surfaces',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(560, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (_) async {},
    );

    expect(find.byType(VideoControlLayoutEditOverlay), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'onscreen overlay keeps save controls visible on low height with large text',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (_) async {},
      textScaler: const TextScaler.linear(1.6),
    );

    expect(tester.takeException(), isNull);
    for (final Finder finder in <Finder>[
      find.text(t.dialog_save),
      find.text(t.dialog_cancel),
      find.byIcon(Icons.close).first,
    ]) {
      final Rect rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
      expect(rect.bottom, lessThanOrEqualTo(260));
    }
  });
}
