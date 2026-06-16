import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_control_layout_edit_overlay.dart';

Future<void> _pumpOverlay(
  WidgetTester tester, {
  required VideoControlLayout layout,
  required Future<void> Function(VideoControlLayout layout) onLayoutChanged,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
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
  final TestGesture gesture =
      await tester.startGesture(tester.getCenter(source));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('onscreen overlay drags a placed button into another player slot',
      (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    VideoControlLayout? committed;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (VideoControlLayout layout) async => committed = layout,
    );

    final Finder source =
        _placedChip(VideoControlItem.settings, VideoControlSlot.screenRight);
    final Finder target = _slotRegion(VideoControlSlot.bottomLeft);
    expect(source, findsOneWidget);
    expect(target, findsOneWidget);

    await _drag(tester, source, target);

    expect(committed, isNotNull);
    expect(committed!.itemsIn(VideoControlSlot.bottomLeft),
        contains(VideoControlItem.settings));
    expect(committed!.itemsIn(VideoControlSlot.screenRight),
        isNot(contains(VideoControlItem.settings)));
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

    expect(committed, isNotNull);
    expect(committed!.itemsIn(VideoControlSlot.screenLeft),
        contains(VideoControlItem.screenshot));
    expect(committed!.itemsIn(VideoControlSlot.topRight),
        contains(VideoControlItem.screenshot));
  });

  testWidgets('onscreen overlay close button exits edit mode',
      (WidgetTester tester) async {
    bool closed = false;
    await _pumpOverlay(
      tester,
      layout: VideoControlLayout.currentChrome,
      onLayoutChanged: (_) async {},
      onClose: () => closed = true,
    );

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
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
}
