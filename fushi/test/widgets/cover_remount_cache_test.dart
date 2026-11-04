import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/video/cover_ui/cover_aspect_probe.dart';
import 'package:fushi/src/media/video/cover_ui/portrait_cover_image.dart';
import 'package:fushi/src/utils/components/prebaked_blur_image.dart';

/// 库页网格是懒建的：卡片滚出视口卸载、滚回来重挂。重挂时不得重做「图本身的
/// 属性」那几件事——宽高比判定（否则先画一帧 cover 再跳 contain，整排布局跳变）、
/// 垫底主色（`toByteData` GPU 回读）、模糊烘焙（`Picture.toImage`）。这些都按
/// [ImageProvider] 记在进程级缓存里，重挂的**首帧**就该是终态。
void main() {
  setUp(() {
    CoverProbeMemo.clear();
    clearPrebakedBlurCache();
  });

  Future<Uint8List> pngBytes(int width, int height) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawRect(
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..color = const ui.Color(0xFF3355FF),
    );
    final ui.Image image = await recorder.endRecording().toImage(width, height);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return data!.buffer.asUint8List();
  }

  const Key fgKey = Key('remount_foreground');

  /// 垫底的烘焙纹理（前景 [Image] 内部也是 RawImage，必须限定在模糊层里找）。
  final Finder bakedLayer = find.descendant(
    of: find.byType(PrebakedBlurImage),
    matching: find.byType(RawImage),
  );

  Widget card(ImageProvider provider) => MaterialApp(
    home: Center(
      child: SizedBox(
        width: 100,
        height: 150,
        child: PortraitCoverImage(image: provider, imageKey: fgKey),
      ),
    ),
  );

  /// 等解码 + 主色采样 + 模糊烘焙这些真异步全部落地。
  Future<void> settleAsync(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (bakedLayer.evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('卸载后重挂同一张横图：首帧即 contain + 垫底，模糊纹理直接上屏', (
    WidgetTester tester,
  ) async {
    final Uint8List bytes = (await tester.runAsync<Uint8List>(
      () => pngBytes(64, 36),
    ))!;
    final MemoryImage provider = MemoryImage(bytes);

    await tester.pumpWidget(card(provider));
    await tester.runAsync<void>(
      () => precacheImage(provider, tester.element(find.byKey(fgKey))),
    );
    await tester.pump();
    await settleAsync(tester);
    expect(tester.widget<Image>(find.byKey(fgKey)).fit, BoxFit.contain);
    expect(bakedLayer, findsOneWidget, reason: '前置：首次挂载已烘焙完');
    expect(prebakedBlurCacheLength, 1);

    // 卸载（滚出视口），再挂一张全新的卡（滚回来）。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(card(provider));

    expect(
      tester.widget<Image>(find.byKey(fgKey)).fit,
      BoxFit.contain,
      reason: '重挂首帧就该按记住的宽高比走 contain，不能先 cover 再跳',
    );
    expect(bakedLayer, findsOneWidget, reason: '重挂首帧应直接拿缓存里的烘焙纹理，不重烘、不留空白等淡入');
    expect(prebakedBlurCacheLength, 1, reason: '同一张图同一尺寸只烘一份');
  });

  testWidgets('从没见过的图：仍按「尺寸未知 = 合槽 cover」首帧', (WidgetTester tester) async {
    final Uint8List bytes = (await tester.runAsync<Uint8List>(
      () => pngBytes(64, 36),
    ))!;
    await tester.pumpWidget(card(MemoryImage(bytes)));
    expect(tester.widget<Image>(find.byKey(fgKey)).fit, BoxFit.cover);
    expect(find.byType(PrebakedBlurImage), findsNothing);
  });

  test('CoverProbeMemo：同一 provider 解出不同尺寸（换了图）时旧主色作废', () {
    final MemoryImage provider = MemoryImage(Uint8List(4));
    CoverProbeMemo.rememberSeed(provider, 16 / 9, const Color(0xFF112233));
    expect(CoverProbeMemo.seedOf(provider, 16 / 9).known, isTrue);
    CoverProbeMemo.rememberAspect(provider, 4 / 3);
    expect(CoverProbeMemo.aspectOf(provider), 4 / 3);
    expect(CoverProbeMemo.seedOf(provider, 4 / 3).known, isFalse);
    CoverProbeMemo.evict(provider);
    expect(CoverProbeMemo.aspectOf(provider), isNull);
  });

  test('CoverProbeMemo 有上限（LRU 淘汰最久未用）', () {
    for (int i = 0; i < CoverProbeMemo.capacity + 10; i++) {
      CoverProbeMemo.rememberAspect(FileImage(File('/c/$i.png')), 1);
    }
    expect(CoverProbeMemo.length, CoverProbeMemo.capacity);
    expect(CoverProbeMemo.aspectOf(FileImage(File('/c/0.png'))), isNull);
    expect(
      CoverProbeMemo.aspectOf(
        FileImage(File('/c/${CoverProbeMemo.capacity + 9}.png')),
      ),
      1,
    );
  });
}
