import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_logo_title.dart';
import 'package:fushi/src/utils/components/fushi_series_cover_block.dart';
import 'package:material_ui/material_ui.dart';

// 11-20 反馈 #2：logo 此前只限高度，横长 logo 撑满整行、方形 / 竖长的显得很小。
// 改成按「视觉面积」统一 + 宽度夹在文字列 38%～62% + 高度不超档位上限，全站
// 一份规则（[fushiLogoBoxSize] / [FushiLogoTitle]）。#3：背景图自带片名时色块
// 不再叠 logo。
void main() {
  const double eps = 0.01;

  /// 三种比例 × 三个尺寸档（半高卡 / 规整块 / 拼贴首块，宽窄两种）的纯函数契约。
  group('fushiLogoBoxSize', () {
    const List<double> aspects = <double>[3, 1, 0.5];
    final List<({String tier, double maxHeight, double column})> tiers =
        <({String tier, double maxHeight, double column})>[
          (
            tier: 'S',
            maxHeight: fushiCoverBlockLogoMaxHeight(
              FushiCoverBlockSize.half,
              compact: false,
            ),
            column: 160,
          ),
          (
            tier: 'M',
            maxHeight: fushiCoverBlockLogoMaxHeight(
              FushiCoverBlockSize.regular,
              compact: false,
            ),
            column: 240,
          ),
          (
            tier: 'M-compact',
            maxHeight: fushiCoverBlockLogoMaxHeight(
              FushiCoverBlockSize.regular,
              compact: true,
            ),
            column: 200,
          ),
          (
            tier: 'L',
            maxHeight: fushiCoverBlockLogoMaxHeight(
              FushiCoverBlockSize.hero,
              compact: false,
            ),
            column: 360,
          ),
        ];
    for (final ({String tier, double maxHeight, double column}) t in tiers) {
      for (final double aspect in aspects) {
        test('${t.tier} 档 · $aspect:1 → 宽 ≤ 62% 列宽、高 ≤ 档位上限、保持比例', () {
          final Size box = fushiLogoBoxSize(
            aspect: aspect,
            columnWidth: t.column,
            maxHeight: t.maxHeight,
          );
          expect(box.width, lessThanOrEqualTo(t.column * 0.62 + eps));
          expect(box.height, lessThanOrEqualTo(t.maxHeight + eps));
          expect((box.width / box.height - aspect).abs(), lessThan(1e-6));
          expect(box.width, greaterThan(0));
        });
      }
    }

    test('横长 logo 不再撑满整行：3:1 在拼贴首块里卡在 62%', () {
      final Size box = fushiLogoBoxSize(
        aspect: 6,
        columnWidth: 360,
        maxHeight: 92,
      );
      expect(box.width, closeTo(360 * 0.62, eps));
    });

    test('方形 logo 不缩成小角标：宽至少到 38% 列宽，再被高度上限卡住', () {
      final Size box = fushiLogoBoxSize(
        aspect: 1,
        columnWidth: 200,
        maxHeight: 92,
      );
      expect(box.width, greaterThanOrEqualTo(200 * 0.38 - eps));
      expect(box.height, lessThanOrEqualTo(92 + eps));
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

  /// 色块实测：logo 框宽 ≤ 文字列 62%、高 ≤ 档位上限（三种比例 × 规整块 / 拼贴
  /// 首块）。文字列宽 = [FushiLogoTitle] 拿到的约束宽。
  for (final ({FushiCoverBlockSize size, Size box, double maxHeight}) tier
      in <({FushiCoverBlockSize size, Size box, double maxHeight})>[
        (
          size: FushiCoverBlockSize.regular,
          box: const Size(420, 204),
          maxHeight: 78,
        ),
        (
          size: FushiCoverBlockSize.hero,
          box: const Size(620, 264),
          maxHeight: 92,
        ),
      ]) {
    for (final (int w, int h) in <(int, int)>[
      (300, 100),
      (200, 200),
      (100, 200),
    ]) {
      testWidgets(
        '${tier.size.name} 色块 · logo $w×$h：宽 ≤ 62% 文字列、高 ≤ ${tier.maxHeight}',
        (WidgetTester tester) async {
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
              metaKey: const ValueKey<String>('meta'),
            ),
          );
          expect(tester.takeException(), isNull);
          final Finder title = find.byType(FushiLogoTitle);
          expect(title, findsOneWidget);
          // 文字列 = 色块文字区（metaKey 那一块）的宽。
          final double column = tester
              .getSize(find.byKey(const ValueKey<String>('meta')))
              .width;
          final Size drawn = tester.getSize(
            find.descendant(of: title, matching: find.byType(Image)),
          );
          expect(drawn.width, lessThanOrEqualTo(column * 0.62 + eps));
          expect(drawn.height, lessThanOrEqualTo(tier.maxHeight + eps));
          expect((drawn.width / drawn.height - w / h).abs(), lessThan(0.01));
        },
      );
    }
  }

  testWidgets('解码前按高度占位，不画图（布局不跳）', (WidgetTester tester) async {
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
              maxHeight: 78,
              fallback: const Text('作品'),
            ),
          ),
        ),
      ),
    );
    final Finder box = find.descendant(
      of: find.byType(FushiLogoTitle),
      matching: find.byType(SizedBox),
    );
    expect(find.byType(Image), findsNothing);
    expect(tester.getSize(box.first).height, 78);
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
