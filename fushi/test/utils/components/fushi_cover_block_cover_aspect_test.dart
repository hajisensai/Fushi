import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:material_ui/material_ui.dart';

// 合集详情页 / 库页色块里封面被从两侧裁掉（用户 2026-11-16「合集封面显示有
// 问题」：薬屋のひとりごと 460×666 的封面，竖排书名「ひ」被裁掉半个）：封面图
// 一律 fitHeight 铺进封面框，框比图瘦就从两侧裁、比图胖就露衬底，所以封面框
// 必须跟封面图同比例。这里断言封面那张图拿到的框与图本身同比例（= 整张显示、
// 不裁不露底），并且斜放的封面整张落在色块里。
void main() {
  const ValueKey<String> coverKey = ValueKey<String>('cover');
  const ValueKey<String> blockKey = ValueKey<String>('block');

  Future<MemoryImage> makeImage(WidgetTester tester, int w, int h) async {
    final Uint8List? bytes = await tester.runAsync<Uint8List?>(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = const Color(0xFF3366AA),
      );
      final ui.Image image = await recorder.endRecording().toImage(w, h);
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      return data?.buffer.asUint8List();
    });
    return MemoryImage(bytes!);
  }

  Widget coverOf(ImageProvider image, {Key? key}) => Image(
    key: key,
    image: image,
    fit: BoxFit.fitHeight,
    alignment: Alignment.topCenter,
  );

  Future<void> pumpDecoded(
    WidgetTester tester,
    Widget child,
    List<ImageProvider> images,
  ) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(488, 700) * 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    );
    await tester.runAsync(() async {
      for (final ImageProvider image in images) {
        await precacheImage(image, tester.element(find.byType(Scaffold)));
      }
    });
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// 封面那张图的框比例与图本身比例之差（0 = fitHeight 正好整张铺满）。
  double aspectError(WidgetTester tester, Finder cover, double imageAspect) {
    final Size box = tester.getSize(cover);
    return (box.width / box.height - imageAspect).abs();
  }

  /// 封面经姿态变换（旋转 / 位移 / 缩放）后四个角的外接框（全局坐标）。
  Rect paintedBounds(WidgetTester tester, Finder cover) {
    final RenderBox box = tester.renderObject<RenderBox>(cover);
    final List<Offset> corners = <Offset>[
      box.localToGlobal(Offset.zero),
      box.localToGlobal(Offset(box.size.width, 0)),
      box.localToGlobal(Offset(0, box.size.height)),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    ];
    double l = double.infinity, t = double.infinity;
    double r = -double.infinity, b = -double.infinity;
    for (final Offset c in corners) {
      if (c.dx < l) l = c.dx;
      if (c.dy < t) t = c.dy;
      if (c.dx > r) r = c.dx;
      if (c.dy > b) b = c.dy;
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  Future<void> hover(WidgetTester tester) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(blockKey)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  // 轻小说（460×666 ≈ 0.69）与漫画（320×500 = 0.64）两种真实封面比例。
  const List<(int, int)> coverSizes = <(int, int)>[(460, 666), (320, 500)];

  for (final (int w, int h) in coverSizes) {
    final double imageAspect = w / h;

    for (final (String name, Size size) in <(String, Size)>[
      ('规整块', const Size(400, 204)),
      ('窄窗块', const Size(400, 184)),
    ]) {
      testWidgets('背景图 + 海报（$name，封面 $w×$h）：海报框与封面同比例，静止 / 悬停都整张在色块内', (
        WidgetTester tester,
      ) async {
        final MemoryImage cover = await makeImage(tester, w, h);
        final MemoryImage backdrop = await makeImage(tester, 1280, 720);
        await pumpDecoded(
          tester,
          SizedBox(
            key: blockKey,
            width: size.width,
            height: size.height,
            child: FushiCoverBlock(
              title: '薬屋のひとりごと',
              art: FushiCoverBlockArt.portrait,
              covers: <Widget>[coverOf(cover, key: coverKey)],
              backdrop: Image(image: backdrop, fit: BoxFit.cover),
            ),
          ),
          <ImageProvider>[cover, backdrop],
        );
        expect(
          aspectError(tester, find.byKey(coverKey), imageAspect),
          lessThan(0.005),
        );
        final Rect block = tester.getRect(find.byKey(blockKey));
        void expectInside(String pose) {
          final Rect painted = paintedBounds(tester, find.byKey(coverKey));
          expect(
            painted.left,
            greaterThanOrEqualTo(block.left),
            reason: '$pose $painted / $block',
          );
          expect(
            painted.top,
            greaterThanOrEqualTo(block.top),
            reason: '$pose $painted / $block',
          );
          expect(
            painted.bottom,
            lessThanOrEqualTo(block.bottom),
            reason: '$pose $painted / $block',
          );
        }

        expectInside('rest');
        await hover(tester);
        expectInside('hover');
      });
    }

    testWidgets('书封摆法（单本，封面 $w×$h）：书封框与封面同比例', (WidgetTester tester) async {
      final MemoryImage cover = await makeImage(tester, w, h);
      await pumpDecoded(
        tester,
        SizedBox(
          key: blockKey,
          width: 400,
          height: 204,
          child: FushiCoverBlock(
            title: '薬屋のひとりごと',
            art: FushiCoverBlockArt.book,
            covers: <Widget>[coverOf(cover, key: coverKey)],
          ),
        ),
        <ImageProvider>[cover],
      );
      expect(
        aspectError(tester, find.byKey(coverKey), imageAspect),
        lessThan(0.005),
      );
    });
  }
}
