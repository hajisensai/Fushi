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

  testWidgets('采色途中 evict（同路径换封面）：旧图主色不得回填进 memo', (WidgetTester tester) async {
    final Uint8List bytes = (await tester.runAsync<Uint8List>(
      () => pngBytes(64, 36),
    ))!;
    final MemoryImage provider = MemoryImage(bytes);

    await tester.pumpWidget(card(provider));
    // 卡片的监听先注册；这里排在它后面：解码一到，卡片的 _onImage 已发起异步采色，
    // 紧接着同步驱逐——正是「采样途中 evictLocalCoverCache」的窗口。
    final ImageStream stream = provider.resolve(ImageConfiguration.empty);
    bool evicted = false;
    final ImageStreamListener evictOnArrival = ImageStreamListener((
      ImageInfo info,
      bool _,
    ) {
      info.dispose();
      CoverProbeMemo.evict(provider);
      evicted = true;
    });
    stream.addListener(evictOnArrival);
    addTearDown(() => stream.removeListener(evictOnArrival));

    await settleAsync(tester);
    expect(evicted, isTrue, reason: '前置：解码已到、驱逐已发生');
    expect(
      CoverProbeMemo.seedOf(provider, 64 / 36).known,
      isFalse,
      reason: 'evict 之后才回来的旧采样不得以同一 provider 写回 memo',
    );
    expect(CoverProbeMemo.aspectOf(provider), isNull);
  });

  testWidgets('烘焙途中 evict：旧图的模糊纹理不得进缓存', (WidgetTester tester) async {
    final Uint8List bytes = (await tester.runAsync<Uint8List>(
      () => pngBytes(64, 36),
    ))!;
    final MemoryImage provider = MemoryImage(bytes);

    await tester.pumpWidget(card(provider));
    // 等到垫底层挂上：它挂上的那一帧 build 就发起了 Picture.toImage 烘焙。
    for (int i = 0; i < 50; i++) {
      if (find.byType(PrebakedBlurImage).evaluate().isNotEmpty) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    expect(find.byType(PrebakedBlurImage), findsOneWidget, reason: '前置：垫底已挂');
    expect(prebakedBlurCacheLength, 0, reason: '前置：烘焙仍在飞');
    evictPrebakedBlur(provider);

    await settleAsync(tester);
    expect(bakedLayer, findsOneWidget, reason: '本卡照常画出（它显示的就是这张源图）');
    expect(
      prebakedBlurCacheLength,
      0,
      reason: 'evict 之后才回来的烘焙结果不得以同一 provider 进缓存，否则别的卡命中旧纹理',
    );
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
