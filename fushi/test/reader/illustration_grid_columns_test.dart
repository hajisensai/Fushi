import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/illustration_grid_columns.dart';
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;

/// 网格宽 → 单张卡宽（列数算完反推）。
double _cardExtent(double gridWidth, {double spacing = 12}) {
  final int columns = illustrationGridColumnsForWidth(
    gridWidth,
    spacing: spacing,
  );
  return (gridWidth - (columns - 1) * spacing) / columns;
}

/// 列数从真实几何反推：网格宽 = 视口宽 − 两侧 16 页边距，卡宽 + 12 间距一格。
/// （BUG-2589 起网格由槽位表驱动，delegate 不再暴露 crossAxisCount。）
int _readerGalleryColumns(WidgetTester tester) {
  final double gridWidth = tester.view.physicalSize.width - 32;
  final double cardWidth = tester
      .getSize(
        find.byKey(const ValueKey<String>('fushi_gallery_card_img0.png')),
      )
      .width;
  return ((gridWidth + 12) / (cardWidth + 12)).round();
}

Future<void> _pumpReaderGallery(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderGalleryPage(
        images: <EpubImageRef>[
          for (int i = 0; i < 8; i++)
            EpubImageRef(
              chapterIndex: 0,
              orderInBook: i,
              src: 'img$i.png',
              revealKey: 'img$i.png',
            ),
        ],
        currentChapter: 0,
        fileForRef: (_) => null,
        onOpenImage: (_) {},
        onJumpTo: (_) {},
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('illustrationGridColumnsForWidth', () {
    test('手机窄屏：目标宽落在 200 下限，列数与原先 maxCrossAxisExtent 200 一致', () {
      // 360 逻辑宽手机减两侧 16 padding。
      expect(illustrationGridColumnsForWidth(328, spacing: 12), 2);
      // 768 平板减 padding。
      expect(illustrationGridColumnsForWidth(736, spacing: 12), 4);
      expect(_cardExtent(328), lessThanOrEqualTo(200));
      expect(_cardExtent(736), lessThanOrEqualTo(200));
    });

    test('桌面窗口越宽卡片越大：1200 → 5 列 ~225，1920 → 6 列 ~305', () {
      expect(illustrationGridColumnsForWidth(1168, spacing: 12), 5);
      expect(_cardExtent(1168), closeTo(224, 1));
      expect(illustrationGridColumnsForWidth(1888, spacing: 12), 6);
      expect(_cardExtent(1888), closeTo(304, 1));
      // 单调：网格变宽，卡不会反而变小到手机尺寸。
      expect(_cardExtent(1888), greaterThan(_cardExtent(1168)));
      expect(_cardExtent(1168), greaterThan(_cardExtent(736)));
    });

    test('卡宽封顶 360：再宽的窗口靠加列吸收，不铺成半屏大图', () {
      for (final double width in <double>[2500, 3200, 5000]) {
        expect(_cardExtent(width), lessThanOrEqualTo(360));
      }
      expect(illustrationGridColumnsForWidth(3200, spacing: 12), 9);
    });

    test('极窄 / 非法宽度至少 1 列', () {
      expect(illustrationGridColumnsForWidth(1, spacing: 12), 1);
      expect(illustrationGridColumnsForWidth(120, spacing: 12), 1);
    });
  });

  group('ReaderGalleryPage 网格列数随视口宽度走', () {
    testWidgets('800 宽 4 列，1920 宽 6 列', (tester) async {
      await _pumpReaderGallery(tester, 800);
      expect(_readerGalleryColumns(tester), 4);
      await _pumpReaderGallery(tester, 1920);
      expect(_readerGalleryColumns(tester), 6);
    });
  });

  test('书架端插图库与阅读器插图册用同一条列数规则（不再钉死 maxCrossAxisExtent）', () {
    final String viewer = File(
      'lib/src/pages/implementations/illustrations_viewer_page.dart',
    ).readAsStringSync();
    final String gallery = File(
      'lib/src/reader/reader_gallery_page.dart',
    ).readAsStringSync();
    // BUG-2589：书架端不再有自己的网格，直接用阅读器内的 ReaderGalleryPage。
    expect(viewer, contains('ReaderGalleryPage('));
    expect(viewer, isNot(contains('GridView')));
    expect(viewer, isNot(contains('maxCrossAxisExtent:')));
    expect(gallery, contains('illustrationGridColumnsForWidth('));
    expect(gallery, isNot(contains('_kCardMaxExtent')));
  });
}
