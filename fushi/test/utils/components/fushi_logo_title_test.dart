import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_logo_title.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:material_ui/material_ui.dart';

// 11-21 用户：「logo 长宽高大小一样主要是，而且标题文字的占位大小也不一样」——
// 每个尺寸档一个固定标题槽（[fushiLogoSlotSize]）：logo 不论横长偏方都占同一个
// 槽，没有 logo 的标题文字（[FushiTitleSlot]）也占同高的槽。11-20 #3：背景图自带
// 片名时色块不再叠 logo。
void main() {
  const double eps = 0.01;

  group('fushiLogoSlotSize', () {
    test('槽宽 = 文字列 70%、槽高 = 档位高度', () {
      final Size slot = fushiLogoSlotSize(columnWidth: 240, height: 64);
      expect(slot.width, closeTo(240 * kFushiLogoSlotWidthFraction, eps));
      expect(slot.height, 64);
    });

    test('列宽无界时按 3:1 取宽，高度为 0 时为空', () {
      expect(
        fushiLogoSlotSize(columnWidth: double.infinity, height: 50),
        const Size(150, 50),
      );
      expect(fushiLogoSlotSize(columnWidth: 240, height: 0), Size.zero);
    });

    test('两行标题文字在规整块 / 拼贴首块的槽里都放得下（含窄窗）', () {
      for (final (FushiCoverBlockSize size, bool compact, double font)
          in <(FushiCoverBlockSize, bool, double)>[
            (FushiCoverBlockSize.regular, false, 20),
            (FushiCoverBlockSize.regular, true, 17),
            (FushiCoverBlockSize.hero, false, 28),
            (FushiCoverBlockSize.hero, true, 24),
          ]) {
        expect(
          fushiCoverBlockLogoMaxHeight(size, compact: compact),
          greaterThanOrEqualTo(font * 1.15 * 2),
          reason: '${size.name} compact=$compact',
        );
      }
    });
  });

  Future<MemoryImage> makeImage(WidgetTester tester, int w, int h) async {
    final Uint8List? bytes = await tester.runAsync<Uint8List?>(() async {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..color = const Color(0xFFCC3366),
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

  Future<void> pumpBlock(
    WidgetTester tester, {
    required Widget block,
    required Size size,
    required List<ImageProvider> images,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(size: size, child: block),
          ),
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

  const ValueKey<String> metaKey = ValueKey<String>('meta');

  /// 色块实测：横长 / 方形 / 竖长三种 logo 占的标题槽完全一样大（规整块 / 拼贴
  /// 首块），图等比画在槽内。
  for (final ({FushiCoverBlockSize size, Size box}) tier
      in <({FushiCoverBlockSize size, Size box})>[
        (size: FushiCoverBlockSize.regular, box: const Size(420, 204)),
        (size: FushiCoverBlockSize.hero, box: const Size(620, 264)),
      ]) {
    testWidgets('${tier.size.name} 色块：三种比例的 logo 标题槽同宽同高', (
      WidgetTester tester,
    ) async {
      final List<Size> slots = <Size>[];
      for (final (int w, int h) in <(int, int)>[
        (300, 100),
        (200, 200),
        (100, 200),
      ]) {
        final MemoryImage logo = await makeImage(tester, w, h);
        await pumpBlock(
          tester,
          size: tier.box,
          images: <ImageProvider>[logo],
          block: FushiCoverBlock(
            size: tier.size,
            art: FushiCoverBlockArt.portrait,
            title: '作品',
            covers: const <Widget>[],
            logo: logo,
            metaKey: metaKey,
          ),
        );
        expect(tester.takeException(), isNull);
        final Finder title = find.byType(FushiLogoTitle);
        expect(title, findsOneWidget);
        final double column = tester.getSize(find.byKey(metaKey)).width;
        final Size slot = tester.getSize(title);
        expect(slot.width, closeTo(column * kFushiLogoSlotWidthFraction, eps));
        expect(slot.height, lessThanOrEqualTo(tier.box.height));
        expect(
          find.descendant(of: title, matching: find.byType(Image)),
          findsOneWidget,
        );
        slots.add(slot);
      }
      expect(slots.toSet(), hasLength(1), reason: '$slots');
    });

    testWidgets('${tier.size.name} 色块：无 logo 的标题文字与 logo 占同高的槽', (
      WidgetTester tester,
    ) async {
      final MemoryImage logo = await makeImage(tester, 300, 100);
      final MemoryImage backdrop = await makeImage(tester, 160, 90);
      Widget blockWith({ImageProvider? logo}) => FushiCoverBlock(
        size: tier.size,
        art: FushiCoverBlockArt.portrait,
        title: '映画ドラえもん のび太と翼の勇者たち 映画ドラえもん のび太と翼の勇者たち',
        covers: const <Widget>[],
        logo: logo,
        backdrop: fushiSeriesBackdrop(backdrop),
        metaKey: metaKey,
      );
      await pumpBlock(
        tester,
        size: tier.box,
        images: <ImageProvider>[logo, backdrop],
        block: blockWith(logo: logo),
      );
      final double logoSlot = tester
          .getSize(find.byType(FushiLogoTitle))
          .height;

      await pumpBlock(
        tester,
        size: tier.box,
        images: <ImageProvider>[backdrop],
        block: blockWith(),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(FushiLogoTitle), findsNothing);
      final Finder textSlot = find.byType(FushiTitleSlot);
      expect(textSlot, findsOneWidget);
      expect(tester.getSize(textSlot).height, closeTo(logoSlot, eps));
      final Text text = tester.widget<Text>(
        find.descendant(of: textSlot, matching: find.byType(Text)),
      );
      expect(text.maxLines, lessThanOrEqualTo(2));
    });
  }

  testWidgets('解码前就占满整个槽，不画图（布局不跳）', (WidgetTester tester) async {
    final MemoryImage logo = await makeImage(tester, 300, 100);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            height: 200,
            child: FushiLogoTitle(
              logo: logo,
              title: '作品',
              maxHeight: 64,
              fallback: const Text('作品'),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    // 外层 300×200 是紧约束，量槽本身（FushiLogoTitle 里的 SizedBox）。
    final Finder slot = find.descendant(
      of: find.byType(FushiLogoTitle),
      matching: find.byType(SizedBox),
    );
    expect(
      tester.getSize(slot.first),
      Size(300 * kFushiLogoSlotWidthFraction, 64),
    );
  });

  testWidgets('背景图自带片名（backdropHasText）：色块不画 logo，只留标题文字', (
    WidgetTester tester,
  ) async {
    final MemoryImage logo = await makeImage(tester, 300, 100);
    final MemoryImage backdrop = await makeImage(tester, 160, 90);
    Widget blockWith({required bool hasText}) => fushiSeriesCoverBlock(
      size: FushiCoverBlockSize.hero,
      title: '作品',
      covers: const <Widget>[],
      meta: FushiSeriesMeta(
        logo: logo,
        backdrop: backdrop,
        backdropHasText: hasText,
      ),
      backdrop: fushiSeriesBackdrop(backdrop),
    );
    await pumpBlock(
      tester,
      size: const Size(620, 264),
      images: <ImageProvider>[logo, backdrop],
      block: blockWith(hasText: true),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(FushiLogoTitle), findsNothing);
    expect(find.text('作品'), findsWidgets);

    await pumpBlock(
      tester,
      size: const Size(620, 264),
      images: <ImageProvider>[logo, backdrop],
      block: blockWith(hasText: false),
    );
    expect(find.byType(FushiLogoTitle), findsOneWidget);
  });
}
