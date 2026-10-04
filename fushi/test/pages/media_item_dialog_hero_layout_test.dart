import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';

/// 2026-10-04 长按 / 右键媒体弹窗 hero 重设计（用户反馈：书架弹窗竖版封面两侧
/// 大片空白）。锁定四条行为：
/// * 竖版封面按自身比例画成封面卡、与标题**并排**，不再整宽 letterbox；
/// * 横版封面（视频）走**横幅**：整宽显示、标题在封面下方；
/// * 桌面宽屏列表动作**两列**，对话框放宽；
/// * 手机窄屏列表动作**单列**、不溢出。
void main() {
  const Key coverKey = ValueKey<String>('hero-cover');

  List<DialogListAction> listActions() => <DialogListAction>[
        for (final String label in <String>[
          'Rename',
          'Open folder',
          'Statistics',
          'Mark as finished',
        ])
          DialogListAction(label: label, onPressed: () {}),
      ];

  /// 生成指定像素尺寸的真 PNG，并预先解码进 ImageCache（与骨架内部探测宽高比
  /// 用的是同一个降采样 provider），让首帧就拿到宽高比。
  Future<ImageProvider> preparedCover(
    WidgetTester tester,
    int width,
    int height,
  ) async {
    late ImageProvider provider;
    await tester.runAsync(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xFF3366CC),
      );
      final ui.Image image =
          await recorder.endRecording().toImage(width, height);
      final ByteData? png =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      provider = MemoryImage(png!.buffer.asUint8List());
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await precacheImage(
        ResizeImage.resizeIfNeeded(64, null, provider),
        tester.element(find.byType(SizedBox)),
      );
    });
    return provider;
  }

  Future<void> pumpFrame(
    WidgetTester tester, {
    required Size screen,
    required ImageProvider backdrop,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: MediaItemDialogFrame(
              cover: const SizedBox.expand(key: coverKey),
              coverBackdrop: backdrop,
              title: 'Hero title',
              author: 'Hero author',
              quickActions: <DialogQuickAction>[
                DialogQuickAction(
                  label: 'Illustrations',
                  icon: Icons.image_outlined,
                  onPressed: () {},
                ),
              ],
              listActions: listActions(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('portrait cover sits beside the title at its own aspect ratio',
      (WidgetTester tester) async {
    final ImageProvider cover = await preparedCover(tester, 200, 300);
    await pumpFrame(tester, screen: const Size(1280, 900), backdrop: cover);
    expect(tester.takeException(), isNull);

    final Rect coverRect = tester.getRect(find.byKey(coverKey));
    final Rect titleRect = tester.getRect(find.text('Hero title'));
    expect(coverRect.width / coverRect.height, closeTo(2 / 3, 0.02),
        reason: '封面卡按图片自身比例定尺寸，没有 letterbox');
    expect(titleRect.left, greaterThan(coverRect.right), reason: '竖版封面与标题并排');
    expect(titleRect.top, lessThan(coverRect.bottom));
    // 宽框：快捷 chip 进入封面右栏（不在封面下方另起一行）。
    final Rect chipRect = tester.getRect(find.text('Illustrations'));
    expect(chipRect.left, greaterThan(coverRect.right));
    expect(chipRect.top, lessThan(coverRect.bottom));
    // 模糊垫底铺满整条头部，比封面卡宽。
    final Rect backdropRect = tester.getRect(
      find.byKey(const ValueKey<String>('media_item_dialog_cover_backdrop')),
    );
    expect(backdropRect.width, greaterThan(coverRect.width * 2));
  });

  testWidgets('landscape cover becomes a full-width banner above the title',
      (WidgetTester tester) async {
    final ImageProvider cover = await preparedCover(tester, 320, 180);
    await pumpFrame(tester, screen: const Size(1280, 900), backdrop: cover);
    expect(tester.takeException(), isNull);

    final Rect coverRect = tester.getRect(find.byKey(coverKey));
    final Rect titleRect = tester.getRect(find.text('Hero title'));
    expect(coverRect.width / coverRect.height, closeTo(16 / 9, 0.03));
    expect(titleRect.top, greaterThan(coverRect.bottom),
        reason: '横版封面走横幅，标题在下');
    expect(coverRect.width, greaterThan(400), reason: '横幅占满头部宽度');
  });

  testWidgets('desktop width lays list actions out in two columns',
      (WidgetTester tester) async {
    final ImageProvider cover = await preparedCover(tester, 200, 300);
    await pumpFrame(tester, screen: const Size(1280, 900), backdrop: cover);

    final Rect a = tester.getRect(find.text('Rename'));
    final Rect b = tester.getRect(find.text('Open folder'));
    final Rect c = tester.getRect(find.text('Statistics'));
    expect(b.top, a.top, reason: '前两项同一行');
    expect(b.left, greaterThan(a.right));
    expect(c.top, greaterThan(a.bottom), reason: '第三项换行');
    expect(c.left, a.left);
  });

  testWidgets('phone width keeps a single column without overflow',
      (WidgetTester tester) async {
    final ImageProvider cover = await preparedCover(tester, 200, 300);
    await pumpFrame(tester, screen: const Size(390, 844), backdrop: cover);
    expect(tester.takeException(), isNull);

    final Rect coverRect = tester.getRect(find.byKey(coverKey));
    final Rect titleRect = tester.getRect(find.text('Hero title'));
    expect(titleRect.left, greaterThan(coverRect.right),
        reason: '手机上竖版封面仍与标题并排');
    final Rect a = tester.getRect(find.text('Rename'));
    final Rect b = tester.getRect(find.text('Open folder'));
    expect(b.top, greaterThan(a.bottom), reason: '窄框列表动作单列');
    expect(b.left, a.left);
    // 快捷 chip 在头部下方（窄框不塞进封面右栏）。
    expect(tester.getRect(find.text('Illustrations')).top,
        greaterThan(coverRect.bottom));
  });
}
